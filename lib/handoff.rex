#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* handoff.rex — Standardised inter-agent handoff protocol             */
/*                                                                     */
/* Writes and reads Markdown handoff documents that carry provenance,  */
/* payload references, and validation contracts between agents.        */
/*                                                                     */
/* Usage:                                                              */
/*   CALL (ralphclipHome'/lib/handoff.rex')                           */
/*   .HandoffWriter~write(sourceTask, targetTask, ...)                */
/*   ho = .HandoffReader~parse(filePath)                               */
/*   ok = .HandoffReader~validate(ho)                                  */
/*--------------------------------------------------------------------*/


/*====================================================================*/
/* HandoffWriter — generates handoff Markdown documents                */
/*====================================================================*/
::CLASS HandoffWriter PUBLIC

/*--------------------------------------------------------------------*/
/* write — create a handoff document from source to target task        */
/*                                                                     */
/* Arguments:                                                          */
/*   sourceTask  — name of the source task                            */
/*   targetTask  — name of the target task                            */
/*   adapter     — adapter that produced the output                   */
/*   fossilRef   — Fossil tag for the source task's success commit    */
/*   runId       — current orchestration run ID                       */
/*   outputFiles — space-separated list of output file paths          */
/*   recordCount — integer count of records (0 if N/A)                */
/*   confidence  — "high" | "medium" | "low" ('' if N/A)              */
/*   summary     — 1-2 sentence description of what was produced      */
/*   schema      — expected schema name or version identifier          */
/*   validationRules — newline-separated list of assertions            */
/*   onFailure   — action on validation failure                       */
/*   handoffsDir — directory to write the handoff file                */
/*                                                                     */
/* Returns: the path to the created handoff file                       */
/*--------------------------------------------------------------------*/
::METHOD write CLASS
   USE ARG sourceTask, targetTask, adapter, fossilRef, runId, ,
           outputFiles, recordCount, confidence, summary, ,
           schema, validationRules, onFailure, handoffsDir

   ADDRESS SYSTEM 'mkdir -p' handoffsDir

   timestamp  = .FossilHelper~isoTimestamp()
   compactTs  = .FossilHelper~isoTimestampCompact()
   fileName   = sourceTask'_to_'targetTask'_'compactTs'.md'
   filePath   = handoffsDir'/'fileName

   /* Default values */
   IF onFailure = '' THEN onFailure = 'park'
   IF confidence = '' THEN confidence = 'N/A'
   IF recordCount = '' | \DATATYPE(recordCount, 'W') THEN recordCount = 0

   /* Build the handoff document */
   doc = '# Handoff:' sourceTask '→' targetTask || '0a'x
   doc = doc || '0a'x

   /* Provenance section */
   doc = doc || '## Provenance' || '0a'x
   doc = doc || '- **Source task**:' sourceTask || '0a'x
   doc = doc || '- **Source adapter**:' adapter || '0a'x
   doc = doc || '- **Fossil ref**:' fossilRef || '0a'x
   doc = doc || '- **Timestamp**:' timestamp || '0a'x
   doc = doc || '- **Trace run ID**:' runId || '0a'x
   doc = doc || '0a'x

   /* Payload section */
   doc = doc || '## Payload' || '0a'x
   doc = doc || '- **Output file(s)**:' outputFiles || '0a'x
   doc = doc || '- **Record count**:' recordCount || '0a'x
   doc = doc || '- **Confidence**:' confidence || '0a'x
   doc = doc || '- **Summary**:' summary || '0a'x
   doc = doc || '0a'x

   /* Contract section */
   doc = doc || '## Contract' || '0a'x
   doc = doc || '- **Expected schema**:' schema || '0a'x

   /* Validation rules as bullet list */
   doc = doc || '- **Validation rules**:' || '0a'x
   remaining = validationRules
   DO WHILE remaining \= ''
      PARSE VAR remaining rule '0a'x remaining
      rule = STRIP(rule)
      IF rule \= '' THEN
         doc = doc || '  -' rule || '0a'x
   END

   doc = doc || '- **On validation failure**:' onFailure || '0a'x

   /* Write the file */
   CALL CHAROUT filePath, doc
   CALL STREAM filePath, 'C', 'CLOSE'

   RETURN filePath


/*====================================================================*/
/* HandoffReader — parses and validates handoff documents               */
/*====================================================================*/
::CLASS HandoffReader PUBLIC

/*--------------------------------------------------------------------*/
/* parse — read a handoff Markdown file and return a Directory         */
/*                                                                     */
/* Returns a Directory with keys:                                      */
/*   source_task, source_adapter, fossil_ref, timestamp, run_id,      */
/*   output_files, record_count, confidence, summary,                  */
/*   schema, validation_rules (array), on_failure                      */
/*--------------------------------------------------------------------*/
::METHOD parse CLASS
   USE ARG filePath

   ho = .Directory~new
   ho['source_task']    = ''
   ho['source_adapter'] = ''
   ho['fossil_ref']     = ''
   ho['timestamp']      = ''
   ho['run_id']         = ''
   ho['output_files']   = ''
   ho['record_count']   = 0
   ho['confidence']     = ''
   ho['summary']        = ''
   ho['schema']         = ''
   ho['validation_rules'] = .Array~new
   ho['on_failure']     = 'park'
   ho['file_path']      = filePath

   IF \SysFileExists(filePath) THEN RETURN ho

   content = CHARIN(filePath, 1, CHARS(filePath))
   CALL STREAM filePath, 'C', 'CLOSE'

   /* Extract fields using the Markdown bold-label pattern */
   ho['source_task']    = self~extractMdField(content, 'Source task')
   ho['source_adapter'] = self~extractMdField(content, 'Source adapter')
   ho['fossil_ref']     = self~extractMdField(content, 'Fossil ref')
   ho['timestamp']      = self~extractMdField(content, 'Timestamp')
   ho['run_id']         = self~extractMdField(content, 'Trace run ID')
   ho['output_files']   = self~extractMdField(content, 'Output file(s)')
   ho['record_count']   = self~extractMdField(content, 'Record count')
   ho['confidence']     = self~extractMdField(content, 'Confidence')
   ho['summary']        = self~extractMdField(content, 'Summary')
   ho['schema']         = self~extractMdField(content, 'Expected schema')
   ho['on_failure']     = self~extractMdField(content, 'On validation failure')

   /* Parse validation rules — indented bullets under Validation rules */
   rulesStart = POS('**Validation rules**:', content)
   IF rulesStart > 0 THEN DO
      chunk = SUBSTR(content, rulesStart)
      /* Skip the header line */
      nlPos = POS('0a'x, chunk)
      IF nlPos > 0 THEN chunk = SUBSTR(chunk, nlPos + 1)
      /* Collect indented bullet lines */
      DO WHILE chunk \= ''
         PARSE VAR chunk line '0a'x chunk
         line = STRIP(line)
         IF LEFT(line, 1) = '-' & LEFT(STRIP(line), 3) \= '- *' THEN
            ho['validation_rules']~append(STRIP(SUBSTR(line, 2)))
         ELSE IF line \= '' THEN LEAVE  /* non-bullet line = end of rules */
      END
   END

   RETURN ho


/*--------------------------------------------------------------------*/
/* validate — run validation checks on a parsed handoff                 */
/*                                                                     */
/* Checks:                                                             */
/*   1. Fossil ref exists                                              */
/*   2. Payload files exist at declared paths                          */
/*   3. Validation rules are satisfied (basic file-exists checks)      */
/*                                                                     */
/* Returns a Directory:                                                */
/*   result['ok']       — .true if all checks pass                    */
/*   result['errors']   — Array of error description strings          */
/*--------------------------------------------------------------------*/
::METHOD validate CLASS
   USE ARG ho

   result = .Directory~new
   result['ok'] = .true
   errors = .Array~new

   /* 1. Check Fossil ref exists */
   fossilRef = ho['fossil_ref']
   IF fossilRef \= '' & fossilRef \= 'N/A' THEN DO
      IF \(.FossilHelper~tagExists(fossilRef)) THEN DO
         errors~append('Fossil ref does not exist:' fossilRef)
         result['ok'] = .false
      END
   END

   /* 2. Check payload files exist */
   outputFiles = ho['output_files']
   IF outputFiles \= '' & outputFiles \= 'N/A' THEN DO
      remaining = outputFiles
      DO WHILE remaining \= ''
         PARSE VAR remaining oneFile remaining
         oneFile = STRIP(oneFile)
         IF oneFile = '' THEN ITERATE
         IF \SysFileExists(oneFile) THEN DO
            errors~append('Payload file missing:' oneFile)
            result['ok'] = .false
         END
      END
   END

   /* 3. Run validation rules                                         */
   /* Rules are human-readable strings; we support a few patterns:    */
   /*   "file exists: <path>"                                         */
   /*   "record count >= N"                                           */
   /*   "record count > 0"                                            */
   /* Unrecognised rules are logged as warnings but do not fail.      */
   rules = ho['validation_rules']
   IF rules~isA(.Array) THEN DO i = 1 TO rules~items
      rule = STRIP(rules[i])
      SELECT
         WHEN LEFT(rule, 13) = 'file exists: ' THEN DO
            path = STRIP(SUBSTR(rule, 14))
            IF \SysFileExists(path) THEN DO
               errors~append('Validation rule failed — file missing:' path)
               result['ok'] = .false
            END
         END
         WHEN LEFT(rule, 16) = 'record count >= ' THEN DO
            threshold = STRIP(SUBSTR(rule, 17))
            actual = ho['record_count']
            IF \DATATYPE(actual, 'W') THEN actual = 0
            IF \DATATYPE(threshold, 'W') THEN threshold = 0
            IF actual < threshold THEN DO
               errors~append('Validation rule failed — record count' actual '<' threshold)
               result['ok'] = .false
            END
         END
         WHEN rule = 'record count > 0' THEN DO
            actual = ho['record_count']
            IF \DATATYPE(actual, 'W') THEN actual = 0
            IF actual <= 0 THEN DO
               errors~append('Validation rule failed — record count is 0')
               result['ok'] = .false
            END
         END
         OTHERWISE
            /* Unrecognised rule — warn but do not fail */
            SAY '[handoff] Warning: unrecognised validation rule:' rule
      END
   END

   result['errors'] = errors
   RETURN result


/*--------------------------------------------------------------------*/
/* extractMdField — extract "**Label**: value" from Markdown           */
/*--------------------------------------------------------------------*/
::METHOD extractMdField CLASS PRIVATE
   USE ARG content, label
   marker = '**'label'**:'
   pos = POS(marker, content)
   IF pos = 0 THEN RETURN ''
   chunk = SUBSTR(content, pos + LENGTH(marker))
   PARSE VAR chunk value '0a'x .
   RETURN STRIP(value)
