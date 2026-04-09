#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* worker.rex — Concurrent task worker for RalphClip                   */
/*                                                                     */
/* TaskWorker encapsulates the retry loop (adapter calls, backoff,     */
/* error classification, prompt enrichment) so it can be dispatched    */
/* asynchronously via ooRexx's ~start mechanism.                       */
/*                                                                     */
/* All Fossil operations go through the shared FossilMutex to          */
/* prevent concurrent write corruption.                                */
/*                                                                     */
/* Usage:                                                              */
/*   worker = .TaskWorker~new(taskSpec, mutex, tracer, runId)         */
/*   msg = worker~start('execute')       -- async dispatch            */
/*   result = msg~result                 -- blocks until done         */
/*--------------------------------------------------------------------*/

::CLASS TaskWorker PUBLIC

::ATTRIBUTE taskSpec   GET
::ATTRIBUTE mutex      GET
::ATTRIBUTE tracer     GET
::ATTRIBUTE runId      GET

/*--------------------------------------------------------------------*/
/* init — construct a worker with everything it needs                   */
/*                                                                     */
/* taskSpec is a Directory containing:                                 */
/*   agentName, agentRuntime, agentModel, agentScript, agentWorkDir   */
/*   ticketId, ticketTitle, ticketType, goalChain, gateType           */
/*   prompt, projCode                                                  */
/*   taskMaxRetries, taskBackoff, taskBackoffBase, taskFailAction      */
/*   adapterRuntimes (space-separated: primary + fallbacks)            */
/*   fallbackModel                                                     */
/*   maxIterations                                                     */
/*   runDir                                                            */
/*   agentConfig (parsed TOML Directory)                               */
/*--------------------------------------------------------------------*/
::METHOD init
   EXPOSE taskSpec mutex tracer runId
   USE ARG taskSpec, mutex, tracer, runId


/*--------------------------------------------------------------------*/
/* execute — run the full retry loop for this task                     */
/*                                                                     */
/* This method is designed to be called via ~start for async dispatch. */
/* Returns a Directory with:                                           */
/*   completed     — .true / .false                                   */
/*   lastResult    — final adapter result Directory                   */
/*   attemptLog    — Array of attempt Directories                     */
/*   totalCost     — accumulated cost in USD                          */
/*   adapterUsed   — the adapter that succeeded (or last one tried)   */
/*   taskSafeName  — sanitised task name for Fossil tags              */
/*--------------------------------------------------------------------*/
::METHOD execute
   EXPOSE taskSpec mutex tracer runId

   /* Unpack taskSpec */
   agentName      = taskSpec['agentName']
   agentRuntime   = taskSpec['agentRuntime']
   agentModel     = taskSpec['agentModel']
   agentScript    = taskSpec['agentScript']
   agentWorkDir   = taskSpec['agentWorkDir']
   ticketId       = taskSpec['ticketId']
   ticketTitle    = taskSpec['ticketTitle']
   projCode       = taskSpec['projCode']
   prompt         = taskSpec['prompt']
   taskMaxRetries = taskSpec['taskMaxRetries']
   taskBackoff    = taskSpec['taskBackoff']
   taskBackoffBase = taskSpec['taskBackoffBase']
   adapterRuntimes = taskSpec['adapterRuntimes']
   fallbackModel  = taskSpec['fallbackModel']
   maxIterations  = taskSpec['maxIterations']
   runDir         = taskSpec['runDir']

   /* Prepare result package */
   outcome = .Directory~new
   outcome['completed']    = .false
   outcome['lastResult']   = .nil
   outcome['attemptLog']   = .Array~new
   outcome['totalCost']    = 0
   outcome['adapterUsed']  = agentRuntime
   outcome['taskSafeName'] = TRANSLATE(ticketTitle, '_', ' ')

   taskSafeName  = outcome['taskSafeName']
   attemptLog    = outcome['attemptLog']
   currentPrompt = prompt
   totalCost     = 0

   /*-----------------------------------------------------------------*/
   /* Retry loop with fallback cascade                                 */
   /*-----------------------------------------------------------------*/
   DO attempt = 1 TO taskMaxRetries
      /* Select adapter: primary first, then walk fallback list */
      adapterIdx = MIN(attempt, WORDS(adapterRuntimes))
      currentRuntime = WORD(adapterRuntimes, adapterIdx)
      IF adapterIdx = 1 THEN currentModel = agentModel
      ELSE currentModel = fallbackModel

      adapter = .AgentAdapter~new(currentRuntime, currentModel, agentWorkDir)
      adapter~scriptPath = agentScript
      adapter~ticketId = ticketId
      adapter~skipPermissions = taskSpec['skipPermissions']

      SAY '['agentName'] Attempt' attempt 'of' taskMaxRetries -
         '(adapter:' currentRuntime')'

      /* Fossil checkpoint: pre-attempt (through mutex) */
      preMsg = '[attempt] task:'ticketTitle 'attempt:'attempt -
               'adapter:'currentRuntime 'run:'runId
      preTag = 'pre-attempt:'taskSafeName':'attempt
      mutex~commitWithTag(preMsg, preTag)

      spanStart = .FossilHelper~isoTimestamp()

      /*--------------------------------------------------------------*/
      /* Ralph loop — the expensive part (no mutex held)               */
      /*--------------------------------------------------------------*/
      iterResult = .nil
      DO iter = 1 TO maxIterations
         SAY '['agentName'] Iteration' iter 'of' maxIterations

         iterResult = adapter~run(currentPrompt)

         /* Track cost through mutex */
         runCost = iterResult['cost']
         IF \DATATYPE(runCost, 'N') THEN runCost = 0
         IF runCost > 0 THEN
            mutex~recordCost(projCode, agentName, ticketId, runCost)
         totalCost = totalCost + runCost

         /* Log output (file per agent — no contention) */
         CALL self~logOutput runDir, agentName, projCode, -
            attempt || '.' || iter, iterResult

         /* Check for runtime error */
         IF \iterResult['ok'] THEN DO
            SAY '['agentName'] Runtime error on iteration' iter -
               '(' || iterResult['error_class'] || ':' -
               || iterResult['error_message'] || ')'
            LEAVE
         END

         /* Check completion */
         IF iterResult['complete'] THEN DO
            SAY '['agentName'] Task complete on attempt' attempt -
               'iter' iter '($'FORMAT(runCost,,4)')'
            LEAVE
         END
      END /* Ralph loop */

      /* Record attempt */
      attemptEntry = .Directory~new
      attemptEntry['adapter']       = currentRuntime
      attemptEntry['duration_ms']   = iterResult['duration_ms']
      attemptEntry['error_class']   = iterResult['error_class']
      attemptEntry['error_message'] = iterResult['error_message']
      attemptLog~append(attemptEntry)

      /* Record trace span (tracer is GUARDED by default) */
      IF iterResult['ok'] & iterResult['complete'] THEN
         spanStatus = 'ok'
      ELSE IF iterResult['error_class'] = 'fatal' THEN
         spanStatus = 'parked'
      ELSE
         spanStatus = 'error'

      spanErrInfo = ''
      IF spanStatus \= 'ok' THEN
         spanErrInfo = iterResult['error_class']':'iterResult['error_message']

      tracer~span('task.'ticketTitle '(attempt' attempt'/'taskMaxRetries')', -
         currentRuntime, spanStart, iterResult['duration_ms'], -
         iterResult['token_in'], iterResult['token_out'], -
         spanStatus, spanErrInfo, preTag)

      /* ---- Evaluate result ---- */

      IF iterResult['ok'] & iterResult['complete'] THEN DO
         /* SUCCESS — checkpoint through mutex */
         postMsg = '[success] task:'ticketTitle -
                   'adapter:'currentRuntime 'run:'runId
         postTag = 'post-success:'taskSafeName
         mutex~commitWithTag(postMsg, postTag)

         outcome['completed']   = .true
         outcome['lastResult']  = iterResult
         outcome['adapterUsed'] = currentRuntime
         outcome['totalCost']   = totalCost
         RETURN outcome
      END

      /* FATAL — mark and exit (commit phase will park) */
      IF iterResult['error_class'] = 'fatal' THEN DO
         SAY '['agentName'] Fatal error — will be parked.'
         outcome['completed']   = .false
         outcome['lastResult']  = iterResult
         outcome['adapterUsed'] = currentRuntime
         outcome['totalCost']   = totalCost
         RETURN outcome
      END

      /* SEMANTIC — enrich prompt for next attempt */
      IF iterResult['error_class'] = 'semantic' THEN DO
         SAY '['agentName'] Semantic error — enriching prompt for retry.'
         currentPrompt = currentPrompt || '0a'x || '0a'x
         currentPrompt = currentPrompt || -
            '--- ERROR FROM PREVIOUS ATTEMPT ---' || '0a'x
         currentPrompt = currentPrompt || -
            'The previous attempt produced a' iterResult['error_class'] -
            'error:' iterResult['error_message'] || '0a'x
         currentPrompt = currentPrompt || -
            'Please fix this issue in your next attempt.' || '0a'x
      END

      /* TRANSIENT — log and backoff */
      SAY '['agentName'] Attempt' attempt 'failed. Retrying...'

      /* Backoff wait (skip on last attempt) */
      IF attempt < taskMaxRetries THEN
         CALL .BackoffHelper~wait taskBackoff, taskBackoffBase, attempt

   END /* retry loop */

   /* Exhausted all retries */
   outcome['completed']   = .false
   outcome['lastResult']  = iterResult
   outcome['adapterUsed'] = currentRuntime
   outcome['totalCost']   = totalCost
   RETURN outcome


/*--------------------------------------------------------------------*/
/* logOutput — write run output to the agent's log file                */
/* Each agent has its own file, so no contention.                      */
/*--------------------------------------------------------------------*/
::METHOD logOutput PRIVATE
   USE ARG runDir, agentName, projCode, attemptIter, result

   logFile = runDir'/'agentName'-'projCode'.log'

   entry = ''
   entry = entry || '========================================' || '0a'x
   entry = entry || 'Agent:     ' agentName                    || '0a'x
   entry = entry || 'Project:   ' projCode                     || '0a'x
   entry = entry || 'Attempt:   ' attemptIter                  || '0a'x
   entry = entry || 'Time:      ' DATE('S') TIME()             || '0a'x
   entry = entry || 'OK:        ' result['ok']                 || '0a'x
   entry = entry || 'Error:     ' result['error_class'] -
                     ':' result['error_message']               || '0a'x
   entry = entry || 'Cost:      $' result['cost']              || '0a'x
   entry = entry || 'Duration:  ' result['duration_ms'] 'ms'   || '0a'x
   entry = entry || 'Tokens:    ' result['token_in'] 'in /' -
                     result['token_out'] 'out'                 || '0a'x
   entry = entry || 'Complete:  ' result['complete']           || '0a'x
   entry = entry || '========================================' || '0a'x
   entry = entry || result['output']                           || '0a'x
   entry = entry || '0a'x

   CALL CHAROUT logFile, entry
   CALL STREAM logFile, 'C', 'CLOSE'
   RETURN
