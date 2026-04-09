#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* trace.rex — Observability and tracing for RalphClip                 */
/*                                                                     */
/* Produces per-run Markdown trace files with YAML-like frontmatter,   */
/* span-level detail for every task attempt/handoff/event, and cost    */
/* accounting from adapter token counts.                               */
/*                                                                     */
/* Usage:                                                              */
/*   CALL (ralphclipHome'/lib/trace.rex')                             */
/*   tracer = .TraceWriter~new(runId, tracesDir, costTable)           */
/*   tracer~start()                                                   */
/*   tracer~span(...)                                                  */
/*   tracer~finish()                                                   */
/*--------------------------------------------------------------------*/

::CLASS TraceWriter PUBLIC

::ATTRIBUTE runId       GET
::ATTRIBUTE tracesDir   GET
::ATTRIBUTE traceFile   GET
::ATTRIBUTE startTime   GET
::ATTRIBUTE costTable   GET

/* Accumulators */
::ATTRIBUTE totalTokenIn   GET
::ATTRIBUTE totalTokenOut  GET
::ATTRIBUTE totalCost      GET
::ATTRIBUTE tasksTotal     GET
::ATTRIBUTE tasksOk        GET
::ATTRIBUTE tasksParked    GET
::ATTRIBUTE tasksSkipped   GET
::ATTRIBUTE adaptersUsed   GET

/*--------------------------------------------------------------------*/
/* init — construct a trace writer for one orchestration run            */
/*                                                                     */
/* costTable is a Directory of Directories:                            */
/*   costTable['claude-code']['input']  = 3.00                        */
/*   costTable['claude-code']['output'] = 15.00                       */
/* (rates per million tokens)                                          */
/*--------------------------------------------------------------------*/
::METHOD init
   EXPOSE runId tracesDir traceFile startTime costTable ,
          totalTokenIn totalTokenOut totalCost ,
          tasksTotal tasksOk tasksParked tasksSkipped adaptersUsed ,
          spanBuffer
   USE ARG runId, tracesDir, costTable

   traceFile = tracesDir'/'runId'.md'
   startTime = ''
   totalTokenIn  = 0
   totalTokenOut = 0
   totalCost     = 0
   tasksTotal    = 0
   tasksOk       = 0
   tasksParked   = 0
   tasksSkipped  = 0
   adaptersUsed  = ''
   spanBuffer    = ''


/*--------------------------------------------------------------------*/
/* start — initialise the trace file and record the start timestamp    */
/*--------------------------------------------------------------------*/

/*--------------------------------------------------------------------*/
/* start — record the start timestamp (no file write yet)              */
/*--------------------------------------------------------------------*/
::METHOD start
   EXPOSE tracesDir startTime
   ADDRESS SYSTEM 'mkdir -p' tracesDir
   startTime = .FossilHelper~isoTimestamp()
   RETURN


/*--------------------------------------------------------------------*/
/* span — buffer a span block (thread-safe via GUARDED)                */
/*--------------------------------------------------------------------*/
::METHOD span GUARDED
   EXPOSE totalTokenIn totalTokenOut totalCost ,
          tasksTotal tasksOk tasksParked tasksSkipped adaptersUsed ,
          costTable spanBuffer
   USE ARG spanName, adapter, startTs, durationMs, tokensIn, tokensOut, ,
           status, errorInfo, fossilRef, extra

   IF \DATATYPE(durationMs, 'N') THEN durationMs = 0
   IF \DATATYPE(tokensIn, 'N')   THEN tokensIn = 0
   IF \DATATYPE(tokensOut, 'N')  THEN tokensOut = 0

   totalTokenIn  = totalTokenIn + tokensIn
   totalTokenOut = totalTokenOut + tokensOut

   spanCost = self~calculateCost(adapter, tokensIn, tokensOut)
   totalCost = totalCost + spanCost

   IF adapter \= '' & WORDPOS(adapter, adaptersUsed) = 0 THEN
      adaptersUsed = STRIP(adaptersUsed adapter)

   durationSec = FORMAT(durationMs / 1000,, 1)

   block = '## Span:' spanName || '0a'x
   IF adapter \= '' THEN
      block = block || '- **Adapter**:' adapter || '0a'x
   block = block || '- **Start**:' startTs || '0a'x
   block = block || '- **Duration**:' durationSec's' || '0a'x
   IF tokensIn > 0 | tokensOut > 0 THEN
      block = block || '- **Tokens**:' tokensIn 'in /' tokensOut 'out' || '0a'x
   IF spanCost > 0 THEN
      block = block || '- **Cost**: $'FORMAT(spanCost,,6) || '0a'x
   block = block || '- **Status**:' status || '0a'x

   IF status = 'error' | status = 'parked' THEN DO
      IF POS(':', errorInfo) > 0 THEN DO
         PARSE VAR errorInfo errClass ':' errMsg
         block = block || '- **Error class**:' STRIP(errClass) || '0a'x
         block = block || '- **Error**:' STRIP(errMsg) || '0a'x
      END
      ELSE IF errorInfo \= '' THEN
         block = block || '- **Error**:' errorInfo || '0a'x
   END

   IF fossilRef \= '' THEN
      block = block || '- **Fossil ref**:' fossilRef || '0a'x
   IF ARG(10, 'E') & extra \= '' THEN
      block = block || '- **Notes**:' extra || '0a'x

   block = block || '0a'x

   /* Buffer — no file I/O until finish() */
   spanBuffer = spanBuffer || block
   RETURN


/*--------------------------------------------------------------------*/
/* countTask — increment task counters (thread-safe via GUARDED)        */
/*--------------------------------------------------------------------*/
::METHOD countTask GUARDED
   EXPOSE tasksTotal tasksOk tasksParked tasksSkipped
   USE ARG outcome
   tasksTotal = tasksTotal + 1
   SELECT
      WHEN outcome = 'ok'      THEN tasksOk = tasksOk + 1
      WHEN outcome = 'parked'  THEN tasksParked = tasksParked + 1
      WHEN outcome = 'skipped' THEN tasksSkipped = tasksSkipped + 1
      OTHERWISE NOP
   END
   RETURN


/*--------------------------------------------------------------------*/
/* finish — assemble header + buffered spans, single atomic write      */
/*--------------------------------------------------------------------*/
::METHOD finish
   EXPOSE traceFile runId startTime spanBuffer ,
          totalTokenIn totalTokenOut totalCost ,
          tasksTotal tasksOk tasksParked tasksSkipped adaptersUsed

   endTime = .FossilHelper~isoTimestamp()
   durationSec = self~secondsBetween(startTime, endTime)

   adapterList = '['
   DO w = 1 TO WORDS(adaptersUsed)
      IF w > 1 THEN adapterList = adapterList || ', '
      adapterList = adapterList || '"'WORD(adaptersUsed, w)'"'
   END
   adapterList = adapterList || ']'

   /* Assemble complete file in memory */
   doc = '---' || '0a'x
   doc = doc || 'run_id: "'runId'"' || '0a'x
   doc = doc || 'start: "'startTime'"' || '0a'x
   doc = doc || 'end: "'endTime'"' || '0a'x
   doc = doc || 'duration_seconds:' durationSec || '0a'x
   doc = doc || 'total_token_in:' totalTokenIn || '0a'x
   doc = doc || 'total_token_out:' totalTokenOut || '0a'x
   doc = doc || 'total_cost_estimate_usd:' FORMAT(totalCost,,3) || '0a'x
   doc = doc || 'tasks_total:' tasksTotal || '0a'x
   doc = doc || 'tasks_ok:' tasksOk || '0a'x
   doc = doc || 'tasks_parked:' tasksParked || '0a'x
   doc = doc || 'tasks_skipped:' tasksSkipped || '0a'x
   doc = doc || 'adapters_used:' adapterList || '0a'x
   doc = doc || '---' || '0a'x
   doc = doc || '0a'x
   doc = doc || '# Trace:' runId || '0a'x
   doc = doc || '0a'x
   doc = doc || spanBuffer

   /* Single atomic write — no read-modify-write, no delimiter parsing */
   IF SysFileExists(traceFile) THEN CALL SysFileDelete traceFile
   CALL CHAROUT traceFile, doc
   CALL STREAM traceFile, 'C', 'CLOSE'

   commitMsg = '[trace] run:'runId 'tasks:'tasksOk'/'tasksTotal ,
               'cost:$'FORMAT(totalCost,,3)
   CALL .FossilHelper~commitAll commitMsg
   RETURN

::METHOD calculateCost PRIVATE
   EXPOSE costTable
   USE ARG adapter, tokensIn, tokensOut

   IF adapter = '' THEN RETURN 0
   IF \costTable~hasIndex(adapter) THEN RETURN 0

   rates = costTable[adapter]
   IF \rates~isA(.Directory) THEN RETURN 0

   inputRate  = 0
   outputRate = 0
   IF rates~hasIndex('input')  THEN inputRate  = rates['input']
   IF rates~hasIndex('output') THEN outputRate = rates['output']

   /* Rates are per million tokens */
   cost = (tokensIn * inputRate / 1000000) + (tokensOut * outputRate / 1000000)
   RETURN cost


/*--------------------------------------------------------------------*/
/* secondsBetween — rough seconds between two ISO 8601 timestamps      */
/* Not timezone-aware — assumes both are UTC.                          */
/*--------------------------------------------------------------------*/
::METHOD secondsBetween PRIVATE
   USE ARG ts1, ts2
   s1 = self~isoToEpochApprox(ts1)
   s2 = self~isoToEpochApprox(ts2)
   diff = s2 - s1
   IF diff < 0 THEN diff = 0
   RETURN diff


/*--------------------------------------------------------------------*/
/* isoToEpochApprox — convert ISO 8601 to approximate epoch seconds    */
/* Good enough for duration calculation within a single run.           */
/*--------------------------------------------------------------------*/
::METHOD isoToEpochApprox PRIVATE
   USE ARG ts
   /* Parse: 2026-04-09T14:23:00Z */
   PARSE VAR ts year '-' month '-' day 'T' hour ':' minute ':' second 'Z'
   IF \DATATYPE(year, 'W') THEN RETURN 0
   /* Approximate: ignore leap years, just need delta */
   epoch = year * 31536000 ,
         + month * 2592000 ,
         + day * 86400 ,
         + hour * 3600 ,
         + minute * 60 ,
         + second
   RETURN epoch


/*--------------------------------------------------------------------*/
/* buildCostTable — parse cost_per_million_tokens from a config Dir     */
/* Returns a Directory of Directories suitable for the TraceWriter.    */
/*                                                                     */
/* Expects TOML keys like:                                             */
/*   cost_per_million_tokens.claude-code.input = 3.00                 */
/*   cost_per_million_tokens.claude-code.output = 15.00               */
/*                                                                     */
/* If not present in config, returns sensible defaults.                */
/*--------------------------------------------------------------------*/
::METHOD buildCostTable CLASS
   USE ARG config

   costTable = .Directory~new

   /* Default cost table */
   defaults = .Array~of( ,
      'claude-code',  3.00,  15.00, ,
      'gemini-cli',   0.50,   1.50, ,
      'mistral-vibe', 0.25,   0.75, ,
      'minimax',      0.10,   0.30, ,
      'trinity-mini', 0.045,  0.15, ,
      'trinity-large', 0.50,  0.90, ,
      'bash',         0.00,   0.00, ,
      'oorexx',       0.00,   0.00, ,
      'mcp-bridge',   0.00,   0.00  )

   /* Populate defaults */
   DO i = 1 TO defaults~items BY 3
      name = defaults[i]
      entry = .Directory~new
      entry['input']  = defaults[i+1]
      entry['output'] = defaults[i+2]
      costTable[name] = entry
   END

   /* Override from config if present */
   IF config \= .nil THEN DO
      supplier = config~supplier
      DO WHILE supplier~available
         key = supplier~index
         IF LEFT(key, 25) = 'cost_per_million_tokens.' THEN DO
            rest = SUBSTR(key, 26)
            PARSE VAR rest adapterName '.' field
            IF \costTable~hasIndex(adapterName) THEN DO
               entry = .Directory~new
               costTable[adapterName] = entry
            END
            ELSE
               entry = costTable[adapterName]
            val = supplier~item
            IF DATATYPE(val, 'N') THEN entry[field] = val
         END
         supplier~next
      END
   END

   RETURN costTable
