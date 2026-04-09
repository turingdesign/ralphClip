#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* escalation.rex — Human-in-the-loop escalation protocol              */
/*                                                                     */
/* Writes structured escalation documents to escalations/ for human    */
/* review. Each document includes full task context, attempt history,  */
/* and a response template the human fills in to re-queue or close.   */
/*                                                                     */
/* Human response is read back by the orchestrator on the next run    */
/* via readHumanResponse() and injected into the task prompt.          */
/*                                                                     */
/* Workflow:                                                           */
/*   1. Task fails → EscalationWriter~write() → escalations/          */
/*   2. Human reviews (fossil ui, review.rex, or editor)              */
/*   3. Human fills in ## Response section                            */
/*   4. Next run → EscalationReader~pendingResponse() detects it      */
/*   5. Orchestrator re-opens ticket with human annotations           */
/*--------------------------------------------------------------------*/


/*====================================================================*/
/* EscalationWriter — generates escalation documents for human review  */
/*====================================================================*/
::CLASS EscalationWriter PUBLIC

/*--------------------------------------------------------------------*/
/* write — create an escalation document                               */
/*                                                                     */
/* Arguments:                                                          */
/*   taskName     — ticket title                                      */
/*   ticketId     — Fossil ticket UUID                                */
/*   agentName    — agent that was working the task                   */
/*   projCode     — project code                                      */
/*   attempts     — number of attempts made                           */
/*   attemptLog   — Array of attempt Directories                      */
/*   lastResult   — final result Directory from adapter               */
/*   prompt       — the prompt that was being used                    */
/*   runId        — orchestration run ID                              */
/*   reason       — why this is being escalated                       */
/*   escalDir     — directory to write to (default: escalations)      */
/*                                                                     */
/* Returns: path to the created escalation file                        */
/*--------------------------------------------------------------------*/
::METHOD write CLASS
   USE ARG taskName, ticketId, agentName, projCode, attempts, -
           attemptLog, lastResult, prompt, runId, reason, escalDir

   IF escalDir = '' THEN escalDir = 'escalations'
   ADDRESS SYSTEM 'mkdir -p' escalDir

   timestamp = .FossilHelper~isoTimestamp()
   compactTs = .FossilHelper~isoTimestampCompact()

   /* Sanitise task name for filename */
   safeName = ''
   raw = TRANSLATE(taskName, '_', ' ')
   DO c = 1 TO LENGTH(raw)
      ch = SUBSTR(raw, c, 1)
      IF DATATYPE(ch, 'A') | ch = '_' | ch = '-' THEN safeName = safeName || ch
   END
   IF safeName = '' THEN safeName = 'unnamed'

   fileName = safeName'_'compactTs'.md'
   filePath = escalDir'/'fileName

   /* Build the document */
   doc = '# Escalation: Human Review Required' || '0a'x
   doc = doc || '0a'x

   /* Context section */
   doc = doc || '## Context' || '0a'x
   doc = doc || '- **Task**:' taskName || '0a'x
   doc = doc || '- **Ticket ID**:' ticketId || '0a'x
   doc = doc || '- **Agent**:' agentName || '0a'x
   doc = doc || '- **Project**:' projCode || '0a'x
   doc = doc || '- **Run ID**:' runId || '0a'x
   doc = doc || '- **Escalated at**:' timestamp || '0a'x
   doc = doc || '- **Reason**:' reason || '0a'x
   doc = doc || '- **Attempts**:' attempts || '0a'x
   doc = doc || '0a'x

   /* Attempt history table */
   doc = doc || '## Attempt History' || '0a'x
   doc = doc || '0a'x
   doc = doc || '| # | Adapter | Duration | Error Class | Error Summary |' || '0a'x
   doc = doc || '|---|---------|----------|-------------|---------------|' || '0a'x

   IF attemptLog~isA(.Array) THEN DO i = 1 TO attemptLog~items
      ae = attemptLog[i]
      aAdapter  = ae['adapter']
      aDuration = ae['duration_ms']
      aClass    = ae['error_class']
      aMsg      = ae['error_message']
      IF aClass = '' | aClass = .nil THEN aClass = 'ok'
      IF aMsg = '' | aMsg = .nil THEN aMsg = '-'
      IF LENGTH(aMsg) > 60 THEN aMsg = LEFT(aMsg, 57) || '...'
      doc = doc || '|' i '|' aAdapter '|' aDuration'ms |' aClass '|' aMsg '|' || '0a'x
   END
   doc = doc || '0a'x

   /* Last error output (truncated) */
   IF lastResult \= .nil THEN DO
      lastOutput = lastResult['output']
      IF LENGTH(lastOutput) > 2000 THEN
         lastOutput = LEFT(lastOutput, 2000) || '0a'x || '... (truncated)'
      doc = doc || '## Last Output' || '0a'x
      doc = doc || '0a'x
      doc = doc || '```' || '0a'x
      doc = doc || lastOutput || '0a'x
      doc = doc || '```' || '0a'x
      doc = doc || '0a'x
   END

   /* Prompt that was used (truncated) */
   IF LENGTH(prompt) > 3000 THEN
      promptExcerpt = LEFT(prompt, 3000) || '0a'x || '... (truncated)'
   ELSE
      promptExcerpt = prompt
   doc = doc || '## Prompt Used' || '0a'x
   doc = doc || '0a'x
   doc = doc || '```' || '0a'x
   doc = doc || promptExcerpt || '0a'x
   doc = doc || '```' || '0a'x
   doc = doc || '0a'x

   /* Recommended actions */
   doc = doc || '## Recommended Actions' || '0a'x
   doc = doc || '0a'x
   doc = doc || '1. Review the error history and last output above' || '0a'x
   doc = doc || '2. Fill in the **Response** section below' || '0a'x
   doc = doc || '3. The next orchestrator run will read your response' || '0a'x
   doc = doc || '0a'x

   /* Response template — human fills this in */
   doc = doc || '## Response' || '0a'x
   doc = doc || '0a'x
   doc = doc || '<!-- Fill in ONE of the following actions -->' || '0a'x
   doc = doc || '0a'x
   doc = doc || '- **Action**: pending' || '0a'x
   doc = doc || '0a'x
   doc = doc || '<!-- Actions:' || '0a'x
   doc = doc || '  "requeue"    — re-open the ticket for another attempt' || '0a'x
   doc = doc || '  "reassign"   — reassign to a different agent' || '0a'x
   doc = doc || '  "close"      — close/abandon the task' || '0a'x
   doc = doc || '  "split"      — decompose into smaller sub-tasks' || '0a'x
   doc = doc || '  "pending"    — not yet reviewed (default)' || '0a'x
   doc = doc || '-->' || '0a'x
   doc = doc || '0a'x
   doc = doc || '- **Reassign to**: <!-- agent name, if action is reassign -->' || '0a'x
   doc = doc || '- **Notes**: <!-- your guidance for the agent on retry -->' || '0a'x
   doc = doc || '0a'x
   doc = doc || '<!-- Example:' || '0a'x
   doc = doc || '- **Action**: requeue' || '0a'x
   doc = doc || '- **Notes**: The wire_key field was missing because the schema' || '0a'x
   doc = doc || '  changed in v5.2. Add explicit handling for the new column name.' || '0a'x
   doc = doc || '-->' || '0a'x

   CALL CHAROUT filePath, doc
   CALL STREAM filePath, 'C', 'CLOSE'

   RETURN filePath


/*====================================================================*/
/* EscalationReader — reads human responses from escalation documents  */
/*====================================================================*/
::CLASS EscalationReader PUBLIC

/*--------------------------------------------------------------------*/
/* scanPending — scan escalations/ for documents with responses        */
/*                                                                     */
/* Returns an Array of Directories, one per actionable escalation:    */
/*   entry['file_path']   — path to the escalation file               */
/*   entry['ticket_id']   — Fossil ticket UUID                        */
/*   entry['agent']       — original agent name                       */
/*   entry['project']     — project code                              */
/*   entry['task']        — task title                                */
/*   entry['action']      — human-chosen action                       */
/*   entry['reassign_to'] — new agent (if reassign)                   */
/*   entry['notes']       — human notes/guidance                      */
/*--------------------------------------------------------------------*/
::METHOD scanPending CLASS
   USE ARG escalDir

   IF escalDir = '' THEN escalDir = 'escalations'

   results = .Array~new

   ADDRESS SYSTEM 'ls' escalDir'/*.md 2>/dev/null' WITH OUTPUT STEM files.
   IF files.0 = 0 THEN RETURN results

   DO f = 1 TO files.0
      filePath = STRIP(files.f)
      IF filePath = '' THEN ITERATE

      entry = self~parseResponse(filePath)

      /* Only return entries where human has responded (not "pending") */
      IF entry['action'] \= 'pending' & entry['action'] \= '' THEN
         results~append(entry)
   END

   RETURN results


/*--------------------------------------------------------------------*/
/* parseResponse — parse an escalation file for the human response     */
/*--------------------------------------------------------------------*/
::METHOD parseResponse CLASS
   USE ARG filePath

   entry = .Directory~new
   entry['file_path']   = filePath
   entry['ticket_id']   = ''
   entry['agent']       = ''
   entry['project']     = ''
   entry['task']        = ''
   entry['action']      = 'pending'
   entry['reassign_to'] = ''
   entry['notes']       = ''

   IF \SysFileExists(filePath) THEN RETURN entry

   content = CHARIN(filePath, 1, CHARS(filePath))
   CALL STREAM filePath, 'C', 'CLOSE'

   /* Extract context fields */
   entry['ticket_id'] = self~extractField(content, 'Ticket ID')
   entry['agent']     = self~extractField(content, 'Agent')
   entry['project']   = self~extractField(content, 'Project')
   entry['task']      = self~extractField(content, 'Task')

   /* Extract response fields */
   entry['action']      = TRANSLATE(self~extractField(content, 'Action'))
   entry['reassign_to'] = self~extractField(content, 'Reassign to')
   entry['notes']       = self~extractField(content, 'Notes')

   /* Normalise action to lowercase */
   entry['action'] = TRANSLATE(entry['action'],, -
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')

   /* Strip HTML comments from notes */
   notes = entry['notes']
   IF LEFT(notes, 4) = '<!--' THEN entry['notes'] = ''

   RETURN entry


/*--------------------------------------------------------------------*/
/* applyResponse — execute the human's chosen action                   */
/*                                                                     */
/* Handles: requeue, reassign, close, split (logged only)             */
/* After applying, renames the escalation file with .done suffix.     */
/*--------------------------------------------------------------------*/
::METHOD applyResponse CLASS
   USE ARG entry

   action   = entry['action']
   ticketId = entry['ticket_id']
   filePath = entry['file_path']

   SELECT
      WHEN action = 'requeue' THEN DO
         CALL .FossilHelper~ticketChange ticketId, 'status=open'
         SAY '[escalation] Re-queued ticket' ticketId
         /* If human provided notes, store them in the wiki for the agent */
         IF entry['notes'] \= '' THEN DO
            agentName = entry['agent']
            note = .FossilHelper~isoTimestamp() '- Human guidance:' entry['notes']
            CALL .FossilHelper~wikiAppend 'AgentLearnings/'agentName, note
            SAY '[escalation] Human notes injected into' agentName 'learnings'
         END
      END

      WHEN action = 'reassign' THEN DO
         newAgent = entry['reassign_to']
         IF newAgent \= '' THEN DO
            CALL .FossilHelper~ticketChange ticketId, -
               'assignee='newAgent 'status=open'
            SAY '[escalation] Reassigned ticket' ticketId 'to' newAgent
            IF entry['notes'] \= '' THEN DO
               note = .FossilHelper~isoTimestamp() '- Human guidance (reassigned from' -
                  entry['agent']'):' entry['notes']
               CALL .FossilHelper~wikiAppend 'AgentLearnings/'newAgent, note
            END
         END
         ELSE DO
            SAY '[escalation] WARNING: reassign requested but no agent specified'
            RETURN  /* don't mark as done */
         END
      END

      WHEN action = 'close' THEN DO
         CALL .FossilHelper~ticketChange ticketId, 'status=closed'
         SAY '[escalation] Closed ticket' ticketId '(human decision)'
      END

      WHEN action = 'split' THEN DO
         /* Split is logged — human needs to create sub-tickets manually */
         SAY '[escalation] Split requested for' ticketId -
            '— create sub-tickets manually via fossil ticket add'
         IF entry['notes'] \= '' THEN
            SAY '[escalation] Human notes:' entry['notes']
         CALL .FossilHelper~ticketChange ticketId, 'status=closed'
      END

      OTHERWISE DO
         SAY '[escalation] Unknown action "' || action || '" — skipping'
         RETURN
      END
   END

   /* Mark the escalation as processed by renaming to .done */
   donePath = filePath'.done'
   ADDRESS SYSTEM 'mv "'filePath'" "'donePath'" 2>/dev/null'
   SAY '[escalation] Processed:' filePath

   /* Fossil commit */
   commitMsg = '[escalation] ticket:'ticketId 'action:'action
   CALL .FossilHelper~commitAll commitMsg

   RETURN


/*--------------------------------------------------------------------*/
/* extractField — pull "**Label**: value" from Markdown                */
/*--------------------------------------------------------------------*/
::METHOD extractField CLASS PRIVATE
   USE ARG content, label
   marker = '**'label'**:'
   pos = POS(marker, content)
   IF pos = 0 THEN RETURN ''
   chunk = SUBSTR(content, pos + LENGTH(marker))
   PARSE VAR chunk value '0a'x .
   value = STRIP(value)
   /* Strip <!-- comments --> */
   commentPos = POS('<!--', value)
   IF commentPos > 0 THEN value = STRIP(LEFT(value, commentPos - 1))
   RETURN value
