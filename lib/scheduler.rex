#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* scheduler.rex — Wave-based dispatch scheduler for RalphClip         */
/*                                                                     */
/* Groups agent tasks into concurrency waves based on:                 */
/*   1. Trigger dependencies (after:<agent>)                          */
/*   2. Ticket dependencies (depends field)                            */
/*   3. Working directory conflicts (same dir = same wave)            */
/*                                                                     */
/* Tasks within a wave run concurrently. Waves execute sequentially.   */
/* After each wave completes, completedAgents is updated, and the     */
/* next wave's trigger/dep checks can resolve.                         */
/*                                                                     */
/* Usage:                                                              */
/*   scheduler = .WaveScheduler~new()                                 */
/*   scheduler~addCandidate(candidateDir)                             */
/*   waves = scheduler~buildWaves(completedAgents)                    */
/*--------------------------------------------------------------------*/

::CLASS WaveScheduler PUBLIC

::METHOD init
   EXPOSE candidates
   candidates = .Array~new

/*--------------------------------------------------------------------*/
/* addCandidate — register a task candidate for scheduling             */
/*                                                                     */
/* candidate is a Directory containing at minimum:                     */
/*   agentName   — agent identifier                                   */
/*   trigger     — trigger string from TOML                           */
/*   deps        — comma-separated ticket dep IDs (or '')             */
/*   workDir     — resolved working directory path                    */
/*   taskSpec    — full taskSpec Directory (carried through to waves)  */
/*--------------------------------------------------------------------*/
::METHOD addCandidate
   EXPOSE candidates
   USE ARG candidate
   candidates~append(candidate)
   RETURN

/*--------------------------------------------------------------------*/
/* buildWaves — partition candidates into ordered concurrency waves    */
/*                                                                     */
/* Returns an Array of Arrays. Each inner Array contains candidate     */
/* Directories that can safely execute concurrently.                   */
/*                                                                     */
/* Algorithm:                                                          */
/*   1. Separate candidates into ready vs. blocked                    */
/*   2. Among ready candidates, group by working directory —          */
/*      candidates sharing a directory go in separate waves           */
/*   3. Blocked candidates wait for future waves                      */
/*   4. After each wave, simulate completion and re-evaluate blocked  */
/*   5. Repeat until all candidates are assigned or no progress       */
/*                                                                     */
/* completedAgents: space-separated list of already-completed agents   */
/*--------------------------------------------------------------------*/
::METHOD buildWaves
   EXPOSE candidates
   USE ARG completedAgents

   IF candidates~items = 0 THEN RETURN .Array~new

   waves = .Array~new
   remaining = self~copyArray(candidates)
   currentCompleted = completedAgents
   maxWaves = 20  /* safety limit to prevent infinite loops */

   DO waveNum = 1 TO maxWaves
      IF remaining~items = 0 THEN LEAVE

      /* Partition into ready vs. blocked */
      ready   = .Array~new
      blocked = .Array~new

      DO i = 1 TO remaining~items
         c = remaining[i]
         IF self~isReady(c, currentCompleted) THEN
            ready~append(c)
         ELSE
            blocked~append(c)
      END

      /* No progress — remaining candidates have circular deps or
         depend on agents not in this run. Stop scheduling. */
      IF ready~items = 0 THEN DO
         /* Log the stranded candidates */
         DO b = 1 TO blocked~items
            SAY '[scheduler] Stranded:' blocked[b]['agentName'] -
               '(trigger:' blocked[b]['trigger'] -
               'deps:' blocked[b]['deps']')'
         END
         LEAVE
      END

      /* Resolve working directory conflicts within the ready set.
         Candidates sharing a workDir are split into sub-waves.
         The first occurrence stays in this wave; later ones are
         pushed back to the blocked pool for the next wave. */
      thisWave = .Array~new
      deferToNext = .Array~new
      usedDirs = ''

      DO i = 1 TO ready~items
         c = ready[i]
         workDir = c['workDir']

         IF workDir \= '' & WORDPOS(workDir, usedDirs) > 0 THEN DO
            /* Directory conflict — defer to next wave */
            deferToNext~append(c)
         END
         ELSE DO
            thisWave~append(c)
            IF workDir \= '' THEN
               usedDirs = usedDirs workDir
         END
      END

      /* Record this wave */
      IF thisWave~items > 0 THEN
         waves~append(thisWave)

      /* Simulate completions: agents in this wave will complete,
         so add them to currentCompleted for the next wave */
      DO i = 1 TO thisWave~items
         currentCompleted = currentCompleted thisWave[i]['agentName']
      END

      /* Remaining = blocked + deferred-due-to-dir-conflict */
      remaining = .Array~new
      DO i = 1 TO blocked~items
         remaining~append(blocked[i])
      END
      DO i = 1 TO deferToNext~items
         remaining~append(deferToNext[i])
      END

   END /* wave loop */

   RETURN waves


/*--------------------------------------------------------------------*/
/* isReady — check if a candidate can run given current completions    */
/*--------------------------------------------------------------------*/
::METHOD isReady PRIVATE
   USE ARG candidate, completedAgents

   trigger = candidate['trigger']
   deps    = candidate['deps']

   /* Check trigger */
   SELECT
      WHEN trigger = 'ticket' THEN NOP  /* always ready */
      WHEN trigger = 'always' THEN NOP
      WHEN trigger = 'manual' THEN RETURN 0  /* never auto-dispatch */
      WHEN LEFT(trigger, 6) = 'after:' THEN DO
         depAgent = SUBSTR(trigger, 7)
         IF WORDPOS(depAgent, completedAgents) = 0 THEN RETURN 0
      END
      WHEN LEFT(trigger, 5) = 'cron:' THEN DO
         /* Cron triggers are evaluated at plan time, not wave time.
            If we got this far, the cron matched. */
         NOP
      END
      OTHERWISE NOP
   END

   /* Check ticket dependencies */
   IF deps \= '' THEN DO
      remaining = deps
      DO WHILE remaining \= ''
         PARSE VAR remaining dep ',' remaining
         dep = STRIP(dep)
         IF dep = '' THEN ITERATE
         status = .FossilHelper~ticketField(dep, 'status')
         IF status \= 'closed' THEN RETURN 0
      END
   END

   RETURN 1


/*--------------------------------------------------------------------*/
/* copyArray — shallow copy an Array                                   */
/*--------------------------------------------------------------------*/
::METHOD copyArray PRIVATE
   USE ARG source
   copy = .Array~new
   DO i = 1 TO source~items
      copy~append(source[i])
   END
   RETURN copy


/*--------------------------------------------------------------------*/
/* describeWaves — human-readable summary of the wave plan             */
/*--------------------------------------------------------------------*/
::METHOD describeWaves CLASS
   USE ARG waves

   DO w = 1 TO waves~items
      wave = waves[w]
      agents = ''
      DO i = 1 TO wave~items
         IF agents \= '' THEN agents = agents || ', '
         agents = agents || wave[i]['agentName']
      END
      SAY '[scheduler] Wave' w':' agents '('wave~items 'concurrent)'
   END
   RETURN
