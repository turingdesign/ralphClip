#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* parked.rex — Parked task writer for RalphClip                       */
/*                                                                     */
/* Writes failed tasks to parked_tasks/ as Markdown files containing   */
/* full error context, attempt logs, and the original task config.     */
/*--------------------------------------------------------------------*/

::CLASS ParkedWriter PUBLIC

/*--------------------------------------------------------------------*/
/* write — create a parked task Markdown file                          */
/*                                                                     */
/* Arguments:                                                          */
/*   taskName     — the task/ticket title                             */
/*   attempts     — total attempts made                               */
/*   finalAdapter — adapter used on the final attempt                 */
/*   errorClass   — final error classification                        */
/*   errorMessage — final error message                               */
/*   attemptLog   — Array of attempt Directory objects, each with:    */
/*                  ['adapter'], ['duration_ms'], ['error_class'],     */
/*                  ['error_message']                                   */
/*   taskConfig   — TOML config block string for the task             */
/*   lastError    — full error output / stack trace from final attempt*/
/*   parkedDir    — directory to write the parked file                */
/*                                                                     */
/* Returns: the path to the created parked task file                   */
/*--------------------------------------------------------------------*/
::METHOD write CLASS
   USE ARG taskName, attempts, finalAdapter, errorClass, errorMessage, ,
           attemptLog, taskConfig, lastError, parkedDir

   ADDRESS SYSTEM 'mkdir -p' parkedDir

   timestamp  = .FossilHelper~isoTimestamp()
   compactTs  = .FossilHelper~isoTimestampCompact()

   /* Sanitise task name for filename (replace spaces with underscores) */
   safeName = TRANSLATE(taskName, '_', ' ')
   /* Remove anything that's not alphanumeric, underscore, or hyphen */
   cleanName = ''
   DO c = 1 TO LENGTH(safeName)
      ch = SUBSTR(safeName, c, 1)
      IF DATATYPE(ch, 'A') | ch = '_' | ch = '-' THEN cleanName = cleanName || ch
   END
   IF cleanName = '' THEN cleanName = 'unnamed'

   fileName = cleanName'_'compactTs'.md'
   filePath = parkedDir'/'fileName

   /* Build the document */
   doc = '# Parked Task:' taskName || '0a'x
   doc = doc || '0a'x
   doc = doc || '- **Parked at**:' timestamp || '0a'x
   doc = doc || '- **Fossil ref**: parked:'cleanName || '0a'x
   doc = doc || '- **Attempts**:' attempts || '0a'x
   doc = doc || '- **Final adapter**:' finalAdapter || '0a'x
   doc = doc || '- **Error class**:' errorClass || '0a'x
   doc = doc || '- **Error message**:' errorMessage || '0a'x
   doc = doc || '0a'x

   /* Attempt log table */
   doc = doc || '## Attempt Log' || '0a'x
   doc = doc || '0a'x
   doc = doc || '| # | Adapter | Duration | Error Class | Error Summary |' || '0a'x
   doc = doc || '|---|---------|----------|-------------|---------------|' || '0a'x

   IF attemptLog~isA(.Array) THEN DO i = 1 TO attemptLog~items
      a = attemptLog[i]
      aAdapter  = a['adapter']
      aDuration = a['duration_ms']
      aClass    = a['error_class']
      aMsg      = a['error_message']
      IF aClass = '' | aClass = .nil THEN aClass = 'ok'
      IF aMsg = '' | aMsg = .nil THEN aMsg = '-'
      /* Truncate long error messages for the table */
      IF LENGTH(aMsg) > 60 THEN aMsg = LEFT(aMsg, 57) || '...'
      doc = doc || '|' i '|' aAdapter '|' aDuration'ms |' aClass '|' aMsg '|' || '0a'x
   END

   doc = doc || '0a'x

   /* Original task config */
   doc = doc || '## Original Task Config' || '0a'x
   doc = doc || '0a'x
   doc = doc || '```toml' || '0a'x
   doc = doc || taskConfig || '0a'x
   doc = doc || '```' || '0a'x
   doc = doc || '0a'x

   /* Last error context */
   doc = doc || '## Last Error Context' || '0a'x
   doc = doc || '0a'x
   doc = doc || lastError || '0a'x

   /* Write the file */
   CALL CHAROUT filePath, doc
   CALL STREAM filePath, 'C', 'CLOSE'

   RETURN filePath
