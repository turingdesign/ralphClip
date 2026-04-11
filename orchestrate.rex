#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* orchestrate.rex — RalphClip main orchestration loop                 */
/*                                                                     */
/* Ralph's simplicity meets Paperclip's organisational structure.       */
/* Reads company.toml, queries Fossil tickets, dispatches agents,      */
/* enforces budgets and governance, logs everything.                    */
/*                                                                     */
/* v2.0 — Error recovery, handoff protocol, observability.            */
/*                                                                     */
/* Usage: rexx orchestrate.rex [company_toml_path]                     */
/*--------------------------------------------------------------------*/

SIGNAL ON HALT   NAME cleanup
SIGNAL ON ERROR  NAME errorHandler
SIGNAL ON SYNTAX NAME syntaxHandler

RALPHCLIP_VERSION = '2.1.0'

/* Resolve paths */
PARSE SOURCE . . sourceFile
ralphclipHome = LEFT(sourceFile, LASTPOS('/', sourceFile) - 1)

/* Load libraries */
CALL (ralphclipHome'/lib/toml.rex')
CALL (ralphclipHome'/lib/fossil.rex')
CALL (ralphclipHome'/lib/trace.rex')
CALL (ralphclipHome'/lib/handoff.rex')
CALL (ralphclipHome'/lib/parked.rex')
CALL (ralphclipHome'/lib/escalation.rex')
CALL (ralphclipHome'/lib/mutex.rex')
CALL (ralphclipHome'/lib/worker.rex')
CALL (ralphclipHome'/lib/scheduler.rex')
CALL (ralphclipHome'/adapters.rex')
CALL (ralphclipHome'/lib/safety.rex')

/*--------------------------------------------------------------------*/
/* Preflight checks                                                    */
/*--------------------------------------------------------------------*/
IF \(.FossilHelper~preflight()) THEN EXIT 1

/*--------------------------------------------------------------------*/
/* Configuration                                                       */
/*--------------------------------------------------------------------*/
companyToml = 'company.toml'
dryRun = 0
preflightMode = 0

DO i = 1 TO ARG()
   a = ARG(i)
   IF a = '--dry-run' THEN dryRun = 1
   ELSE IF a = '--preflight' THEN preflightMode = 1
   ELSE companyToml = a
END

IF \SysFileExists(companyToml) THEN DO
   SAY '[FATAL] Cannot find' companyToml
   EXIT 1
END

config = .TomlParser~parse(companyToml)
companyName   = .TomlParser~get(config, 'company.name', 'Unnamed')
companyCap    = .TomlParser~get(config, 'company.monthly_budget_usd', 0)
maxIterations = .TomlParser~get(config, 'orchestrator.max_iterations', 5)
logDir        = .TomlParser~get(config, 'orchestrator.log_dir', 'runs')

/* Governance config */
requireApproval = .TomlParser~get(config, 'governance.require_approval', '')
maxFailures     = .TomlParser~get(config, 'governance.escalation.max_consecutive_failures', 3)
notifyFile      = .TomlParser~get(config, 'governance.escalation.notification_file', -
                  '/tmp/ralphclip-escalation.txt')

/* Run ID — ISO 8601 compact format for tracing */
isoTs = .FossilHelper~isoTimestampCompact()
runId = 'run-'isoTs
logDir = .FossilHelper~shellSafeStrict(logDir)
runDir = logDir'/'runId
ADDRESS SYSTEM 'mkdir -p "' || runDir || '"'

SAY '================================================================'
SAY ' RalphClip v'RALPHCLIP_VERSION '—' companyName
SAY ' Run:' runId
IF dryRun THEN SAY ' Mode: DRY RUN (no agents will be dispatched)'
SAY '================================================================'

/*--------------------------------------------------------------------*/
/* Initialise cost table and tracer                                    */
/*--------------------------------------------------------------------*/
costTable = .TraceWriter~buildCostTable(config)
tracer = .TraceWriter~new(runId, 'traces', costTable, RALPHCLIP_VERSION)
tracer~start()
tracer~span('orchestrator.init', '', .FossilHelper~isoTimestamp(), -
            0, 0, 0, 'ok', '', '', 'Loaded config, initialised tracer')

/* Register crash handler globals */
CALL safetyInit runDir, tracer

/* Fossil mutex for concurrent access */
mutex = .FossilMutex~new()

/*--------------------------------------------------------------------*/
/* Extended preflight: verify all agent runtimes and working dirs      */
/*--------------------------------------------------------------------*/
IF preflightMode THEN DO
   SAY ''
   SAY '--- Extended Preflight ---'
   SAY ''
   errors = 0

   /* Check agent configs */
   ADDRESS SYSTEM 'ls agents/*.toml 2>/dev/null' WITH OUTPUT STEM pfAgents.
   IF pfAgents.0 = 0 THEN DO
      SAY '[preflight] WARNING: No agent TOML files found in agents/'
      errors = errors + 1
   END
   ELSE DO a = 1 TO pfAgents.0
      af = STRIP(pfAgents.a)
      IF af = '' THEN ITERATE
      ac = .TomlParser~parse(af)
      aName = FILESPEC('N', af)
      aName = LEFT(aName, LASTPOS('.', aName) - 1)
      aRuntime = .TomlParser~get(ac, 'runtime', 'claude')
      aScript  = .TomlParser~get(ac, 'script', '')
      aWorkDir = .TomlParser~get(ac, 'working_dir', '')

      /* Check runtime binary */
      SELECT
         WHEN aRuntime = 'claude' | aRuntime = 'claude-code' THEN DO
            ADDRESS SYSTEM 'which claude 2>/dev/null' WITH OUTPUT STEM w.
            IF w.0 = 0 THEN DO
               SAY '[preflight] FAIL:' aName '— claude binary not found'
               errors = errors + 1
            END
            ELSE SAY '[preflight] OK:' aName '— claude found at' STRIP(w.1)
         END
         WHEN aRuntime = 'mistral' | aRuntime = 'mistral-vibe' THEN DO
            ADDRESS SYSTEM 'which vibe 2>/dev/null' WITH OUTPUT STEM w.
            IF w.0 = 0 THEN DO
               SAY '[preflight] FAIL:' aName '— vibe binary not found'
               errors = errors + 1
            END
            ELSE SAY '[preflight] OK:' aName '— vibe found at' STRIP(w.1)
         END
         WHEN aRuntime = 'gemini' | aRuntime = 'gemini-cli' THEN DO
            ADDRESS SYSTEM 'which gemini 2>/dev/null' WITH OUTPUT STEM w.
            IF w.0 = 0 THEN DO
               SAY '[preflight] FAIL:' aName '— gemini binary not found'
               errors = errors + 1
            END
            ELSE SAY '[preflight] OK:' aName '— gemini found at' STRIP(w.1)
         END
         WHEN aRuntime = 'trinity' THEN DO
            ADDRESS SYSTEM 'which curl 2>/dev/null' WITH OUTPUT STEM w.
            IF w.0 = 0 THEN DO
               SAY '[preflight] FAIL:' aName '— curl not found (required for OpenRouter)'
               errors = errors + 1
            END
            ELSE DO
               orKey = VALUE('OPENROUTER_API_KEY',, 'ENVIRONMENT')
               IF orKey = '' THEN DO
                  SAY '[preflight] FAIL:' aName '— OPENROUTER_API_KEY not set'
                  errors = errors + 1
               END
               ELSE SAY '[preflight] OK:' aName '— curl + OPENROUTER_API_KEY present'
            END
         END
         WHEN aRuntime = 'script' | aRuntime = 'bash' THEN DO
            IF aScript \= '' & \SysFileExists(aScript) THEN DO
               SAY '[preflight] FAIL:' aName '— script not found:' aScript
               errors = errors + 1
            END
            ELSE SAY '[preflight] OK:' aName '— script runtime'
         END
         WHEN aRuntime = 'rexx' | aRuntime = 'oorexx' THEN DO
            IF aScript \= '' & \SysFileExists(aScript) THEN DO
               SAY '[preflight] FAIL:' aName '— rexx script not found:' aScript
               errors = errors + 1
            END
            ELSE SAY '[preflight] OK:' aName '— rexx runtime'
         END
         OTHERWISE SAY '[preflight] WARN:' aName '— unknown runtime:' aRuntime
      END

      /* Check working directory */
      IF aWorkDir \= '' THEN DO
         IF LEFT(aWorkDir, 1) = '~' THEN
            aWorkDir = VALUE('HOME',, 'ENVIRONMENT') || SUBSTR(aWorkDir, 2)
         ADDRESS SYSTEM 'test -d "' || aWorkDir || '"'
         IF RC \= 0 THEN DO
            SAY '[preflight] FAIL:' aName '— working_dir does not exist:' aWorkDir
            errors = errors + 1
         END
      END
   END

   /* Check project working dirs */
   projectSections = .TomlParser~sections(config, 'projects')
   DO p = 1 TO projectSections~items
      projKey = projectSections[p]
      projDir = .TomlParser~get(config, projKey'.working_dir', '.')
      IF LEFT(projDir, 1) = '~' THEN
         projDir = VALUE('HOME',, 'ENVIRONMENT') || SUBSTR(projDir, 2)
      ADDRESS SYSTEM 'test -d "' || projDir || '"'
      IF RC \= 0 THEN DO
         SAY '[preflight] FAIL: project' projKey '— working_dir does not exist:' projDir
         errors = errors + 1
      END
      ELSE SAY '[preflight] OK: project' projKey '— working_dir exists'
   END

   SAY ''
   IF errors = 0 THEN
      SAY '[preflight] All checks passed.'
   ELSE
      SAY '[preflight]' errors 'check(s) failed.'
   EXIT errors
END

/*--------------------------------------------------------------------*/
/* Create required directories                                         */
/*--------------------------------------------------------------------*/
ADDRESS SYSTEM 'mkdir -p parked_tasks handoffs traces escalations debug/mcp_dry_run'

/*--------------------------------------------------------------------*/
/* Process pending human escalation responses                          */
/*--------------------------------------------------------------------*/
escalResponses = .EscalationReader~scanPending('escalations')
IF escalResponses~items > 0 THEN DO
   SAY '[escalation] Processing' escalResponses~items 'human response(s)...'
   DO er = 1 TO escalResponses~items
      resp = escalResponses[er]
      SAY '[escalation]' resp['action'] '→' resp['task'] -
         '(ticket:' resp['ticket_id']')'
      CALL .EscalationReader~applyResponse resp
   END
   SAY '[escalation] Done.'
   SAY ''
END

/*--------------------------------------------------------------------*/
/* Company budget gate                                                 */
/*--------------------------------------------------------------------*/
companySpent = mutex~readBudgetSpent()
CALL logGov 'RUN START', 'all', 'orchestrate.rex triggered'

IF companyCap > 0 & companySpent >= companyCap THEN DO
   CALL logGov 'BUDGET HALT', 'all', -
      'Company ceiling reached:' companySpent '/' companyCap
   SAY '[BUDGET] Company budget exhausted:' companySpent '/' companyCap
   tracer~finish()
   EXIT 0
END
SAY '[BUDGET]' FORMAT(companySpent,,2) '/' FORMAT(companyCap,,2) 'USD'

/*--------------------------------------------------------------------*/
/* Load projects                                                       */
/*--------------------------------------------------------------------*/
projectSections = .TomlParser~sections(config, 'projects')
completedAgents = ''  /* track which agents completed work this run */
totalCompleted = 0
totalFailed = 0
totalParked = 0
totalDispatched = 0
lastCompletedTask = ''   /* for handoff chain tracking */
lastCompletedAdapter = ''
lastCompletedFossilRef = ''

DO p = 1 TO projectSections~items
   projKey  = projectSections[p]
   projCode = SUBSTR(projKey, LASTPOS('.', projKey) + 1)
   projDir  = .TomlParser~get(config, projKey'.working_dir', '.')
   projCap  = .TomlParser~get(config, projKey'.budget_usd', 0)
   projCtxPage = .TomlParser~get(config, projKey'.context_wiki', '')

   /* Expand ~ in path */
   IF LEFT(projDir, 1) = '~' THEN
      projDir = VALUE('HOME',, 'ENVIRONMENT') || SUBSTR(projDir, 2)

   /* Project budget gate */
   projSpent = mutex~readProjectSpend(projCode)
   IF projSpent >= projCap & projCap > 0 THEN DO
      CALL logGov 'BUDGET HOLD', projCode, -
         'Project budget reached:' projSpent '/' projCap
      SAY '[' || projCode || '] Project budget exhausted. Skipping.'
      ITERATE
   END

   SAY ''
   SAY '==== Project:' projCode '===='

   /* Load project context from wiki */
   projCtx = ''
   IF projCtxPage \= '' THEN projCtx = .FossilHelper~wikiExport(projCtxPage)

   /*-----------------------------------------------------------------*/
   /* CANDIDATE DISCOVERY: Find eligible agents (no claims yet)        */
   /*-----------------------------------------------------------------*/
   agentFiles. = ''
   ADDRESS SYSTEM 'ls agents/*.toml 2>/dev/null' WITH OUTPUT STEM agentFiles.
   scheduler = .WaveScheduler~new()

   DO a = 1 TO agentFiles.0
      agentFile = STRIP(agentFiles.a)
      IF agentFile = '' THEN ITERATE

      ac = .TomlParser~parse(agentFile)
      agentName     = FILESPEC('N', agentFile)
      agentName     = LEFT(agentName, LASTPOS('.', agentName) - 1)
      agentRuntime  = .TomlParser~get(ac, 'runtime', 'claude')
      agentModel    = .TomlParser~get(ac, 'model', '')
      agentBudget   = .TomlParser~get(ac, 'budget_usd', 0)
      agentProjects = .TomlParser~get(ac, 'projects', '')
      agentTrigger  = .TomlParser~get(ac, 'trigger', 'ticket')
      agentOwnDir   = .TomlParser~get(ac, 'working_dir', '')

      fallbackAdapters = .TomlParser~get(ac, 'fallback_adapters', '')
      IF fallbackAdapters = '' THEN DO
         legacyFb = .TomlParser~get(ac, 'fallback_runtime', '')
         IF legacyFb \= '' THEN fallbackAdapters = legacyFb
      END

      taskMaxRetries  = .TomlParser~get(ac, 'max_retries', 1)
      taskBackoff     = .TomlParser~get(ac, 'backoff', 'fixed')
      taskBackoffBase = .TomlParser~get(ac, 'backoff_base_seconds', 0)
      taskFailAction  = .TomlParser~get(ac, 'fail_action', 'park')
      IF \DATATYPE(taskMaxRetries, 'W') THEN taskMaxRetries = 1
      IF \DATATYPE(taskBackoffBase, 'N') THEN taskBackoffBase = 0

      agentProjectCount = WORDS(agentProjects)
      IF agentOwnDir \= '' & agentProjectCount <= 1 THEN
         agentWorkDir = agentOwnDir
      ELSE
         agentWorkDir = projDir
      IF LEFT(agentWorkDir, 1) = '~' THEN
         agentWorkDir = VALUE('HOME',, 'ENVIRONMENT') || SUBSTR(agentWorkDir, 2)

      /* Input validation: reject path traversal and unknown runtimes */
      IF POS('..', agentWorkDir) > 0 THEN DO
         SAY '[SECURITY] Agent' agentName 'has ".." in working_dir. Skipping.'
         ITERATE
      END
      agentScript = .TomlParser~get(ac, 'script', '')
      IF agentScript \= '' & POS('..', agentScript) > 0 THEN DO
         SAY '[SECURITY] Agent' agentName 'has ".." in script path. Skipping.'
         ITERATE
      END
      knownRuntimes = 'claude claude-code mistral mistral-vibe gemini gemini-cli trinity script bash rexx oorexx mcp-bridge'
      IF WORDPOS(agentRuntime, knownRuntimes) = 0 THEN DO
         SAY '[SECURITY] Agent' agentName 'has unknown runtime "'agentRuntime'". Skipping.'
         ITERATE
      END

      /* Static eligibility checks */
      IF agentProjects \= '' & WORDPOS(projCode, agentProjects) = 0 THEN ITERATE
      agentSpent = mutex~readAgentSpend(agentName)
      IF agentSpent >= agentBudget & agentBudget > 0 THEN DO
         CALL logGov 'BUDGET HOLD', projCode, -
            agentName 'budget reached:' agentSpent '/' agentBudget
         ITERATE
      END
      IF agentTrigger = 'manual' THEN ITERATE

      adapterRuntimes = agentRuntime
      IF fallbackAdapters \= '' THEN
         adapterRuntimes = adapterRuntimes fallbackAdapters

      /* Peek at the agent's next ticket to get dependency info.
         Read-only — no status change. If no ticket, skip. */
      peekTicket = .FossilHelper~ticketPeek(agentName, projCode)
      IF peekTicket = '' THEN ITERATE
      PARSE VAR peekTicket . '|' . '|' . '|' peekDeps '|' .
      peekDeps = STRIP(peekDeps)

      /* Register scheduling candidate — carry all config through */
      candidate = .Directory~new
      candidate['agentName']       = agentName
      candidate['trigger']         = agentTrigger
      candidate['deps']            = peekDeps
      candidate['workDir']         = agentWorkDir
      candidate['agentRole']       = .TomlParser~get(ac, 'role', agentName)
      candidate['agentRuntime']    = agentRuntime
      candidate['agentModel']      = agentModel
      candidate['agentScript']     = .TomlParser~get(ac, 'script', '')
      candidate['agentSkill']      = .TomlParser~get(ac, 'skill', '')
      candidate['agentAllowed']    = .TomlParser~get(ac, 'allowed_paths', '')
      candidate['agentForbid']     = .TomlParser~get(ac, 'forbidden_paths', '')
      candidate['agentCtx']        = .TomlParser~get(ac, 'context', '')
      candidate['agentConfig']     = ac
      candidate['taskMaxRetries']  = taskMaxRetries
      candidate['taskBackoff']     = taskBackoff
      candidate['taskBackoffBase'] = taskBackoffBase
      candidate['taskFailAction']  = taskFailAction
      candidate['adapterRuntimes'] = adapterRuntimes
      candidate['fallbackModel']   = .TomlParser~get(ac, 'fallback_model', '')
      candidate['skipPermissions'] = .TomlParser~get(ac, 'skip_permissions', 0)

      scheduler~addCandidate(candidate)
   END /* candidate discovery */

   /*-----------------------------------------------------------------*/
   /* WAVE SCHEDULING: dependency-aware concurrency tiers               */
   /*-----------------------------------------------------------------*/
   waves = scheduler~buildWaves(completedAgents)

   IF waves~items > 0 THEN
      CALL .WaveScheduler~describeWaves waves

   /*-----------------------------------------------------------------*/
   /* WAVE EXECUTION LOOP                                              */
   /*-----------------------------------------------------------------*/
   DO w = 1 TO waves~items
      wave = waves[w]
      SAY '---- Wave' w 'of' waves~items '('wave~items 'agents) ----'

      /* -- WAVE PLAN: claim tickets, build prompts -- */
      dispatchQueue = .Array~new

      DO wc = 1 TO wave~items
         c = wave[wc]
         agentName = c['agentName']

         ticket = mutex~claimTicket(agentName, projCode)
         IF ticket = '' THEN ITERATE

         PARSE VAR ticket ticketId '|' ticketTitle '|' goalChain '|' deps '|' gateType
         ticketId = STRIP(ticketId); ticketTitle = STRIP(ticketTitle)
         goalChain = STRIP(goalChain); deps = STRIP(deps); gateType = STRIP(gateType)

         IF deps \= '' & \(mutex~allDepsClosed(deps)) THEN DO
            SAY '['agentName'] "'ticketTitle'" has unmet deps. Releasing.'
            mutex~ticketChange(ticketId, 'status=open')
            ITERATE
         END

         ticketType = mutex~ticketField(ticketId, 'type')
         IF requiresApproval(ticketType, requireApproval) THEN DO
            mutex~ticketChange(ticketId, 'status=awaiting-approval')
            CALL logGov 'APPROVAL REQUIRED', projCode, -
               'Ticket "'ticketTitle'" needs human approval'
            totalParked = totalParked + 1
            ITERATE
         END

         CALL logGov 'DISPATCHED', projCode, -
            agentName '→ "'ticketTitle'" [wave' w']'
         IF c['skipPermissions'] = 1 THEN
            CALL logGov 'SECURITY WARNING', projCode, -
               agentName 'dispatched with skip_permissions=true'
         SAY '['agentName'] Queued:' ticketTitle
         totalDispatched = totalDispatched + 1
         tracer~countTask('ok')

         /* Build prompt */
         prompt = ''
         agentSkill = c['agentSkill']
         IF agentSkill \= '' & SysFileExists('skills/'agentSkill'.md') THEN
            prompt = readFile('skills/'agentSkill'.md')
         prompt = prompt || '0a'x
         prompt = prompt || 'Role:' c['agentRole'] || '0a'x
         IF goalChain \= '' THEN
            prompt = prompt || 'Goal ancestry: <goal>' || goalChain || '</goal>' || '0a'x
         prompt = prompt || 'Task: <task>' || ticketTitle || '</task>' || '0a'x
         IF c['agentCtx'] \= '' THEN
            prompt = prompt || '0a'x || c['agentCtx'] || '0a'x
         IF projCtx \= '' THEN
            prompt = prompt || '0a'x || 'Project context:' || '0a'x || projCtx || '0a'x
         learnings = .FossilHelper~wikiExport('AgentLearnings/'agentName)
         IF learnings \= '' & learnings \= 'No learnings yet.' THEN
            prompt = prompt || '0a'x || 'Learnings:' || '0a'x || learnings || '0a'x
         prompt = injectHandoffContext(ticketId, deps, prompt)
         IF c['agentAllowed'] \= '' THEN DO
            prompt = prompt || '0a'x || 'SCOPE: Only modify:' c['agentAllowed'] || '0a'x
            IF c['agentForbid'] \= '' THEN
               prompt = prompt || 'Do NOT touch:' c['agentForbid'] || '0a'x
         END
         prompt = prompt || '0a'x || 'When done, output <promise>COMPLETE</promise>.' || '0a'x

         taskSpec = .Directory~new
         taskSpec['agentName']       = agentName
         taskSpec['agentRuntime']    = c['agentRuntime']
         taskSpec['agentModel']      = c['agentModel']
         taskSpec['agentScript']     = c['agentScript']
         taskSpec['agentWorkDir']    = c['workDir']
         taskSpec['ticketId']        = ticketId
         taskSpec['ticketTitle']     = ticketTitle
         taskSpec['ticketType']      = ticketType
         taskSpec['goalChain']       = goalChain
         taskSpec['gateType']        = gateType
         taskSpec['projCode']        = projCode
         taskSpec['prompt']          = prompt
         taskSpec['taskMaxRetries']  = c['taskMaxRetries']
         taskSpec['taskBackoff']     = c['taskBackoff']
         taskSpec['taskBackoffBase'] = c['taskBackoffBase']
         taskSpec['taskFailAction']  = c['taskFailAction']
         taskSpec['adapterRuntimes'] = c['adapterRuntimes']
         taskSpec['fallbackModel']   = c['fallbackModel']
         taskSpec['skipPermissions'] = c['skipPermissions']
         taskSpec['maxIterations']   = maxIterations
         taskSpec['runDir']          = runDir
         taskSpec['agentConfig']     = c['agentConfig']

         dispatchQueue~append(taskSpec)
      END /* wave plan */

      /* -- DRY RUN: print plan and release tickets, skip dispatch -- */
      IF dryRun THEN DO
         IF dispatchQueue~items > 0 THEN DO
            SAY '[dry-run] Wave' w 'would dispatch' dispatchQueue~items 'agent(s):'
            DO i = 1 TO dispatchQueue~items
               ts = dispatchQueue[i]
               SAY '[dry-run]   'ts['agentName'] '→ "'ts['ticketTitle']'"' -
                  '(runtime:' ts['agentRuntime']', gate:' ts['gateType']')'
               /* Release the claimed ticket back to open */
               mutex~ticketChange(ts['ticketId'], 'status=open')
            END
         END
         ITERATE  /* skip to next wave */
      END

      /* -- WAVE EXECUTE: parallel dispatch -- */
      asyncMessages = .Array~new
      IF dispatchQueue~items > 0 THEN DO
         SAY '[parallel] Wave' w':' dispatchQueue~items 'agent(s)'
         DO i = 1 TO dispatchQueue~items
            worker = .TaskWorker~new(dispatchQueue[i], mutex, tracer, runId)
            msg = worker~start('execute')
            asyncMessages~append(msg)
         END
      END

      /* -- WAVE COMMIT: serial results processing -- */
      DO i = 1 TO asyncMessages~items
         outcome = asyncMessages[i]~result
         taskSpec = dispatchQueue[i]

         agentName    = taskSpec['agentName']
         ticketId     = taskSpec['ticketId']
         ticketTitle  = taskSpec['ticketTitle']
         ticketType   = taskSpec['ticketType']
         goalChain    = taskSpec['goalChain']
         gateType     = taskSpec['gateType']
         agentWorkDir = taskSpec['agentWorkDir']
         failAction   = taskSpec['taskFailAction']
         ac           = taskSpec['agentConfig']
         taskMaxRetries = taskSpec['taskMaxRetries']

         completed    = outcome['completed']
         lastResult   = outcome['lastResult']
         attemptLog   = outcome['attemptLog']
         taskSafeName = outcome['taskSafeName']
         adapterUsed  = outcome['adapterUsed']
         companySpent = companySpent + outcome['totalCost']

         IF completed THEN DO
            IF ticketType = 'epic' THEN DO
               sc = createStoriesFromOutput(lastResult['output'], projCode, goalChain)
               IF sc > 0 THEN SAY '['agentName'] Created' sc 'stories'
            END
            gatesPassed = runQualityGates(gateType, projCode, agentWorkDir, config)
            IF gatesPassed THEN DO
               mutex~ticketClose(ticketId)
               CALL logGov 'COMPLETED', projCode, agentName '→' ticketId
               CALL updateLearnings agentName, lastResult['output']
               CALL resetEscalation agentName
               completedAgents = completedAgents agentName
               totalCompleted = totalCompleted + 1
               CALL writeHandoff ticketTitle, ticketId, agentName, adapterUsed, -
                  'post-success:'taskSafeName, runId, projCode
            END
            ELSE DO
               mutex~ticketChange(ticketId, 'status=open')
               CALL logGov 'GATE FAILED', projCode, agentName '→ "'ticketTitle'"'
               totalFailed = totalFailed + 1
            END
         END
         ELSE DO
            /* Handle missing result first — worker crashed without output */
            IF lastResult = .nil THEN DO
               SAY '['agentName'] No result returned — worker may have crashed'
               CALL logGov 'WORKER CRASH', projCode, agentName '→ "'ticketTitle'" (nil result)'
               mutex~ticketChange(ticketId, 'status=open')
               totalFailed = totalFailed + 1
            END
            /* Fatal errors are always parked immediately */
            ELSE IF lastResult['error_class'] = 'fatal' THEN DO
               CALL parkTask ticketTitle, attemptLog~items, adapterUsed, -
                  lastResult, attemptLog, ac, agentName
               mutex~commitWithTag('[parked] task:'ticketTitle -
                  'reason:fatal run:'runId, 'parked:'taskSafeName)
               totalParked = totalParked + 1
            END
            /* Non-fatal failures: honour the agent's fail_action */
            ELSE DO
               SELECT
                  WHEN failAction = 'park' THEN DO
                     CALL parkTask ticketTitle, taskMaxRetries, adapterUsed, -
                        lastResult, attemptLog, ac, agentName
                     mutex~commitWithTag('[parked] task:'ticketTitle -
                        'run:'runId, 'parked:'taskSafeName)
                     totalParked = totalParked + 1
                  END
                  WHEN failAction = 'escalate' THEN DO
                     ef = .EscalationWriter~write(ticketTitle, ticketId, -
                        agentName, projCode, taskMaxRetries, attemptLog, -
                        lastResult, taskSpec['prompt'], runId, -
                        'Retries exhausted', 'escalations')
                     mutex~ticketChange(ticketId, 'status=escalated')
                     CALL logGov 'ESCALATED', projCode, agentName '→' ef
                     mutex~commitAll('[escalated] task:'ticketTitle 'run:'runId)
                     totalParked = totalParked + 1
                  END
                  WHEN failAction = 'skip' THEN DO
                     CALL logGov 'SKIPPED', projCode, agentName '→ "'ticketTitle'"'
                     mutex~commitAll('[skipped] task:'ticketTitle 'run:'runId)
                     tracer~countTask('skipped')
                     totalFailed = totalFailed + 1
                  END
                  OTHERWISE DO
                     mutex~ticketChange(ticketId, 'status=open')
                     totalFailed = totalFailed + 1
                  END
               END
               CALL checkEscalation agentName, projCode, ticketTitle
            END
         END
      END /* wave commit */

   END /* wave loop */
END /* project loop */

/*--------------------------------------------------------------------*/
/* Run summary                                                         */
/*--------------------------------------------------------------------*/
SAY ''

IF totalDispatched = 0 THEN DO
   SAY '================================================================'
   SAY ' Run idle — no work to dispatch'
   SAY '================================================================'
   CALL logGov 'RUN IDLE', 'all', 'No open tickets matched any agent'
   ADDRESS SYSTEM 'rmdir' runDir '2>/dev/null'
   tracer~finish()
END
ELSE DO
   SAY '================================================================'
   SAY ' Run complete:' totalCompleted 'completed,' -
      totalFailed 'failed,' totalParked 'parked'
   SAY ' Dispatched:' totalDispatched 'tasks'
   SAY '================================================================'

   CALL logGov 'RUN END', 'all', -
      totalDispatched 'dispatched,' totalCompleted 'completed,' -
      totalFailed 'failed,' totalParked 'parked'

   /* Write run summary file */
   summary = 'RalphClip Run Summary' || '0a'x
   summary = summary || 'Version:    ' RALPHCLIP_VERSION || '0a'x
   summary = summary || 'Run:        ' runId || '0a'x
   summary = summary || 'Company:    ' companyName || '0a'x
   summary = summary || 'Dispatched: ' totalDispatched || '0a'x
   summary = summary || 'Completed:  ' totalCompleted || '0a'x
   summary = summary || 'Failed:     ' totalFailed || '0a'x
   summary = summary || 'Parked:     ' totalParked || '0a'x
   summary = summary || 'Spent:      $' FORMAT(companySpent,,4) || '0a'x
   CALL CHAROUT runDir'/summary.log', summary
   CALL STREAM runDir'/summary.log', 'C', 'CLOSE'

   /* Housekeeping: archive old artifacts */
   CALL cleanupOldFiles 'handoffs', 30
   CALL cleanupOldFiles 'parked_tasks', 30
   CALL cleanupOldFiles 'escalations', 30, '.done'

   /* Finalise trace and commit */
   tracer~finish()
END

EXIT 0


/*====================================================================*/
/* Helper routines                                                     */
/*====================================================================*/

/*--------------------------------------------------------------------*/
/* readFile — read entire file into a string                           */
/*--------------------------------------------------------------------*/
readFile: PROCEDURE
   PARSE ARG filePath
   IF \SysFileExists(filePath) THEN RETURN ''
   content = CHARIN(filePath, 1, CHARS(filePath))
   CALL STREAM filePath, 'C', 'CLOSE'
   RETURN content

/*--------------------------------------------------------------------*/
/* parkTask — write a parked task file using the ParkedWriter          */
/*--------------------------------------------------------------------*/
parkTask: PROCEDURE
   PARSE ARG taskName, attempts, finalAdapter, result, attemptLog, ac, agentName

   /* Build a TOML config summary string */
   taskConfig = '[task.'agentName']' || '0a'x
   taskConfig = taskConfig || 'runtime = "'result['error_class']'"' || '0a'x
   /* Include key fields from agent config */
   sup = ac~supplier
   DO WHILE sup~available
      taskConfig = taskConfig || sup~index '= "'sup~item'"' || '0a'x
      sup~next
   END

   filePath = .ParkedWriter~write(taskName, attempts, finalAdapter, -
      result['error_class'], result['error_message'], -
      attemptLog, taskConfig, result['output'], 'parked_tasks')

   SAY '['agentName'] Parked task written to:' filePath
   RETURN

/*--------------------------------------------------------------------*/
/* writeHandoff — create a handoff document after successful task      */
/*--------------------------------------------------------------------*/
writeHandoff: PROCEDURE
   PARSE ARG taskName, ticketId, agentName, adapterName, fossilRef, runId, projCode

   filePath = .HandoffWriter~write( -
      taskName, -           /* sourceTask */
      'next',  -            /* targetTask — placeholder */
      adapterName, -        /* adapter */
      fossilRef, -          /* fossil ref */
      runId, -              /* run ID */
      '', -                 /* outputFiles — agent doesn't declare these yet */
      0, -                  /* recordCount */
      '', -                 /* confidence */
      'Task "'taskName'" completed by' agentName, - /* summary */
      '', -                 /* schema */
      '', -                 /* validationRules */
      'park', -             /* onFailure */
      'handoffs', -         /* directory */
      ticketId)             /* sourceTicketId */

   CALL logGov 'HANDOFF', projCode, -
      'Handoff written:' taskName '→ next ('filePath')'

   handoffMsg = '[handoff] task:'taskName 'run:'runId
   CALL .FossilHelper~commitAll handoffMsg
   RETURN

/*--------------------------------------------------------------------*/
/* injectHandoffContext — inject handoffs from upstream dependencies   */
/*                                                                     */
/* Matches handoffs by source_ticket_id (primary) or source_task      */
/* title (legacy fallback for handoffs created before this change).   */
/*--------------------------------------------------------------------*/
injectHandoffContext: PROCEDURE
   PARSE ARG ticketId, deps, prompt

   /* No dependencies = no upstream handoffs to inject */
   IF deps = '' THEN RETURN prompt

   /* Build space-delimited list of dependency ticket IDs */
   depIds = ''
   remaining = deps
   DO WHILE remaining \= ''
      PARSE VAR remaining dep ',' remaining
      dep = STRIP(dep)
      IF dep = '' THEN ITERATE
      depIds = depIds dep
   END
   depIds = STRIP(depIds)

   IF depIds = '' THEN RETURN prompt

   /* Scan handoff files, match on source_ticket_id */
   ADDRESS SYSTEM 'ls handoffs/*.md 2>/dev/null' WITH OUTPUT STEM hfiles.
   IF hfiles.0 = 0 THEN RETURN prompt

   injected = 0

   DO h = 1 TO hfiles.0
      hfile = STRIP(hfiles.h)
      IF hfile = '' THEN ITERATE

      ho = .HandoffReader~parse(hfile)
      sourceTicketId = ho['source_ticket_id']

      /* Fall back to title matching if handoff predates this change */
      IF sourceTicketId = '' | sourceTicketId = 'N/A' THEN DO
         sourceTask = ho['source_task']
         /* Legacy path: resolve dep IDs to titles and match */
         matched = 0
         DO d = 1 TO WORDS(depIds)
            depTitle = .FossilHelper~ticketField(WORD(depIds, d), 'title')
            IF depTitle \= '' & POS(sourceTask, depTitle) > 0 THEN DO
               matched = 1
               LEAVE
            END
         END
         IF \matched THEN ITERATE
      END
      ELSE DO
         /* Primary path: match by ticket ID */
         IF WORDPOS(sourceTicketId, depIds) = 0 THEN ITERATE
      END

      /* Validate before injecting */
      valResult = .HandoffReader~validate(ho)

      IF valResult['ok'] THEN DO
         prompt = prompt || '0a'x
         prompt = prompt || '--- HANDOFF FROM: 'ho['source_task']' ---' || '0a'x
         prompt = prompt || 'Summary:' ho['summary'] || '0a'x
         IF ho['output_files'] \= '' & ho['output_files'] \= 'N/A' THEN
            prompt = prompt || 'Output files:' ho['output_files'] || '0a'x
         IF ho['confidence'] \= '' & ho['confidence'] \= 'N/A' THEN
            prompt = prompt || 'Confidence:' ho['confidence'] || '0a'x
         prompt = prompt || '--- END HANDOFF ---' || '0a'x
         injected = injected + 1
      END
      ELSE DO
         errors = valResult['errors']
         DO e = 1 TO errors~items
            SAY '[handoff] Validation warning ('ho['source_task']'):' errors[e]
         END
      END
   END

   IF injected > 0 THEN
      SAY '[handoff] Injected' injected 'upstream handoff(s) into prompt'
   RETURN prompt

/*--------------------------------------------------------------------*/
/* Governance helpers                                                  */
/*--------------------------------------------------------------------*/
logGov: PROCEDURE
   PARSE ARG event, project, details
   entry = DATE('S') TIME() '|' event '|' project '|' details
   CALL .FossilHelper~wikiAppend 'GovernanceLog', entry
   RETURN

requiresApproval: PROCEDURE
   PARSE ARG ticketType, approvalList
   RETURN (WORDPOS(ticketType, approvalList) > 0)

/*--------------------------------------------------------------------*/
/* matchesCron — check if current time matches a 5-field cron expr     */
/*--------------------------------------------------------------------*/
matchesCron: PROCEDURE
   PARSE ARG cronExpr
   curMinute = SUBSTR(TIME(), 1, 2) + 0
   curHour   = SUBSTR(TIME(), 4, 2) + 0
   curDay    = SUBSTR(DATE('S'), 7, 2) + 0
   curMonth  = SUBSTR(DATE('S'), 5, 2) + 0

   dayName = LEFT(DATE('W'), 3)
   SELECT
      WHEN dayName = 'Sun' THEN curDow = 0
      WHEN dayName = 'Mon' THEN curDow = 1
      WHEN dayName = 'Tue' THEN curDow = 2
      WHEN dayName = 'Wed' THEN curDow = 3
      WHEN dayName = 'Thu' THEN curDow = 4
      WHEN dayName = 'Fri' THEN curDow = 5
      WHEN dayName = 'Sat' THEN curDow = 6
      OTHERWISE curDow = 0
   END

   PARSE VAR cronExpr fMinute fHour fDom fMonth fDow .

   IF \cronFieldMatches(fMinute, curMinute) THEN RETURN 0
   IF \cronFieldMatches(fHour, curHour) THEN RETURN 0
   IF \cronFieldMatches(fDom, curDay) THEN RETURN 0
   IF \cronFieldMatches(fMonth, curMonth) THEN RETURN 0
   IF \cronFieldMatches(fDow, curDow) THEN RETURN 0

   RETURN 1

/*--------------------------------------------------------------------*/
/* cronFieldMatches — check if a value matches a single cron field     */
/*--------------------------------------------------------------------*/
cronFieldMatches: PROCEDURE
   PARSE ARG field, value

   /* Handle */N step on wildcard: */5 means every 5th */
   IF LEFT(field, 2) = '*/' THEN DO
      step = SUBSTR(field, 3)
      IF DATATYPE(step, 'W') & step > 0 THEN
         RETURN (value // step = 0)
      RETURN 0
   END

   IF field = '*' THEN RETURN 1

   remaining = field
   DO WHILE remaining \= ''
      PARSE VAR remaining part ',' remaining
      part = STRIP(part)
      IF part = '' THEN ITERATE

      /* Handle step on range: 1-10/2 */
      IF POS('/', part) > 0 THEN DO
         PARSE VAR part rangePart '/' step
         IF \DATATYPE(step, 'W') | step <= 0 THEN step = 1
         IF POS('-', rangePart) > 0 THEN DO
            PARSE VAR rangePart rangeStart '-' rangeEnd
            IF DATATYPE(rangeStart, 'W') & DATATYPE(rangeEnd, 'W') THEN DO
               IF value >= rangeStart & value <= rangeEnd THEN
                  IF (value - rangeStart) // step = 0 THEN RETURN 1
            END
         END
      END
      ELSE IF POS('-', part) > 0 THEN DO
         PARSE VAR part rangeStart '-' rangeEnd
         IF DATATYPE(rangeStart, 'W') & DATATYPE(rangeEnd, 'W') THEN DO
            IF value >= rangeStart & value <= rangeEnd THEN RETURN 1
         END
      END
      ELSE DO
         IF DATATYPE(part, 'W') & value = part THEN RETURN 1
      END
   END

   RETURN 0

checkEscalation: PROCEDURE EXPOSE maxFailures notifyFile runDir
   PARSE ARG agentName, projCode, ticketTitle

   failFile = 'runs/.failures-'agentName
   consecutiveFails = 0

   IF SysFileExists(failFile) THEN DO
      prev = CHARIN(failFile, 1, CHARS(failFile))
      CALL STREAM failFile, 'C', 'CLOSE'
      prev = STRIP(prev)
      IF DATATYPE(prev, 'W') THEN consecutiveFails = prev
   END

   consecutiveFails = consecutiveFails + 1

   CALL SysFileDelete failFile
   CALL CHAROUT failFile, consecutiveFails
   CALL STREAM failFile, 'C', 'CLOSE'

   SAY '['agentName'] Consecutive failures:' consecutiveFails '/' maxFailures

   IF consecutiveFails >= maxFailures THEN DO
      SAY '['agentName'] *** ESCALATION: Agent suspended after' consecutiveFails 'failures ***'
      CALL logGov 'ESCALATION', projCode, -
         agentName 'suspended after' consecutiveFails 'consecutive failures. Last task: "'ticketTitle'"'

      entry = DATE('S') TIME() '|' agentName '|' projCode '|' -
         'Suspended after' consecutiveFails 'failures on "' || ticketTitle || '"' || '0a'x
      CALL CHAROUT notifyFile, entry, 1 + CHARS(notifyFile)
      CALL STREAM notifyFile, 'C', 'CLOSE'

      /* Escalate all open tickets for this agent, writing escalation docs */
      safeAgent = .FossilHelper~shellSafe(agentName)
      ADDRESS SYSTEM 'fossil ticket list assignee="' || safeAgent || '" status=open' -
         '--format "%u|%t" 2>/dev/null' WITH OUTPUT STEM openTix.
      emptyLog = .Array~new
      DO t = 1 TO openTix.0
         line = STRIP(openTix.t)
         IF line = '' THEN ITERATE
         PARSE VAR line tid '|' tTitle
         tid = STRIP(tid)
         tTitle = STRIP(tTitle)

         CALL .FossilHelper~ticketChange tid, 'status=escalated'

         /* Write an escalation document for each ticket */
         escalFile = .EscalationWriter~write( -
            tTitle, tid, agentName, projCode, -
            consecutiveFails, emptyLog, .nil, -
            '', '', -
            'Agent' agentName 'suspended after' consecutiveFails -
               'consecutive failures', -
            'escalations')
         SAY '[escalation] Wrote:' escalFile
      END
      SAY '['agentName'] All open tickets moved to escalated status.'

      CALL .FossilHelper~commitAll -
         '[escalation] agent:'agentName 'suspended after' consecutiveFails 'failures'
   END
   RETURN

/*--------------------------------------------------------------------*/
/* resetEscalation — clear failure counter when an agent succeeds      */
/*--------------------------------------------------------------------*/
resetEscalation: PROCEDURE
   PARSE ARG agentName
   failFile = 'runs/.failures-'agentName
   IF SysFileExists(failFile) THEN CALL SysFileDelete failFile
   RETURN

/*--------------------------------------------------------------------*/
/* Quality gates                                                       */
/*--------------------------------------------------------------------*/
runQualityGates: PROCEDURE
   PARSE ARG gateType, projCode, workingDir, config

   IF gateType = '' THEN RETURN 1

   gatePipelineKey = 'governance.gates.'gateType'.pipeline'
   pipeline = .TomlParser~get(config, gatePipelineKey, '')
   IF pipeline = '' THEN RETURN 1

   SAY '[gates] Running' gateType 'quality gates:' pipeline

   DO g = 1 TO WORDS(pipeline)
      gateName = WORD(pipeline, g)

      IF gateName = 'human-approval' THEN DO
         SAY '[gates] Human approval required — parking.'
         RETURN 0
      END

      gateToml = 'agents/'gateName'.toml'
      IF \SysFileExists(gateToml) THEN DO
         SAY '[gates] Warning: gate agent' gateName 'not found. Skipping.'
         ITERATE
      END

      gateConfig = .TomlParser~parse(gateToml)
      gateRuntime = .TomlParser~get(gateConfig, 'runtime', 'script')
      gateScript  = .TomlParser~get(gateConfig, 'script', '')

      gateAdapter = .AgentAdapter~new(gateRuntime, '', workingDir)
      gateAdapter~scriptPath = gateScript

      SAY '[gates] Running:' gateName
      gateResult = gateAdapter~run('')

      IF \gateResult['complete'] THEN DO
         SAY '[gates]' gateName 'FAILED'
         CALL createTicketsFromOutput gateResult['output'], projCode
         RETURN 0
      END
      SAY '[gates]' gateName 'passed'
   END

   SAY '[gates] All gates passed.'
   RETURN 1

/*--------------------------------------------------------------------*/
/* createStoriesFromOutput — parse ## Story: blocks from CTO output    */
/*--------------------------------------------------------------------*/
createStoriesFromOutput: PROCEDURE
   PARSE ARG output, projCode, parentGoalChain
   remaining = output
   created = 0

   storyMap. = ''; storyMap.0 = 0
   symbolicDeps. = ''; symbolicDeps.0 = 0

   DO WHILE remaining \= ''
      storyPos = POS('## Story:', remaining)
      IF storyPos = 0 THEN LEAVE
      remaining = SUBSTR(remaining, storyPos)

      nextBlock = POS('## ', remaining, 4)
      IF nextBlock > 0 THEN DO
         storyBlock = LEFT(remaining, nextBlock - 1)
         remaining = SUBSTR(remaining, nextBlock)
      END
      ELSE DO
         storyBlock = remaining
         remaining = ''
      END

      PARSE VAR storyBlock '## Story:' title '0a'x .
      title = STRIP(title)
      IF title = '' THEN ITERATE

      assignee   = extractField(storyBlock, 'assignee')
      goalChain  = extractField(storyBlock, 'goal_chain')
      acceptance = extractField(storyBlock, 'acceptance')
      gateType   = extractField(storyBlock, 'gate_type')
      depends    = extractField(storyBlock, 'depends')
      points     = extractField(storyBlock, 'points')

      IF assignee = '' THEN assignee = 'cto'

      IF goalChain = '' & parentGoalChain \= '' THEN
         goalChain = parentGoalChain
      ELSE IF parentGoalChain \= '' & LEFT(goalChain, 1) \= 'G' THEN
         goalChain = parentGoalChain '>' goalChain

      IF gateType = '' THEN gateType = 'code'

      fields = 'type=story' -
               'assignee='assignee -
               'project='projCode -
               'status=open' -
               'gate_type='gateType
      IF goalChain \= '' THEN
         fields = fields 'goal_chain="'goalChain'"'
      IF acceptance \= '' THEN
         fields = fields 'acceptance="'acceptance'"'

      CALL .FossilHelper~ticketAdd title, fields
      SAY '[stories] Created:' title '→' assignee
      created = created + 1

      newTicketId = getLatestTicketId(title, projCode)

      n = storyMap.0 + 1; storyMap.0 = n
      storyMap.n.title = title
      storyMap.n.id = newTicketId

      IF depends \= '' THEN DO
         sn = symbolicDeps.0 + 1; symbolicDeps.0 = sn
         symbolicDeps.sn.ticketId = newTicketId
         symbolicDeps.sn.raw = depends
      END
   END

   /* Second pass: resolve symbolic dependencies */
   DO d = 1 TO symbolicDeps.0
      ticketId = symbolicDeps.d.ticketId
      rawDeps = symbolicDeps.d.raw
      resolvedDeps = ''

      remaining = rawDeps
      DO WHILE remaining \= ''
         PARSE VAR remaining oneDep ',' remaining
         oneDep = STRIP(oneDep)
         IF oneDep = '' THEN ITERATE

         IF LEFT(oneDep, 6) = 'story:' THEN DO
            depTitle = STRIP(SUBSTR(oneDep, 7))
            resolved = 0
            DO s = 1 TO storyMap.0
               IF TRANSLATE(storyMap.s.title) = TRANSLATE(depTitle) THEN DO
                  IF resolvedDeps \= '' THEN resolvedDeps = resolvedDeps','
                  resolvedDeps = resolvedDeps || storyMap.s.id
                  resolved = 1
                  LEAVE
               END
            END
            IF \resolved THEN
               SAY '[stories] WARNING: Cannot resolve dependency "' || depTitle || '"'
         END
         ELSE DO
            IF resolvedDeps \= '' THEN resolvedDeps = resolvedDeps','
            resolvedDeps = resolvedDeps || oneDep
         END
      END

      IF resolvedDeps \= '' THEN DO
         CALL .FossilHelper~ticketChange ticketId, 'depends="'resolvedDeps'"'
         SAY '[stories] Resolved dependencies for ticket' ticketId
      END
   END

   RETURN created

/*--------------------------------------------------------------------*/
/* getLatestTicketId — find the most recently created ticket by title   */
/*--------------------------------------------------------------------*/
getLatestTicketId: PROCEDURE
   PARSE ARG title, projCode
   cmd = 'fossil ticket list title="'title'" project="'projCode'"' -
      '--format "%u" --limit 1 2>/dev/null'
   ADDRESS SYSTEM cmd WITH OUTPUT STEM ids.
   IF ids.0 = 0 THEN RETURN ''
   RETURN STRIP(ids.1)

/*--------------------------------------------------------------------*/
/* extractField — pull "- key: value" from a markdown block            */
/*--------------------------------------------------------------------*/
extractField: PROCEDURE
   PARSE ARG block, key
   marker = '- 'key':'
   pos = POS(marker, block)
   IF pos = 0 THEN RETURN ''
   chunk = SUBSTR(block, pos + LENGTH(marker))
   PARSE VAR chunk value '0a'x .
   RETURN STRIP(value)

/*--------------------------------------------------------------------*/
/* createTicketsFromOutput — parse Markdown issue blocks into tickets   */
/*--------------------------------------------------------------------*/
createTicketsFromOutput: PROCEDURE
   PARSE ARG output, projCode
   remaining = output

   DO WHILE remaining \= ''
      issuePos = POS('## Issue:', remaining)
      IF issuePos = 0 THEN LEAVE
      remaining = SUBSTR(remaining, issuePos)

      PARSE VAR remaining '## Issue:' title '0a'x rest
      title = STRIP(title)

      assignee = ''; severity = ''
      PARSE VAR rest . '- assignee:' assignee '0a'x .
      PARSE VAR rest . '- severity:' severity '0a'x .
      assignee = STRIP(assignee)
      severity = STRIP(severity)

      IF title \= '' & assignee \= '' THEN DO
         fields = 'assignee='assignee 'project='projCode 'status=open type=fix'
         CALL .FossilHelper~ticketAdd title, fields
         SAY '[tickets] Created fix ticket:' title '→' assignee
      END

      nextPos = POS('## Issue:', rest)
      IF nextPos > 0 THEN remaining = SUBSTR(rest, nextPos)
      ELSE remaining = ''
   END
   RETURN

/*--------------------------------------------------------------------*/
/* updateLearnings — extract key points and append to agent wiki       */
/*--------------------------------------------------------------------*/
updateLearnings: PROCEDURE
   PARSE ARG agentName, output
   entry = DATE('S') '- Completed a task successfully.'
   CALL .FossilHelper~wikiAppend 'AgentLearnings/'agentName, entry
   RETURN

/*--------------------------------------------------------------------*/
/* cleanupOldFiles — remove files older than N days from a directory   */
/* Prevents unbounded growth of handoffs/, parked_tasks/, escalations/ */
/* If suffix is specified (e.g. '.done'), only removes matching files. */
/*--------------------------------------------------------------------*/
cleanupOldFiles: PROCEDURE
   PARSE ARG dir, maxDays, suffix
   IF \DATATYPE(maxDays, 'W') THEN maxDays = 30
   IF suffix = '' THEN suffix = '.md'

   /* Use find -mtime to locate old files */
   cmd = 'find' dir '-maxdepth 1 -name "*' || suffix || '" -mtime +' || maxDays '-type f 2>/dev/null'
   ADDRESS SYSTEM cmd WITH OUTPUT STEM oldFiles.

   IF oldFiles.0 = 0 THEN RETURN

   removed = 0
   DO i = 1 TO oldFiles.0
      f = STRIP(oldFiles.i)
      IF f = '' THEN ITERATE
      CALL SysFileDelete f
      removed = removed + 1
   END

   IF removed > 0 THEN
      SAY '[cleanup] Removed' removed 'file(s) older than' maxDays 'days from' dir
   RETURN

/*--------------------------------------------------------------------*/
/* Cleanup — handle Ctrl-C gracefully                                  */
/*--------------------------------------------------------------------*/
cleanup:
   SAY ''
   SAY 'Interrupted. Committing partial state...'
   CALL logGov 'INTERRUPTED', 'all', 'Ctrl-C received'
   CALL .FossilHelper~commitAll 'interrupted run' DATE('S')
   EXIT 1

/*--------------------------------------------------------------------*/
/* SIGNAL ON ERROR / SYNTAX handlers                                   */
/*--------------------------------------------------------------------*/
errorHandler:
   CALL safetyHandler 'ERROR'
   EXIT 2

syntaxHandler:
   CALL safetyHandler 'SYNTAX'
   EXIT 3
