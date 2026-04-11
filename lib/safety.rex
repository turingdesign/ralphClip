#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* lib/safety.rex — Structured error recovery for RalphClip           */
/*                                                                    */
/* Provides SIGNAL ON ERROR and SIGNAL ON SYNTAX handlers that:       */
/*   1. Write a structured crash record to runs/<runId>/crash.log     */
/*   2. Attempt a clean Fossil commit of uncommitted work             */
/*   3. Finalise the tracer if available                              */
/*   4. Exit with a non-zero return code                              */
/*                                                                    */
/* Usage in orchestrate.rex — add after existing SIGNAL ON HALT:      */
/*                                                                    */
/*   SIGNAL ON HALT    NAME cleanup                                   */
/*   SIGNAL ON ERROR   NAME errorHandler                              */
/*   SIGNAL ON SYNTAX  NAME syntaxHandler                             */
/*                                                                    */
/* Then at the bottom of orchestrate.rex, add:                        */
/*                                                                    */
/*   errorHandler:                                                    */
/*     CALL safetyHandler 'ERROR'                                     */
/*     EXIT 2                                                         */
/*                                                                    */
/*   syntaxHandler:                                                   */
/*     CALL safetyHandler 'SYNTAX'                                    */
/*     EXIT 3                                                         */
/*                                                                    */
/* v1.0.0                                                             */
/*--------------------------------------------------------------------*/

::routine safetyHandler PUBLIC
  USE ARG conditionType

  /* Gather condition info — ooRexx provides these via CONDITION() */
  condObj = CONDITION('O')
  IF condObj \= .nil THEN DO
    condDesc    = condObj~description
    condCode    = condObj~code
    condMessage = condObj~message
  END
  ELSE DO
    condDesc    = CONDITION('D')
    condCode    = CONDITION('C')
    condMessage = '(no message object available)'
  END

  errorLine = SIGL

  /* Build structured crash record */
  ts = DATE('S') TIME()
  record = ''
  record = record || '--- CRASH RECORD ---'                     || '0a'x
  record = record || 'timestamp:  ' ts                          || '0a'x
  record = record || 'condition:  ' conditionType               || '0a'x
  record = record || 'line:       ' errorLine                   || '0a'x
  record = record || 'code:       ' condCode                    || '0a'x
  record = record || 'message:    ' condMessage                 || '0a'x
  record = record || 'description:' condDesc                    || '0a'x
  record = record || '--- END CRASH ---'                        || '0a'x

  /* Write to stderr immediately */
  .error~lineout('[FATAL] RalphClip crashed at line' errorLine':' conditionType '-' condDesc)

  /* Attempt to write crash log — best effort, no SIGNAL re-entry */
  SIGNAL OFF ERROR
  SIGNAL OFF SYNTAX

  /* Try to resolve runDir from the environment stem .local */
  crashDir = VALUE('RALPHCLIP_RUN_DIR',, 'ENVIRONMENT')
  IF crashDir = '' THEN crashDir = 'runs'

  ADDRESS SYSTEM 'mkdir -p "' || crashDir || '"'
  crashFile = crashDir'/crash.log'

  DO
    CALL CHAROUT crashFile, record, 1 + CHARS(crashFile)
    CALL STREAM crashFile, 'C', 'CLOSE'
    .error~lineout('[FATAL] Crash record written to' crashFile)
  END

  /* Attempt emergency Fossil commit of any uncommitted state */
  DO
    ADDRESS SYSTEM 'fossil addremove 2>/dev/null'
    ADDRESS SYSTEM 'fossil commit -m "[crash] ' || conditionType || ' at line' errorLine || '" --no-warnings 2>/dev/null'
    .error~lineout('[FATAL] Emergency Fossil commit attempted.')
  END

  /* Attempt tracer finalisation — if the global tracer exists */
  DO
    tracer = .environment~at('RALPHCLIP.TRACER')
    IF tracer \= .nil THEN DO
      tracer~span('orchestrator.crash', '', ts,
                   0, 0, 0, 'fatal', conditionType,
                   'line:'errorLine, condDesc)
      tracer~finish()
      .error~lineout('[FATAL] Tracer finalised.')
    END
  END

  .error~lineout('[FATAL] Exiting with code' || (conditionType = 'ERROR')~?('2', '3'))

  RETURN


/*--------------------------------------------------------------------*/
/* safetyInit — call early in orchestrate.rex to register globals     */
/*              that the crash handler needs                          */
/*--------------------------------------------------------------------*/
::routine safetyInit PUBLIC
  USE ARG runDir, tracer

  /* Store in environment variables so the handler can find them     */
  /* without relying on any particular scope being active            */
  CALL VALUE 'RALPHCLIP_RUN_DIR', runDir, 'ENVIRONMENT'

  /* Store tracer in the global .environment directory */
  IF tracer \= .nil THEN
    .environment~put(tracer, 'RALPHCLIP.TRACER')

  RETURN
