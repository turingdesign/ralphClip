#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* adapters.rex — CLI adapter layer for RalphClip                      */
/*                                                                     */
/* Normalises invocation and output parsing across all supported        */
/* runtimes: Claude Code, Mistral Vibe, Gemini CLI, Trinity,          */
/* shell scripts, ooRexx scripts, and MCP bridge (stub).              */
/*                                                                     */
/* Every adapter returns a standardised result Directory:              */
/*   result['ok']            — .true / .false                         */
/*   result['error_class']   — "transient"|"semantic"|"fatal"|.nil    */
/*   result['error_message'] — human-readable error string            */
/*   result['output']        — text output from the agent             */
/*   result['duration_ms']   — wall-clock execution time (integer)    */
/*   result['token_in']      — input token count (0 for non-AI)       */
/*   result['token_out']     — output token count (0 for non-AI)      */
/*   result['complete']      — 1 if <promise>COMPLETE</promise> found */
/*   result['cost']          — estimated cost in USD (legacy compat)  */
/*                                                                     */
/* Error classification:                                               */
/*   transient — timeout, rate limit, temporary API error → retry     */
/*   semantic  — malformed output, schema violation → retry + context */
/*   fatal     — auth failure, missing tool, unsupported → park now   */
/*--------------------------------------------------------------------*/

::CLASS AgentAdapter PUBLIC

::ATTRIBUTE runtime   GET
::ATTRIBUTE model     GET
::ATTRIBUTE workingDir GET
::ATTRIBUTE scriptPath GET
::ATTRIBUTE ticketId  GET

/*--------------------------------------------------------------------*/
/* init — construct an adapter for a specific agent                    */
/*--------------------------------------------------------------------*/
::METHOD init
   EXPOSE runtime model workingDir scriptPath ticketId
   USE ARG runtime, model, workingDir
   scriptPath = ''
   ticketId = ''

::METHOD 'scriptPath='
   EXPOSE scriptPath
   USE ARG scriptPath

::METHOD 'ticketId='
   EXPOSE ticketId
   USE ARG ticketId

/*--------------------------------------------------------------------*/
/* run — dispatch to the correct runtime, return normalised result     */
/*--------------------------------------------------------------------*/
::METHOD run
   EXPOSE runtime
   USE ARG prompt

   /* Start timing */
   CALL TIME 'R'

   SELECT
      WHEN runtime = 'claude'       THEN result = self~runClaude(prompt)
      WHEN runtime = 'claude-code'  THEN result = self~runClaude(prompt)
      WHEN runtime = 'mistral'      THEN result = self~runMistral(prompt)
      WHEN runtime = 'mistral-vibe' THEN result = self~runMistral(prompt)
      WHEN runtime = 'gemini'       THEN result = self~runGemini(prompt)
      WHEN runtime = 'gemini-cli'   THEN result = self~runGemini(prompt)
      WHEN runtime = 'trinity'      THEN result = self~runTrinity(prompt)
      WHEN runtime = 'minimax'      THEN result = self~runMinimax(prompt)
      WHEN runtime = 'script'       THEN result = self~runScript(prompt)
      WHEN runtime = 'bash'         THEN result = self~runScript(prompt)
      WHEN runtime = 'rexx'         THEN result = self~runRexx(prompt)
      WHEN runtime = 'oorexx'       THEN result = self~runRexx(prompt)
      WHEN runtime = 'mcp-bridge'   THEN result = self~runMcpBridge(prompt)
      OTHERWISE DO
         result = self~makeResult(.false, 'fatal', -
                     'Unknown runtime:' runtime, '', 0, 0, 0)
         RETURN result
      END
   END

   /* Fill in duration if not already set */
   elapsed = TIME('E')
   IF \result~hasIndex('duration_ms') | result['duration_ms'] = 0 THEN
      result['duration_ms'] = TRUNC(elapsed * 1000)

   /* Universal completion check */
   IF result~hasIndex('output') THEN
      result['complete'] = (POS('<promise>COMPLETE</promise>', result['output']) > 0)
   ELSE
      result['complete'] = 0

   /* Legacy compat: populate 'success' from 'ok' */
   IF result['ok'] THEN result['success'] = 1
   ELSE result['success'] = 0

   RETURN result


/*--------------------------------------------------------------------*/
/* makeResult — construct a standardised result Directory              */
/*--------------------------------------------------------------------*/
::METHOD makeResult PRIVATE
   USE ARG ok, errorClass, errorMessage, output, durationMs, tokenIn, tokenOut
   result = .Directory~new
   result['ok']            = ok
   result['error_class']   = errorClass
   result['error_message'] = errorMessage
   result['output']        = output
   result['duration_ms']   = durationMs
   result['token_in']      = tokenIn
   result['token_out']     = tokenOut
   result['complete']      = 0
   result['cost']          = 0
   RETURN result


/*--------------------------------------------------------------------*/
/* classifyShellError — determine error class from shell return code   */
/* and output content                                                  */
/*--------------------------------------------------------------------*/
::METHOD classifyShellError PRIVATE
   USE ARG rc, output

   /* Timeout (from the timeout command) */
   IF rc = 124 THEN RETURN 'transient'

   /* Check output for known transient patterns */
   upper = TRANSLATE(output)
   IF POS('RATE LIMIT', upper) > 0       THEN RETURN 'transient'
   IF POS('429', output) > 0             THEN RETURN 'transient'
   IF POS('503', output) > 0             THEN RETURN 'transient'
   IF POS('502', output) > 0             THEN RETURN 'transient'
   IF POS('TIMEOUT', upper) > 0          THEN RETURN 'transient'
   IF POS('ECONNRESET', upper) > 0       THEN RETURN 'transient'
   IF POS('TEMPORARY', upper) > 0        THEN RETURN 'transient'

   /* Fatal patterns */
   IF POS('AUTH', upper) > 0 & POS('FAIL', upper) > 0 THEN RETURN 'fatal'
   IF POS('401', output) > 0             THEN RETURN 'fatal'
   IF POS('403', output) > 0             THEN RETURN 'fatal'
   IF POS('PERMISSION DENIED', upper) > 0 THEN RETURN 'fatal'
   IF POS('NOT FOUND', upper) > 0 & POS('COMMAND', upper) > 0 THEN RETURN 'fatal'
   IF POS('NO SUCH FILE', upper) > 0     THEN RETURN 'fatal'

   /* Default: treat unknown errors as transient (allow retry) */
   RETURN 'transient'


/*--------------------------------------------------------------------*/
/* classifyOutputQuality — check for semantic issues in output         */
/* Returns 'semantic' if output looks malformed, '' otherwise          */
/*--------------------------------------------------------------------*/
::METHOD classifyOutputQuality PRIVATE
   USE ARG output
   IF LENGTH(output) < 30 & output \= '' THEN RETURN 'semantic'
   IF STRIP(output) = '' THEN RETURN 'semantic'
   RETURN ''


/*--------------------------------------------------------------------*/
/* Claude Code adapter                                                 */
/* Uses: claude -p --model <model> < prompt_file                      */
/*--------------------------------------------------------------------*/
::METHOD runClaude PRIVATE
   EXPOSE model workingDir
   USE ARG prompt

   tmpFile = self~writeTempPrompt(prompt)

   cmdLine = 'cd' workingDir '&&' -
             'claude -p' -
             '--model "' || model || '"' -
             '--dangerously-skip-permissions' -
             '<' tmpFile -
             '2>&1'

   cmdLine = 'timeout 600' cmdLine  /* 10 minute hard kill */

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   output = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   cost = self~parseCostFromOutput(output, 'cost: $')
   tokenIn  = self~parseIntFromOutput(output, 'Input tokens:')
   tokenOut = self~parseIntFromOutput(output, 'Output tokens:')

   IF shellRc = 0 THEN DO
      semantic = self~classifyOutputQuality(output)
      IF semantic \= '' THEN
         result = self~makeResult(.false, 'semantic', -
                     'Suspiciously short or empty output', output, -
                     durationMs, tokenIn, tokenOut)
      ELSE
         result = self~makeResult(.true, .nil, '', output, -
                     durationMs, tokenIn, tokenOut)
   END
   ELSE DO
      errClass = self~classifyShellError(shellRc, output)
      errMsg = self~firstErrorLine(output)
      result = self~makeResult(.false, errClass, errMsg, output, -
                  durationMs, tokenIn, tokenOut)
   END

   result['cost'] = cost
   CALL SysFileDelete tmpFile
   RETURN result


/*--------------------------------------------------------------------*/
/* Mistral Vibe adapter                                                */
/* Uses: vibe --prompt "..." --max-turns N --max-price $               */
/*--------------------------------------------------------------------*/
::METHOD runMistral PRIVATE
   EXPOSE model workingDir
   USE ARG prompt

   tmpFile = self~writeTempPrompt(prompt)

   cmdLine = 'cd' workingDir '&&' -
             'vibe --prompt "$(cat' tmpFile ')"' -
             '--max-turns 50' -
             '--max-price 0.50' -
             '2>&1'

   cmdLine = 'timeout 300' cmdLine

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   output = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   cost = self~parseCostFromOutput(output, 'Total cost: $')
   IF cost = 0 THEN cost = self~parseCostFromOutput(output, 'cost: $')
   tokenIn  = self~parseIntFromOutput(output, 'Input tokens:')
   tokenOut = self~parseIntFromOutput(output, 'Output tokens:')

   IF shellRc = 0 THEN DO
      semantic = self~classifyOutputQuality(output)
      IF semantic \= '' THEN
         result = self~makeResult(.false, 'semantic', -
                     'Suspiciously short or empty output', output, -
                     durationMs, tokenIn, tokenOut)
      ELSE
         result = self~makeResult(.true, .nil, '', output, -
                     durationMs, tokenIn, tokenOut)
   END
   ELSE DO
      errClass = self~classifyShellError(shellRc, output)
      errMsg = self~firstErrorLine(output)
      result = self~makeResult(.false, errClass, errMsg, output, -
                  durationMs, tokenIn, tokenOut)
   END

   result['cost'] = cost
   CALL SysFileDelete tmpFile
   RETURN result


/*--------------------------------------------------------------------*/
/* Gemini CLI adapter                                                  */
/* Uses: gemini -p "..." --yolo                                        */
/*--------------------------------------------------------------------*/
::METHOD runGemini PRIVATE
   EXPOSE model workingDir
   USE ARG prompt

   tmpFile = self~writeTempPrompt(prompt)

   cmdLine = 'cd' workingDir '&&' -
             'gemini -p "$(cat' tmpFile ')"' -
             '--yolo' -
             '2>&1'

   cmdLine = 'timeout 300' cmdLine

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   output = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   words = WORDS(output)
   tokenOut = TRUNC(words * 1.3)
   tokenIn  = 0
   cost = self~estimateTokenCost(output, 0.000000075)

   IF shellRc = 0 THEN DO
      semantic = self~classifyOutputQuality(output)
      IF semantic \= '' THEN
         result = self~makeResult(.false, 'semantic', -
                     'Suspiciously short or empty output', output, -
                     durationMs, tokenIn, tokenOut)
      ELSE
         result = self~makeResult(.true, .nil, '', output, -
                     durationMs, tokenIn, tokenOut)
   END
   ELSE DO
      errClass = self~classifyShellError(shellRc, output)
      errMsg = self~firstErrorLine(output)
      result = self~makeResult(.false, errClass, errMsg, output, -
                  durationMs, tokenIn, tokenOut)
   END

   result['cost'] = cost
   CALL SysFileDelete tmpFile
   RETURN result


/*--------------------------------------------------------------------*/
/* Trinity (Arcee AI) adapter                                          */
/* Uses OpenRouter API via curl.                                       */
/*--------------------------------------------------------------------*/
::METHOD runTrinity PRIVATE
   EXPOSE model workingDir
   USE ARG prompt

   tmpFile = self~writeTempPrompt(prompt)

   SELECT
      WHEN model = 'trinity-mini' THEN orModel = 'arcee-ai/trinity-mini'
      WHEN model = 'trinity-large' THEN orModel = 'arcee-ai/trinity-large-preview'
      WHEN model = 'trinity-large-thinking' THEN orModel = 'arcee-ai/trinity-large-thinking'
      OTHERWISE orModel = 'arcee-ai/' || model
   END

   cmdLine = 'cd' workingDir '&&' -
      'curl -s https://openrouter.ai/api/v1/chat/completions' -
      '-H "Authorization: Bearer $OPENROUTER_API_KEY"' -
      '-H "Content-Type: application/json"' -
      '-d "$(jq -n --arg model "' || orModel || '"' -
      '--rawfile prompt' tmpFile -
      "'{model: $model, messages: [{role: ""user"", content: $prompt}], max_tokens: 16000}')" -
      '2>&1'

   cmdLine = 'timeout 600' cmdLine

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   rawOutput = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   output = self~extractJsonField(rawOutput, 'content')
   IF output = '' THEN output = rawOutput

   tokenOut = self~extractJsonField(rawOutput, 'completion_tokens')
   tokenIn  = self~extractJsonField(rawOutput, 'prompt_tokens')
   IF \DATATYPE(tokenOut, 'W') THEN tokenOut = 0
   IF \DATATYPE(tokenIn, 'W') THEN tokenIn = 0

   SELECT
      WHEN POS('mini', model) > 0 THEN
         cost = FORMAT(tokenIn * 0.000000045 + tokenOut * 0.00000015,, 6)
      OTHERWISE
         cost = FORMAT(tokenIn * 0.0000005 + tokenOut * 0.0000009,, 6)
   END

   apiError = self~extractJsonField(rawOutput, 'error')

   IF shellRc = 0 & apiError = '' THEN DO
      semantic = self~classifyOutputQuality(output)
      IF semantic \= '' THEN
         result = self~makeResult(.false, 'semantic', -
                     'Suspiciously short or empty output', output, -
                     durationMs, tokenIn, tokenOut)
      ELSE
         result = self~makeResult(.true, .nil, '', output, -
                     durationMs, tokenIn, tokenOut)
   END
   ELSE DO
      IF apiError \= '' THEN DO
         errClass = self~classifyShellError(0, apiError)
         result = self~makeResult(.false, errClass, apiError, rawOutput, -
                     durationMs, tokenIn, tokenOut)
      END
      ELSE DO
         errClass = self~classifyShellError(shellRc, rawOutput)
         errMsg = self~firstErrorLine(rawOutput)
         result = self~makeResult(.false, errClass, errMsg, rawOutput, -
                     durationMs, tokenIn, tokenOut)
      END
   END

   result['cost'] = cost
   CALL SysFileDelete tmpFile
   RETURN result


/*--------------------------------------------------------------------*/
/* MiniMax adapter                                                     */
/* OpenRouter pattern, same as Trinity.                                */
/*--------------------------------------------------------------------*/
::METHOD runMinimax PRIVATE
   EXPOSE model workingDir
   USE ARG prompt

   tmpFile = self~writeTempPrompt(prompt)

   orModel = 'minimax/' || model
   cmdLine = 'cd' workingDir '&&' -
      'curl -s https://openrouter.ai/api/v1/chat/completions' -
      '-H "Authorization: Bearer $OPENROUTER_API_KEY"' -
      '-H "Content-Type: application/json"' -
      '-d "$(jq -n --arg model "' || orModel || '"' -
      '--rawfile prompt' tmpFile -
      "'{model: $model, messages: [{role: ""user"", content: $prompt}], max_tokens: 16000}')" -
      '2>&1'

   cmdLine = 'timeout 300' cmdLine

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   rawOutput = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   output = self~extractJsonField(rawOutput, 'content')
   IF output = '' THEN output = rawOutput

   tokenOut = self~extractJsonField(rawOutput, 'completion_tokens')
   tokenIn  = self~extractJsonField(rawOutput, 'prompt_tokens')
   IF \DATATYPE(tokenOut, 'W') THEN tokenOut = 0
   IF \DATATYPE(tokenIn, 'W') THEN tokenIn = 0

   cost = FORMAT(tokenIn * 0.0000001 + tokenOut * 0.0000003,, 6)
   apiError = self~extractJsonField(rawOutput, 'error')

   IF shellRc = 0 & apiError = '' THEN
      result = self~makeResult(.true, .nil, '', output, -
                  durationMs, tokenIn, tokenOut)
   ELSE DO
      errClass = self~classifyShellError(shellRc, rawOutput || apiError)
      errMsg = self~firstErrorLine(rawOutput)
      result = self~makeResult(.false, errClass, errMsg, rawOutput, -
                  durationMs, tokenIn, tokenOut)
   END

   result['cost'] = cost
   CALL SysFileDelete tmpFile
   RETURN result


/*--------------------------------------------------------------------*/
/* Shell script adapter                                                */
/* Runs: bash <script> with env vars set                               */
/*--------------------------------------------------------------------*/
::METHOD runScript PRIVATE
   EXPOSE workingDir scriptPath ticketId
   USE ARG prompt

   CALL VALUE 'RALPHCLIP_WORKING_DIR', workingDir, 'ENVIRONMENT'
   CALL VALUE 'RALPHCLIP_TICKET_ID', ticketId, 'ENVIRONMENT'

   cmdLine = 'cd' workingDir '&& bash "' || scriptPath || '" 2>&1'
   cmdLine = 'timeout 120' cmdLine

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   output = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   IF shellRc = 0 THEN
      result = self~makeResult(.true, .nil, '', output, durationMs, 0, 0)
   ELSE DO
      errClass = self~classifyShellError(shellRc, output)
      errMsg = self~firstErrorLine(output)
      result = self~makeResult(.false, errClass, errMsg, output, durationMs, 0, 0)
   END

   result['cost'] = 0
   RETURN result


/*--------------------------------------------------------------------*/
/* ooRexx script adapter                                               */
/* Runs: rexx <script> with env vars set                               */
/*--------------------------------------------------------------------*/
::METHOD runRexx PRIVATE
   EXPOSE workingDir scriptPath ticketId
   USE ARG prompt

   CALL VALUE 'RALPHCLIP_WORKING_DIR', workingDir, 'ENVIRONMENT'
   CALL VALUE 'RALPHCLIP_TICKET_ID', ticketId, 'ENVIRONMENT'
   CALL VALUE 'RALPHCLIP_PROMPT', prompt, 'ENVIRONMENT'

   cmdLine = 'cd' workingDir '&& rexx "' || scriptPath || '" 2>&1'
   cmdLine = 'timeout 120' cmdLine

   CALL TIME 'R'
   ADDRESS SYSTEM cmdLine WITH OUTPUT STEM out.
   shellRc = RC
   elapsed = TIME('E')

   output = self~stemToString(out.)
   durationMs = TRUNC(elapsed * 1000)

   IF shellRc = 0 THEN
      result = self~makeResult(.true, .nil, '', output, durationMs, 0, 0)
   ELSE DO
      errClass = self~classifyShellError(shellRc, output)
      errMsg = self~firstErrorLine(output)
      result = self~makeResult(.false, errClass, errMsg, output, durationMs, 0, 0)
   END

   result['cost'] = 0
   RETURN result


/*--------------------------------------------------------------------*/
/* MCP Bridge adapter (stub)                                           */
/*                                                                     */
/* Accepts tasks, translates to MCP JSON-RPC tools/call shape, logs   */
/* the would-be request to debug/mcp_dry_run/, returns fatal until     */
/* a real server URL is configured.                                    */
/*--------------------------------------------------------------------*/
::METHOD runMcpBridge PRIVATE
   EXPOSE model workingDir
   USE ARG prompt

   dryRunDir = 'debug/mcp_dry_run'
   ADDRESS SYSTEM 'mkdir -p' dryRunDir

   timestamp = .FossilHelper~isoTimestampCompact()

   mcpRequest = '{' || '0a'x
   mcpRequest = mcpRequest || '  "jsonrpc": "2.0",' || '0a'x
   mcpRequest = mcpRequest || '  "method": "tools/call",' || '0a'x
   mcpRequest = mcpRequest || '  "params": {' || '0a'x
   mcpRequest = mcpRequest || '    "name": "ralphclip_task",' || '0a'x
   mcpRequest = mcpRequest || '    "arguments": {' || '0a'x
   mcpRequest = mcpRequest || '      "prompt": "<see attached prompt file>",' || '0a'x
   mcpRequest = mcpRequest || '      "working_dir": "'workingDir'",' || '0a'x
   mcpRequest = mcpRequest || '      "model": "'model'"' || '0a'x
   mcpRequest = mcpRequest || '    }' || '0a'x
   mcpRequest = mcpRequest || '  },' || '0a'x
   mcpRequest = mcpRequest || '  "id": "dry-run-'timestamp'"' || '0a'x
   mcpRequest = mcpRequest || '}' || '0a'x

   dryRunFile = dryRunDir'/mcp_request_'timestamp'.json'
   CALL CHAROUT dryRunFile, mcpRequest
   CALL STREAM dryRunFile, 'C', 'CLOSE'

   promptFile = dryRunDir'/mcp_prompt_'timestamp'.md'
   CALL CHAROUT promptFile, prompt
   CALL STREAM promptFile, 'C', 'CLOSE'

   SAY '[mcp-bridge] Dry run logged to' dryRunFile

   result = self~makeResult(.false, 'fatal', -
               'MCP bridge not yet connected', -
               'MCP dry run: request logged to' dryRunFile, -
               0, 0, 0)
   result['cost'] = 0
   RETURN result


/*--------------------------------------------------------------------*/
/* Utility methods                                                     */
/*--------------------------------------------------------------------*/

::METHOD writeTempPrompt PRIVATE
   USE ARG prompt
   tmpFile = .FossilHelper~safeTmpFile('prompt')
   CALL CHAROUT tmpFile, prompt
   CALL STREAM tmpFile, 'C', 'CLOSE'
   RETURN tmpFile

::METHOD stemToString PRIVATE
   USE ARG lines.
   s = ''
   DO j = 1 TO lines.0
      s = s || lines.j || '0a'x
   END
   RETURN s

::METHOD parseCostFromOutput PRIVATE
   USE ARG output, marker
   costPos = LASTPOS(marker, output)
   IF costPos = 0 THEN RETURN 0
   chunk = SUBSTR(output, costPos + LENGTH(marker))
   PARSE VAR chunk cost .
   cleanCost = ''
   DO i = 1 TO LENGTH(cost)
      c = SUBSTR(cost, i, 1)
      IF DATATYPE(c, 'N') | c = '.' THEN cleanCost = cleanCost || c
      ELSE LEAVE
   END
   IF DATATYPE(cleanCost, 'N') THEN RETURN cleanCost
   RETURN 0

::METHOD parseIntFromOutput PRIVATE
   USE ARG output, marker
   pos = POS(marker, output)
   IF pos = 0 THEN RETURN 0
   chunk = SUBSTR(output, pos + LENGTH(marker))
   PARSE VAR chunk val .
   val = STRIP(val)
   IF DATATYPE(val, 'W') THEN RETURN val
   RETURN 0

::METHOD estimateTokenCost PRIVATE
   USE ARG output, costPerToken
   words = WORDS(output)
   tokens = TRUNC(words * 1.3)
   RETURN FORMAT(tokens * costPerToken,, 6)

::METHOD firstErrorLine PRIVATE
   USE ARG output
   remaining = output
   DO WHILE remaining \= ''
      PARSE VAR remaining line '0a'x remaining
      line = STRIP(line)
      IF line \= '' THEN RETURN LEFT(line, MIN(LENGTH(line), 200))
   END
   RETURN 'Unknown error'

::METHOD extractJsonField PRIVATE
   USE ARG json, fieldName
   marker = '"' || fieldName || '"'
   pos = POS(marker, json)
   IF pos = 0 THEN RETURN ''
   chunk = SUBSTR(json, pos + LENGTH(marker))
   PARSE VAR chunk ':' rest
   rest = STRIP(rest)
   IF LEFT(rest, 1) = '"' THEN DO
      val = ''; escaped = 0
      DO i = 2 TO LENGTH(rest)
         c = SUBSTR(rest, i, 1)
         IF escaped THEN DO
            IF c = 'n' THEN val = val || '0a'x
            ELSE IF c = 't' THEN val = val || '09'x
            ELSE val = val || c
            escaped = 0
         END
         ELSE IF c = '\' THEN escaped = 1
         ELSE IF c = '"' THEN LEAVE
         ELSE val = val || c
      END
      RETURN val
   END
   ELSE DO
      numVal = ''
      DO i = 1 TO LENGTH(rest)
         c = SUBSTR(rest, i, 1)
         IF DATATYPE(c, 'N') | c = '.' | c = '-' THEN numVal = numVal || c
         ELSE LEAVE
      END
      RETURN numVal
   END


/*====================================================================*/
/* BackoffHelper — static backoff/wait utility                         */
/*====================================================================*/
::CLASS BackoffHelper PUBLIC

/*--------------------------------------------------------------------*/
/* wait — sleep for the appropriate backoff interval                   */
/*                                                                     */
/* strategy: "fixed" | "linear" | "exponential"                       */
/* baseSec:  base wait time in seconds                                */
/* attempt:  current attempt number (1-based)                         */
/*--------------------------------------------------------------------*/
::METHOD wait CLASS
   USE ARG strategy, baseSec, attempt

   IF \DATATYPE(baseSec, 'N') THEN baseSec = 5
   IF baseSec = 0 THEN RETURN

   SELECT
      WHEN strategy = 'exponential' THEN DO
         power = 1
         DO i = 1 TO attempt - 1
            power = power * 2
         END
         waitSec = MIN(power * baseSec, 300)
      END
      WHEN strategy = 'linear' THEN
         waitSec = MIN(attempt * baseSec, 300)
      OTHERWISE  /* fixed */
         waitSec = baseSec
   END

   SAY '[backoff] Waiting' waitSec 'seconds (strategy:' strategy', attempt:' attempt')'
   ADDRESS SYSTEM 'sleep' waitSec
   RETURN
