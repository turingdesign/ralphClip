#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* add-agent.rex — Add a new agent to an existing RalphClip company    */
/*                                                                     */
/* Creates an agent TOML file with runtime, skill, budget, trigger,   */
/* and project assignment. Seeds the agent's learnings wiki page.      */
/*                                                                     */
/* Usage: rexx /path/to/ralphclip/add-agent.rex [company.toml]        */
/* Run from inside the Fossil workspace directory.                     */
/*--------------------------------------------------------------------*/

SIGNAL ON HALT NAME userCancel

PARSE SOURCE . . sourceFile
ralphclipHome = LEFT(sourceFile, LASTPOS('/', sourceFile) - 1)

/* Load libraries */
CALL (ralphclipHome'/lib/toml.rex')
CALL (ralphclipHome'/lib/fossil.rex')

/*--------------------------------------------------------------------*/
/* Preflight                                                           */
/*--------------------------------------------------------------------*/
IF \(.FossilHelper~preflight()) THEN EXIT 1

IF ARG() > 0 THEN companyToml = ARG(1)
ELSE companyToml = 'company.toml'

IF \SysFileExists(companyToml) THEN DO
   SAY '[FATAL] Cannot find' companyToml
   EXIT 1
END

config = .TomlParser~parse(companyToml)
companyName = .TomlParser~get(config, 'company.name', 'Unnamed')

SAY ''
SAY '================================================================'
SAY ' RalphClip — Add Agent to' companyName
SAY '================================================================'
SAY ''

/*--------------------------------------------------------------------*/
/* Detect available runtimes                                           */
/*--------------------------------------------------------------------*/
runtimes. = 0
ADDRESS SYSTEM 'which claude 2>/dev/null' WITH OUTPUT STEM w.
IF w.0 > 0 & STRIP(w.1) \= '' THEN runtimes.claude = 1
ADDRESS SYSTEM 'which vibe 2>/dev/null' WITH OUTPUT STEM w.
IF w.0 > 0 & STRIP(w.1) \= '' THEN runtimes.mistral = 1
ADDRESS SYSTEM 'which gemini 2>/dev/null' WITH OUTPUT STEM w.
IF w.0 > 0 & STRIP(w.1) \= '' THEN runtimes.gemini = 1
orKey = VALUE('OPENROUTER_API_KEY',, 'ENVIRONMENT')
IF orKey \= '' THEN runtimes.trinity = 1
runtimes.script = 1
runtimes.rexx = 1

/*--------------------------------------------------------------------*/
/* Gather agent details                                                */
/*--------------------------------------------------------------------*/
name = ask('Agent name (lowercase, no spaces)', '')
IF name = '' THEN DO
   SAY 'Agent name is required.'
   EXIT 1
END

/* Check for existing agent */
IF SysFileExists('agents/'name'.toml') THEN DO
   SAY 'Agent "'name'" already exists (agents/'name'.toml).'
   EXIT 1
END

role = ask('Role description', name)

/* Runtime selection */
SAY '  Available runtimes:'
options = ''
IF runtimes.claude  THEN options = options 'claude'
IF runtimes.mistral THEN options = options 'mistral'
IF runtimes.gemini  THEN options = options 'gemini'
IF runtimes.trinity THEN options = options 'trinity'
options = options 'script rexx'
SAY '   ' STRIP(options)
runtime = ask('Runtime', WORD(options, 1))

/* Model */
model = ''
SELECT
   WHEN runtime = 'claude' | runtime = 'claude-code' THEN
      model = ask('Model', 'claude-sonnet-4-20250514')
   WHEN runtime = 'mistral' | runtime = 'mistral-vibe' THEN
      model = ask('Model', 'devstral-2')
   WHEN runtime = 'trinity' THEN
      model = ask('Model', 'trinity-large')
   OTHERWISE NOP
END

/* Skill selection */
SAY ''
SAY '  Skills library:'
SAY '    marketing/   market-research, content-strategy, brand-voice,'
SAY '                 article-writing, seo-strategy, conversion-copy,'
SAY '                 email-marketing, social-media-strategy'
SAY '    wordpress/   bricks-page-design, bricks-ui-ux, bricks-element-dev,'
SAY '                 wp-plugin-dev, wp-site-architecture, wp-performance,'
SAY '                 wp-woocommerce'
SAY '    vue/         vue-spa, vue-pwa, vue-component, vue-data-viz, nuxt-app'
SAY '    general/     decompose, review-code, write-tests, tech-docs,'
SAY '                 api-design, data-modelling'
SAY ''
skill = ask('Skill (category/name, or blank for none)', '')

/* Budget */
budget = askNum('Budget (USD)', 5.00)

/* Trigger */
SAY '  Trigger options: ticket, always, manual, after:<agent>, cron:<expr>'
trigger = ask('Trigger', 'ticket')

/* Fail action */
SAY '  Fail action: park, escalate, skip'
failAction = ask('Fail action', 'park')

/* Skip permissions (Claude only) */
skipPerms = 0
IF runtime = 'claude' | runtime = 'claude-code' THEN DO
   sp = askYN('Enable --dangerously-skip-permissions?', 'n')
   IF sp THEN skipPerms = 1
END

/* Script path (script/rexx only) */
scriptPath = ''
IF runtime = 'script' | runtime = 'bash' | runtime = 'rexx' | runtime = 'oorexx' THEN
   scriptPath = ask('Script path', 'scripts/'name'.sh')

/* Project assignment */
SAY ''
SAY '  Available projects:'
projectSections = .TomlParser~sections(config, 'projects')
projList = ''
DO p = 1 TO projectSections~items
   projKey = projectSections[p]
   pCode = SUBSTR(projKey, LASTPOS('.', projKey) + 1)
   projList = projList pCode
   SAY '    'pCode
END
IF projList = '' THEN SAY '    (none found)'
SAY ''
projAssign = ask('Assign to projects (space-separated, or "all")', 'all')

IF projAssign = 'all' THEN projAssign = STRIP(projList)

/* Retry config */
maxRetries = askNum('Max retries', 1)
fallbacks = ''
IF maxRetries > 1 THEN DO
   SAY '  Fallback runtimes for retry cascade (space-separated, or blank):'
   fallbacks = ask('Fallbacks', '')
END

SAY ''

/*--------------------------------------------------------------------*/
/* Summary & confirmation                                              */
/*--------------------------------------------------------------------*/
SAY '--- Summary ---'
SAY ''
SAY '  Name:       ' name
SAY '  Role:       ' role
SAY '  Runtime:    ' runtime
IF model \= '' THEN SAY '  Model:      ' model
IF skill \= '' THEN SAY '  Skill:      ' skill
SAY '  Budget:      $'FORMAT(budget,,2)
SAY '  Trigger:    ' trigger
SAY '  Fail action:' failAction
IF skipPerms THEN SAY '  Permissions:  skip_permissions = true'
IF scriptPath \= '' THEN SAY '  Script:     ' scriptPath
SAY '  Projects:   ' projAssign
IF maxRetries > 1 THEN SAY '  Retries:    ' maxRetries '(fallbacks:' fallbacks')'
SAY ''

proceed = askYN('Create this agent?', 'y')
IF \proceed THEN DO
   SAY 'Cancelled.'
   EXIT 0
END

SAY ''
SAY 'Creating agent...'

/*--------------------------------------------------------------------*/
/* Write agent TOML                                                    */
/*--------------------------------------------------------------------*/
ADDRESS SYSTEM 'mkdir -p agents'

at = 'role = "'role'"' || '0a'x
at = at || 'runtime = "'runtime'"' || '0a'x
IF model \= '' THEN
   at = at || 'model = "'model'"' || '0a'x
IF scriptPath \= '' THEN
   at = at || 'script = "'scriptPath'"' || '0a'x
at = at || 'budget_usd =' budget || '0a'x
IF skill \= '' THEN
   at = at || 'skill = "'skill'"' || '0a'x
at = at || 'trigger = "'trigger'"' || '0a'x
at = at || 'fail_action = "'failAction'"' || '0a'x
IF skipPerms THEN
   at = at || 'skip_permissions = true' || '0a'x
IF maxRetries > 1 THEN DO
   at = at || 'max_retries =' maxRetries || '0a'x
   at = at || 'backoff = "exponential"' || '0a'x
   at = at || 'backoff_base_seconds = 5' || '0a'x
END
IF fallbacks \= '' THEN
   at = at || 'fallback_adapters = "'fallbacks'"' || '0a'x
at = at || 'projects = "'projAssign'"' || '0a'x

filePath = 'agents/'name'.toml'
CALL CHAROUT filePath, at
CALL STREAM filePath, 'C', 'CLOSE'
SAY '  Created' filePath

/*--------------------------------------------------------------------*/
/* Create placeholder script if needed                                 */
/*--------------------------------------------------------------------*/
IF scriptPath \= '' & \SysFileExists(scriptPath) THEN DO
   /* Ensure directory exists */
   scriptDir = LEFT(scriptPath, LASTPOS('/', scriptPath))
   IF scriptDir \= '' THEN ADDRESS SYSTEM 'mkdir -p "'scriptDir'"'

   script = '#!/bin/bash' || '0a'x
   script = script || 'set -euo pipefail' || '0a'x
   script = script || 'cd "$RALPHCLIP_WORKING_DIR"' || '0a'x
   script = script || '# TODO: Replace with your actual command' || '0a'x
   script = script || 'echo "'name' placeholder — edit' scriptPath'"' || '0a'x
   script = script || 'echo "<promise>COMPLETE</promise>"' || '0a'x
   CALL CHAROUT scriptPath, script
   CALL STREAM scriptPath, 'C', 'CLOSE'
   ADDRESS SYSTEM 'chmod +x "'scriptPath'"'
   SAY '  Created placeholder script:' scriptPath
END

/*--------------------------------------------------------------------*/
/* Seed learnings wiki page                                            */
/*--------------------------------------------------------------------*/
CALL .FossilHelper~wikiCommit 'AgentLearnings/'name, 'No learnings yet.'
SAY '  Seeded wiki: AgentLearnings/'name

/*--------------------------------------------------------------------*/
/* Fossil commit                                                       */
/*--------------------------------------------------------------------*/
CALL .FossilHelper~commitAll '[add-agent] 'name' ('runtime'): 'role

SAY ''
SAY '================================================================'
SAY ' Agent "'name'" created successfully.'
SAY ''
SAY ' Next steps:'
SAY '   1. Review agents/'name'.toml'
IF scriptPath \= '' THEN
   SAY '   2. Edit' scriptPath 'with your actual command'
SAY '   3. Run preflight: rexx' ralphclipHome'/orchestrate.rex --preflight'
SAY '================================================================'

EXIT 0


/*====================================================================*/
/* Helper routines                                                     */
/*====================================================================*/

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

askYN: PROCEDURE
   PARSE ARG label, default
   IF default = 'y' THEN prompt = '[Y/n]'
   ELSE prompt = '[y/N]'
   CALL CHAROUT , '  'label prompt': '
   PARSE PULL response
   response = STRIP(TRANSLATE(response,, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))
   IF response = '' THEN response = default
   RETURN (LEFT(response, 1) = 'y')

userCancel:
   SAY ''
   SAY 'Cancelled. No changes made.'
   EXIT 1
