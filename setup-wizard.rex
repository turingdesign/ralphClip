#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* setup-wizard.rex — Interactive RalphClip company setup wizard       */
/*                                                                     */
/* Walks through multi-project, multi-agent setup with skill           */
/* assignment, budget allocation, governance rules, and quality gates. */
/* Produces company.toml + agents/*.toml + wired skills.               */
/*                                                                     */
/* Usage: rexx /path/to/ralphclip/setup-wizard.rex                    */
/* Run from inside an existing Fossil workspace (after setup.sh).     */
/*--------------------------------------------------------------------*/

SIGNAL ON HALT NAME userCancel

PARSE SOURCE . . sourceFile
ralphclipHome = LEFT(sourceFile, LASTPOS('/', sourceFile) - 1)

SAY ''
SAY '================================================================'
SAY ' RalphClip — Interactive Setup Wizard'
SAY '================================================================'
SAY ''
SAY 'This wizard will walk you through configuring your company,'
SAY 'projects, agents, skills, budgets, and governance rules.'
SAY ''
SAY 'Press Ctrl-C at any time to cancel (no changes saved until the end).'
SAY ''

/*--------------------------------------------------------------------*/
/* 1. Company basics                                                   */
/*--------------------------------------------------------------------*/
SAY '--- Step 1: Company ---'
SAY ''
companyName = ask('Company name', 'My Company')
monthlyBudget = askNum('Monthly budget (USD)', 50.00)

SAY ''

/*--------------------------------------------------------------------*/
/* 2. Available runtimes detection                                     */
/*--------------------------------------------------------------------*/
SAY '--- Step 2: Runtime Detection ---'
SAY ''
SAY 'Checking which AI runtimes are available...'
SAY ''

runtimes. = 0
ADDRESS SYSTEM 'which claude 2>/dev/null' WITH OUTPUT STEM w.
IF w.0 > 0 & STRIP(w.1) \= '' THEN DO
   SAY '  [x] Claude Code (claude)'
   runtimes.claude = 1
END
ELSE SAY '  [ ] Claude Code — not found'

ADDRESS SYSTEM 'which vibe 2>/dev/null' WITH OUTPUT STEM w.
IF w.0 > 0 & STRIP(w.1) \= '' THEN DO
   SAY '  [x] Mistral Vibe (vibe)'
   runtimes.mistral = 1
END
ELSE SAY '  [ ] Mistral Vibe — not found'

ADDRESS SYSTEM 'which gemini 2>/dev/null' WITH OUTPUT STEM w.
IF w.0 > 0 & STRIP(w.1) \= '' THEN DO
   SAY '  [x] Gemini CLI (gemini)'
   runtimes.gemini = 1
END
ELSE SAY '  [ ] Gemini CLI — not found'

orKey = VALUE('OPENROUTER_API_KEY',, 'ENVIRONMENT')
IF orKey \= '' THEN DO
   SAY '  [x] Trinity (OpenRouter API key set)'
   runtimes.trinity = 1
END
ELSE SAY '  [ ] Trinity — OPENROUTER_API_KEY not set'

SAY '  [x] Script (bash) — always available'
SAY '  [x] Rexx (ooRexx) — always available'
runtimes.script = 1
runtimes.rexx = 1
SAY ''

/*--------------------------------------------------------------------*/
/* 3. Projects                                                         */
/*--------------------------------------------------------------------*/
SAY '--- Step 3: Projects ---'
SAY ''
SAY 'Define your projects. You need at least one.'
SAY ''

projects. = ''; projects.0 = 0

DO FOREVER
   n = projects.0 + 1
   SAY '  Project' n':'
   code = ask('    Project code (short, no spaces)', 'project'n)
   workDir = ask('    Working directory', '~/projects/'code)
   budget = askNum('    Project budget (USD)', monthlyBudget)
   goal = ask('    Primary goal (one sentence)', '')

   projects.0 = n
   projects.n.code = code
   projects.n.workDir = workDir
   projects.n.budget = budget
   projects.n.goal = goal
   SAY ''

   more = askYN('Add another project?', 'n')
   IF \more THEN LEAVE
   SAY ''
END

SAY ''

/*--------------------------------------------------------------------*/
/* 4. Skill library browser                                            */
/*--------------------------------------------------------------------*/
SAY '--- Step 4: Skills & Agents ---'
SAY ''
SAY 'Available skill categories in the library:'
SAY ''
SAY '  Marketing:   market-research, content-strategy, brand-voice,'
SAY '               article-writing, seo-strategy, conversion-copy,'
SAY '               email-marketing, social-media-strategy'
SAY ''
SAY '  WordPress:   bricks-page-design, bricks-ui-ux, bricks-element-dev,'
SAY '               wp-plugin-dev, wp-site-architecture, wp-performance,'
SAY '               wp-woocommerce'
SAY ''
SAY '  Vue/PWA:     vue-spa, vue-pwa, vue-component, vue-data-viz, nuxt-app'
SAY ''
SAY '  General:     decompose, review-code, write-tests, tech-docs,'
SAY '               api-design, data-modelling'
SAY ''

/*--------------------------------------------------------------------*/
/* 5. Agent configuration                                              */
/*--------------------------------------------------------------------*/
SAY 'Now define your agents. Each agent gets a runtime, skill, and budget.'
SAY 'The CTO (decompose) agent is created automatically.'
SAY ''

agents. = ''; agents.0 = 0

/* Auto-create CTO */
agents.0 = 1
agents.1.name = 'cto'
agents.1.role = 'CTO'
agents.1.runtime = selectRuntime('cto (decomposer)', runtimes.)
agents.1.model = askModel(agents.1.runtime)
agents.1.skill = 'general/decompose'
agents.1.budget = askNum('    CTO budget (USD)', 10.00)
agents.1.trigger = 'ticket'
agents.1.failAction = 'escalate'
agents.1.skipPerms = 0
agents.1.projects = 'all'
SAY ''

DO FOREVER
   more = askYN('Add another agent?', 'y')
   IF \more THEN LEAVE
   SAY ''

   n = agents.0 + 1

   name = ask('  Agent name (lowercase, no spaces)', '')
   IF name = '' THEN ITERATE
   role = ask('  Role description', name)
   runtime = selectRuntime(name, runtimes.)
   model = askModel(runtime)

   SAY '  Select a skill (category/name from the list above, or custom path):'
   skill = ask('  Skill', '')

   budget = askNum('  Budget (USD)', 5.00)

   SAY '  Trigger options: ticket, always, manual, after:<agent>, cron:<expr>'
   trigger = ask('  Trigger', 'ticket')

   SAY '  Fail action: park (save for later), escalate (human review), skip'
   failAction = ask('  Fail action', 'park')

   skipPerms = 0
   IF runtime = 'claude' | runtime = 'claude-code' THEN DO
      sp = askYN('  Enable --dangerously-skip-permissions for this agent?', 'n')
      IF sp THEN skipPerms = 1
   END

   SAY '  Assign to which projects? (space-separated codes, or "all"):'
   projList = ''
   DO p = 1 TO projects.0
      projList = projList projects.p.code
   END
   SAY '    Available:' STRIP(projList)
   projAssign = ask('  Projects', 'all')

   /* Retry/fallback config */
   maxRetries = askNum('  Max retries', 1)
   fallbacks = ''
   IF maxRetries > 1 THEN DO
      SAY '  Fallback adapters (space-separated runtimes for retry cascade, or blank):'
      fallbacks = ask('  Fallbacks', '')
   END

   agents.0 = n
   agents.n.name = name
   agents.n.role = role
   agents.n.runtime = runtime
   agents.n.model = model
   agents.n.skill = skill
   agents.n.budget = budget
   agents.n.trigger = trigger
   agents.n.failAction = failAction
   agents.n.skipPerms = skipPerms
   agents.n.projects = projAssign
   agents.n.maxRetries = maxRetries
   agents.n.fallbacks = fallbacks

   SAY ''
END

SAY ''

/*--------------------------------------------------------------------*/
/* 6. Quality gates                                                    */
/*--------------------------------------------------------------------*/
SAY '--- Step 5: Quality Gates ---'
SAY ''
SAY 'Quality gates run after an agent completes a task.'
SAY 'Common gates: linter (run-lint.sh), test-runner (run-tests.sh),'
SAY '              reviewer (review-code skill), human-approval.'
SAY ''

gates. = ''; gates.0 = 0

addLinter = askYN('Add a linter gate agent?', 'y')
IF addLinter THEN DO
   gates.0 = 1
   gates.1.name = 'linter'
   gates.1.script = 'scripts/run-lint.sh'
   SAY '  Linter agent created. Edit scripts/run-lint.sh with your lint command.'
END

addTests = askYN('Add a test-runner gate agent?', 'y')
IF addTests THEN DO
   n = gates.0 + 1; gates.0 = n
   gates.n.name = 'test-runner'
   gates.n.script = 'scripts/run-tests.sh'
   SAY '  Test runner agent created. Edit scripts/run-tests.sh with your test command.'
END

/* Build gate pipeline string */
gatePipeline = ''
DO g = 1 TO gates.0
   IF gatePipeline \= '' THEN gatePipeline = gatePipeline' '
   gatePipeline = gatePipeline || gates.g.name
END

SAY ''

/*--------------------------------------------------------------------*/
/* 7. Governance                                                       */
/*--------------------------------------------------------------------*/
SAY '--- Step 6: Governance ---'
SAY ''

SAY 'Which ticket types require human approval before dispatch?'
SAY '  Common types: deploy, client-facing, epic, infrastructure'
requireApproval = ask('  Require approval for (space-separated)', 'deploy client-facing')

maxFailures = askNum('Max consecutive failures before agent suspension', 3)

SAY ''

/*--------------------------------------------------------------------*/
/* 8. Summary & confirmation                                           */
/*--------------------------------------------------------------------*/
SAY '================================================================'
SAY ' Configuration Summary'
SAY '================================================================'
SAY ''
SAY '  Company:     ' companyName
SAY '  Budget:       $'FORMAT(monthlyBudget,,2)'/month'
SAY ''

SAY '  Projects:'
DO p = 1 TO projects.0
   SAY '    'projects.p.code '→' projects.p.workDir '($'FORMAT(projects.p.budget,,2)')'
END
SAY ''

SAY '  Agents:'
DO a = 1 TO agents.0
   SAY '    'agents.a.name '('agents.a.runtime') — skill:' agents.a.skill -
      '$'FORMAT(agents.a.budget,,2)
END
DO g = 1 TO gates.0
   SAY '    'gates.g.name '(script) — gate agent'
END
SAY ''

SAY '  Gate pipeline:' gatePipeline
SAY '  Approval required: ' requireApproval
SAY '  Escalation threshold:' maxFailures 'failures'
SAY ''

proceed = askYN('Write this configuration?', 'y')
IF \proceed THEN DO
   SAY 'Cancelled. No files written.'
   EXIT 0
END

SAY ''

/*--------------------------------------------------------------------*/
/* 9. Write files                                                      */
/*--------------------------------------------------------------------*/
SAY 'Writing configuration...'

/* Ensure directories exist */
ADDRESS SYSTEM 'mkdir -p agents skills scripts runs'

/* ----- company.toml ----- */
toml = '[company]' || '0a'x
toml = toml || 'name = "'companyName'"' || '0a'x
toml = toml || 'monthly_budget_usd =' monthlyBudget || '0a'x
toml = toml || 'ralphclip_home = "'ralphclipHome'"' || '0a'x
toml = toml || '0a'x

/* Projects */
DO p = 1 TO projects.0
   c = projects.p.code
   toml = toml || '[projects.'c']' || '0a'x
   toml = toml || 'budget_usd =' projects.p.budget || '0a'x
   toml = toml || 'working_dir = "'projects.p.workDir'"' || '0a'x
   toml = toml || 'context_wiki = "Projects/'c'/Context"' || '0a'x
   toml = toml || 'goals = ["G001"]' || '0a'x
   toml = toml || '0a'x
END

/* Governance */
toml = toml || '[governance]' || '0a'x
toml = toml || 'require_approval = "'requireApproval'"' || '0a'x
toml = toml || '0a'x

IF gatePipeline \= '' THEN DO
   toml = toml || '[governance.gates.code]' || '0a'x
   toml = toml || 'pipeline = "'gatePipeline'"' || '0a'x
   toml = toml || 'on_fail = "reopen"' || '0a'x
   toml = toml || '0a'x
END

toml = toml || '[governance.escalation]' || '0a'x
toml = toml || 'max_consecutive_failures =' maxFailures || '0a'x
toml = toml || 'notification_file = "/tmp/ralphclip-escalation.txt"' || '0a'x
toml = toml || '0a'x

/* Orchestrator */
toml = toml || '[orchestrator]' || '0a'x
toml = toml || 'max_iterations = 5' || '0a'x
toml = toml || 'log_dir = "runs"' || '0a'x

CALL writeFile 'company.toml', toml
SAY '  company.toml'

/* ----- Agent TOML files ----- */
DO a = 1 TO agents.0
   at = 'role = "'agents.a.role'"' || '0a'x
   at = at || 'runtime = "'agents.a.runtime'"' || '0a'x
   IF agents.a.model \= '' THEN
      at = at || 'model = "'agents.a.model'"' || '0a'x
   at = at || 'budget_usd =' agents.a.budget || '0a'x
   IF agents.a.skill \= '' THEN
      at = at || 'skill = "'agents.a.skill'"' || '0a'x
   at = at || 'trigger = "'agents.a.trigger'"' || '0a'x
   at = at || 'fail_action = "'agents.a.failAction'"' || '0a'x
   IF agents.a.skipPerms THEN
      at = at || 'skip_permissions = true' || '0a'x
   IF agents.a.maxRetries > 1 THEN DO
      at = at || 'max_retries =' agents.a.maxRetries || '0a'x
      at = at || 'backoff = "exponential"' || '0a'x
      at = at || 'backoff_base_seconds = 5' || '0a'x
   END
   IF agents.a.fallbacks \= '' THEN
      at = at || 'fallback_adapters = "'agents.a.fallbacks'"' || '0a'x

   /* Project assignment */
   IF agents.a.projects = 'all' THEN DO
      projArr = ''
      DO p = 1 TO projects.0
         IF projArr \= '' THEN projArr = projArr' '
         projArr = projArr || projects.p.code
      END
      at = at || 'projects = "'projArr'"' || '0a'x
   END
   ELSE
      at = at || 'projects = "'agents.a.projects'"' || '0a'x

   CALL writeFile 'agents/'agents.a.name'.toml', at
   SAY '  agents/'agents.a.name'.toml'
END

/* ----- Gate agent TOML files ----- */
DO g = 1 TO gates.0
   gt = 'role = "'gates.g.name'"' || '0a'x
   gt = gt || 'runtime = "script"' || '0a'x
   gt = gt || 'script = "'gates.g.script'"' || '0a'x
   gt = gt || 'budget_usd = 0.00' || '0a'x
   gt = gt || 'trigger = "ticket"' || '0a'x

   projArr = ''
   DO p = 1 TO projects.0
      IF projArr \= '' THEN projArr = projArr' '
      projArr = projArr || projects.p.code
   END
   gt = gt || 'projects = "'projArr'"' || '0a'x

   CALL writeFile 'agents/'gates.g.name'.toml', gt
   SAY '  agents/'gates.g.name'.toml'
END

/* ----- Symlink skills if not already present ----- */
IF \SysFileExists('skills/general') THEN DO
   SAY ''
   SAY 'Linking skills library...'
   ADDRESS SYSTEM 'ln -sf "'ralphclipHome'/skills/marketing" skills/marketing 2>/dev/null'
   ADDRESS SYSTEM 'ln -sf "'ralphclipHome'/skills/wordpress" skills/wordpress 2>/dev/null'
   ADDRESS SYSTEM 'ln -sf "'ralphclipHome'/skills/vue" skills/vue 2>/dev/null'
   ADDRESS SYSTEM 'ln -sf "'ralphclipHome'/skills/general" skills/general 2>/dev/null'
   SAY '  Symlinked skills/marketing, skills/wordpress, skills/vue, skills/general'
END

/* ----- Placeholder gate scripts ----- */
IF \SysFileExists('scripts/run-lint.sh') THEN DO
   script = '#!/bin/bash' || '0a'x
   script = script || 'set -euo pipefail' || '0a'x
   script = script || 'cd "$RALPHCLIP_WORKING_DIR"' || '0a'x
   script = script || 'echo "Linter placeholder — replace with your lint command."' || '0a'x
   script = script || 'echo "<promise>COMPLETE</promise>"' || '0a'x
   CALL writeFile 'scripts/run-lint.sh', script
   ADDRESS SYSTEM 'chmod +x scripts/run-lint.sh'
END

IF \SysFileExists('scripts/run-tests.sh') THEN DO
   script = '#!/bin/bash' || '0a'x
   script = script || 'set -euo pipefail' || '0a'x
   script = script || 'cd "$RALPHCLIP_WORKING_DIR"' || '0a'x
   script = script || 'echo "Test runner placeholder — replace with your test command."' || '0a'x
   script = script || 'echo "<promise>COMPLETE</promise>"' || '0a'x
   CALL writeFile 'scripts/run-tests.sh', script
   ADDRESS SYSTEM 'chmod +x scripts/run-tests.sh'
END

SAY ''
SAY '================================================================'
SAY ' Setup complete!'
SAY ''
SAY ' Next steps:'
SAY '   1. Review company.toml and agents/*.toml'
SAY '   2. Replace scripts/run-lint.sh and run-tests.sh with real commands'
SAY '   3. Run preflight: rexx' ralphclipHome'/orchestrate.rex --preflight'
SAY '   4. Dry run:       rexx' ralphclipHome'/orchestrate.rex --dry-run'
SAY '   5. Go live:       rexx' ralphclipHome'/orchestrate.rex'
SAY '================================================================'

EXIT 0


/*====================================================================*/
/* Helper routines                                                     */
/*====================================================================*/

/*--------------------------------------------------------------------*/
/* ask — prompt for input with a default value                         */
/*--------------------------------------------------------------------*/
ask: PROCEDURE
   PARSE ARG label, default
   IF default \= '' THEN
      CALL CHAROUT , '  'label' ['default']: '
   ELSE
      CALL CHAROUT , '  'label': '
   PARSE PULL response
   response = STRIP(response)
   IF response = '' THEN RETURN default
   RETURN response

/*--------------------------------------------------------------------*/
/* askNum — prompt for a numeric value with a default                  */
/*--------------------------------------------------------------------*/
askNum: PROCEDURE
   PARSE ARG label, default
   DO FOREVER
      CALL CHAROUT , '  'label' ['FORMAT(default,,2)']: '
      PARSE PULL response
      response = STRIP(response)
      IF response = '' THEN RETURN default
      IF DATATYPE(response, 'N') THEN RETURN response
      SAY '    Please enter a number.'
   END

/*--------------------------------------------------------------------*/
/* askYN — yes/no prompt                                               */
/*--------------------------------------------------------------------*/
askYN: PROCEDURE
   PARSE ARG label, default
   IF default = 'y' THEN prompt = '[Y/n]'
   ELSE prompt = '[y/N]'
   CALL CHAROUT , '  'label prompt': '
   PARSE PULL response
   response = STRIP(TRANSLATE(response,, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))
   IF response = '' THEN response = default
   RETURN (LEFT(response, 1) = 'y')

/*--------------------------------------------------------------------*/
/* askModel — ask for model identifier based on runtime                */
/*--------------------------------------------------------------------*/
askModel: PROCEDURE
   PARSE ARG runtime
   SELECT
      WHEN runtime = 'claude' | runtime = 'claude-code' THEN
         def = 'claude-sonnet-4-20250514'
      WHEN runtime = 'mistral' | runtime = 'mistral-vibe' THEN
         def = 'devstral-2'
      WHEN runtime = 'gemini' | runtime = 'gemini-cli' THEN
         def = ''
      WHEN runtime = 'trinity' THEN
         def = 'trinity-large'
      OTHERWISE
         RETURN ''
   END
   IF def = '' THEN RETURN ''
   RETURN ask('    Model', def)

/*--------------------------------------------------------------------*/
/* selectRuntime — choose a runtime from available options              */
/*--------------------------------------------------------------------*/
selectRuntime: PROCEDURE
   PARSE ARG agentLabel, runtimes.
   SAY '  Runtime for' agentLabel':'
   options = ''
   IF runtimes.claude   THEN options = options 'claude'
   IF runtimes.mistral  THEN options = options 'mistral'
   IF runtimes.gemini   THEN options = options 'gemini'
   IF runtimes.trinity  THEN options = options 'trinity'
   options = options 'script rexx'
   SAY '    Available:' STRIP(options)
   RETURN ask('    Runtime', WORD(options, 1))

/*--------------------------------------------------------------------*/
/* writeFile — write content to a file (overwrite)                     */
/*--------------------------------------------------------------------*/
writeFile: PROCEDURE
   PARSE ARG filePath, content
   IF SysFileExists(filePath) THEN CALL SysFileDelete filePath
   CALL CHAROUT filePath, content
   CALL STREAM filePath, 'C', 'CLOSE'
   RETURN

/*--------------------------------------------------------------------*/
/* userCancel — handle Ctrl-C                                          */
/*--------------------------------------------------------------------*/
userCancel:
   SAY ''
   SAY 'Setup cancelled. No files were written.'
   EXIT 1
