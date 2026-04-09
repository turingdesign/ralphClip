#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* review.rex — Human-in-the-loop review tool for RalphClip           */
/*                                                                     */
/* Interactive CLI for processing escalated tasks, parked tasks, and   */
/* approval-pending tickets.                                           */
/*                                                                     */
/* Usage:                                                              */
/*   rexx /path/to/ralphclip/review.rex [command]                     */
/*                                                                     */
/* Commands:                                                           */
/*   list       — show all items awaiting human action (default)      */
/*   apply      — process all escalations with completed responses    */
/*   approve    — list and approve awaiting-approval tickets          */
/*   parked     — list parked tasks                                   */
/*   requeue ID — re-open a specific ticket                           */
/*--------------------------------------------------------------------*/

PARSE SOURCE . . sourceFile
ralphclipHome = LEFT(sourceFile, LASTPOS('/', sourceFile) - 1)

CALL (ralphclipHome'/lib/toml.rex')
CALL (ralphclipHome'/lib/fossil.rex')
CALL (ralphclipHome'/lib/escalation.rex')

/* Parse command */
IF ARG() > 0 THEN
   PARSE ARG command extra
ELSE
   command = 'list'

command = STRIP(TRANSLATE(command,, -
   'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))

SELECT
   WHEN command = 'list'    THEN CALL doList
   WHEN command = 'apply'   THEN CALL doApply
   WHEN command = 'approve' THEN CALL doApprove
   WHEN command = 'parked'  THEN CALL doParked
   WHEN command = 'requeue' THEN CALL doRequeue STRIP(extra)
   WHEN command = 'help'    THEN CALL doHelp
   OTHERWISE DO
      SAY 'Unknown command:' command
      CALL doHelp
   END
END

EXIT 0


/*--------------------------------------------------------------------*/
/* doList — show everything awaiting human action                      */
/*--------------------------------------------------------------------*/
doList:
   SAY '================================================================'
   SAY ' RalphClip — Human Review Queue'
   SAY '================================================================'
   SAY ''

   /* 1. Escalated tickets */
   SAY '--- Escalated Tickets ---'
   ADDRESS SYSTEM 'fossil ticket list status=escalated' -
      '--format "%u | %t | %x(assignee) | %x(project)" 2>/dev/null' -
      WITH OUTPUT STEM esc.
   IF esc.0 > 0 & STRIP(esc.1) \= '' THEN DO
      SAY '  ID            | Title                          | Agent        | Project'
      SAY '  --------------|--------------------------------|--------------|--------'
      DO i = 1 TO esc.0
         IF STRIP(esc.i) \= '' THEN SAY '  'esc.i
      END
   END
   ELSE
      SAY '  (none)'
   SAY ''

   /* 2. Awaiting-approval tickets */
   SAY '--- Awaiting Approval ---'
   ADDRESS SYSTEM 'fossil ticket list status=awaiting-approval' -
      '--format "%u | %t | %x(assignee) | %x(project)" 2>/dev/null' -
      WITH OUTPUT STEM appr.
   IF appr.0 > 0 & STRIP(appr.1) \= '' THEN DO
      SAY '  ID            | Title                          | Agent        | Project'
      SAY '  --------------|--------------------------------|--------------|--------'
      DO i = 1 TO appr.0
         IF STRIP(appr.i) \= '' THEN SAY '  'appr.i
      END
   END
   ELSE
      SAY '  (none)'
   SAY ''

   /* 3. Pending escalation documents */
   SAY '--- Escalation Documents (awaiting your response) ---'
   ADDRESS SYSTEM 'ls escalations/*.md 2>/dev/null' WITH OUTPUT STEM edocs.
   found = 0
   IF edocs.0 > 0 THEN DO i = 1 TO edocs.0
      f = STRIP(edocs.i)
      IF f = '' THEN ITERATE
      IF RIGHT(f, 8) = '.md.done' THEN ITERATE
      entry = .EscalationReader~parseResponse(f)
      IF entry['action'] = 'pending' THEN DO
         SAY '  →' f
         SAY '    Task:' entry['task'] '| Agent:' entry['agent'] -
            '| Project:' entry['project']
         found = found + 1
      END
   END
   IF found = 0 THEN SAY '  (none)'
   SAY ''

   /* 4. Escalation documents with responses ready to apply */
   SAY '--- Escalation Responses (ready to apply) ---'
   responses = .EscalationReader~scanPending('escalations')
   IF responses~items > 0 THEN DO i = 1 TO responses~items
      r = responses[i]
      SAY '  →' r['file_path']
      SAY '    Action:' r['action'] '| Task:' r['task'] -
         '| Ticket:' r['ticket_id']
   END
   ELSE
      SAY '  (none — fill in the Response section in an escalation doc)'
   SAY ''

   /* 5. Parked tasks */
   SAY '--- Parked Tasks ---'
   ADDRESS SYSTEM 'ls parked_tasks/*.md 2>/dev/null' WITH OUTPUT STEM parked.
   IF parked.0 > 0 & STRIP(parked.1) \= '' THEN DO
      DO i = 1 TO parked.0
         IF STRIP(parked.i) \= '' THEN SAY '  →' parked.i
      END
   END
   ELSE
      SAY '  (none)'
   SAY ''

   SAY 'Commands: rexx review.rex apply | approve | requeue <ticket-id> | help'
   RETURN


/*--------------------------------------------------------------------*/
/* doApply — process all escalation documents that have responses      */
/*--------------------------------------------------------------------*/
doApply:
   SAY '================================================================'
   SAY ' Applying escalation responses...'
   SAY '================================================================'
   SAY ''

   responses = .EscalationReader~scanPending('escalations')

   IF responses~items = 0 THEN DO
      SAY 'No escalation responses to process.'
      SAY 'Edit an escalation document in escalations/ and fill in the Response section.'
      RETURN
   END

   DO i = 1 TO responses~items
      r = responses[i]
      SAY '--- Processing:' r['file_path'] '---'
      SAY '  Task:' r['task']
      SAY '  Action:' r['action']
      IF r['notes'] \= '' THEN SAY '  Notes:' r['notes']
      SAY ''
      CALL .EscalationReader~applyResponse r
      SAY ''
   END

   SAY 'Done. Processed' responses~items 'escalation(s).'
   RETURN


/*--------------------------------------------------------------------*/
/* doApprove — list awaiting-approval tickets and approve them         */
/*--------------------------------------------------------------------*/
doApprove:
   SAY '================================================================'
   SAY ' Approving awaiting-approval tickets...'
   SAY '================================================================'
   SAY ''

   ADDRESS SYSTEM 'fossil ticket list status=awaiting-approval' -
      '--format "%u|%t|%x(assignee)" 2>/dev/null' -
      WITH OUTPUT STEM appr.

   IF appr.0 = 0 | STRIP(appr.1) = '' THEN DO
      SAY 'No tickets awaiting approval.'
      RETURN
   END

   DO i = 1 TO appr.0
      line = STRIP(appr.i)
      IF line = '' THEN ITERATE

      PARSE VAR line tid '|' title '|' assignee
      tid = STRIP(tid)
      title = STRIP(title)
      assignee = STRIP(assignee)

      SAY '  Approving:' title '(ticket:' tid', agent:' assignee')'
      CALL .FossilHelper~ticketChange tid, 'status=open'
   END

   CALL .FossilHelper~commitAll '[approval] batch approval via review.rex'
   SAY ''
   SAY 'Done. All tickets re-opened for processing.'
   RETURN


/*--------------------------------------------------------------------*/
/* doParked — list parked tasks with detail                            */
/*--------------------------------------------------------------------*/
doParked:
   SAY '================================================================'
   SAY ' Parked Tasks'
   SAY '================================================================'
   SAY ''

   ADDRESS SYSTEM 'ls parked_tasks/*.md 2>/dev/null' WITH OUTPUT STEM parked.
   IF parked.0 = 0 | STRIP(parked.1) = '' THEN DO
      SAY 'No parked tasks.'
      RETURN
   END

   DO i = 1 TO parked.0
      f = STRIP(parked.i)
      IF f = '' THEN ITERATE

      SAY '--- 'f' ---'

      /* Read first 10 lines for a quick summary */
      ADDRESS SYSTEM 'head -15 "'f'" 2>/dev/null' WITH OUTPUT STEM lines.
      DO j = 1 TO lines.0
         SAY '  'lines.j
      END
      SAY ''
   END

   SAY 'To re-queue a parked task, use: rexx review.rex requeue <ticket-id>'
   RETURN


/*--------------------------------------------------------------------*/
/* doRequeue — re-open a specific ticket by UUID                       */
/*--------------------------------------------------------------------*/
doRequeue:
   PARSE ARG ticketId
   IF ticketId = '' THEN DO
      SAY 'Usage: rexx review.rex requeue <ticket-id>'
      SAY 'Get ticket IDs from: rexx review.rex list'
      RETURN
   END

   /* Verify the ticket exists */
   status = .FossilHelper~ticketField(ticketId, 'status')
   IF status = '' THEN DO
      SAY 'Ticket not found:' ticketId
      RETURN
   END

   SAY 'Ticket:' ticketId
   SAY 'Current status:' status
   SAY 'Re-opening...'

   CALL .FossilHelper~ticketChange ticketId, 'status=open'
   CALL .FossilHelper~commitAll '[requeue] ticket:'ticketId 'via review.rex'

   SAY 'Done. Ticket re-opened for next orchestrator run.'
   RETURN


/*--------------------------------------------------------------------*/
/* doHelp — print usage                                                */
/*--------------------------------------------------------------------*/
doHelp:
   SAY 'RalphClip Review Tool — Human-in-the-loop task management'
   SAY ''
   SAY 'Usage: rexx' sourceFile '[command]'
   SAY ''
   SAY 'Commands:'
   SAY '  list       Show all items awaiting human action (default)'
   SAY '  apply      Process all escalation documents with completed responses'
   SAY '  approve    Batch-approve all awaiting-approval tickets'
   SAY '  parked     List parked tasks with detail'
   SAY '  requeue ID Re-open a specific ticket for retry'
   SAY '  help       Show this message'
   SAY ''
   SAY 'Workflow:'
   SAY '  1. Run "rexx review.rex" to see what needs attention'
   SAY '  2. Edit escalation docs in escalations/ — fill in the Response section'
   SAY '  3. Run "rexx review.rex apply" to process your responses'
   SAY '  4. Next "rexx orchestrate.rex" run picks up re-queued tasks'
   SAY ''
   SAY 'Escalation response actions:'
   SAY '  requeue   — re-open the ticket for another attempt'
   SAY '  reassign  — reassign to a different agent (set "Reassign to" field)'
   SAY '  close     — close/abandon the task'
   SAY '  split     — mark for decomposition (create sub-tickets manually)'
   RETURN
