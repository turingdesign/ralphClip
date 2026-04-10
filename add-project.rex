#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* add-project.rex — Add a new project to an existing RalphClip company*/
/*                                                                     */
/* Appends a [projects.<code>] section to company.toml, seeds the      */
/* Fossil wiki pages, creates the first epic ticket, and optionally    */
/* assigns existing agents to the new project.                         */
/*                                                                     */
/* Usage: rexx /path/to/ralphclip/add-project.rex [company.toml]      */
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
   SAY 'Run this from inside your Fossil workspace directory.'
   EXIT 1
END

/* Load existing config to check for conflicts */
config = .TomlParser~parse(companyToml)
companyName = .TomlParser~get(config, 'company.name', 'Unnamed')

SAY ''
SAY '================================================================'
SAY ' RalphClip — Add Project to' companyName
SAY '================================================================'
SAY ''

/*--------------------------------------------------------------------*/
/* Gather project details                                              */
/*--------------------------------------------------------------------*/
projCode = ask('Project code (short, no spaces)', '')
IF projCode = '' THEN DO
   SAY 'Project code is required.'
   EXIT 1
END

/* Check for existing project with same code */
existing = .TomlParser~get(config, 'projects.'projCode'.budget_usd', '')
IF existing \= '' THEN DO
   SAY 'Project "'projCode'" already exists in' companyToml
   EXIT 1
END

workDir = ask('Working directory', '~/projects/'projCode)
budget = askNum('Project budget (USD)', 20.00)
goal = ask('Primary goal (one sentence)', '')
client = ask('Client name (or "Internal")', 'Internal')

SAY ''

/*--------------------------------------------------------------------*/
/* Agent assignment                                                    */
/*--------------------------------------------------------------------*/
SAY 'Which existing agents should work on this project?'
SAY ''

/* List existing agents */
ADDRESS SYSTEM 'ls agents/*.toml 2>/dev/null' WITH OUTPUT STEM agentFiles.
IF agentFiles.0 = 0 THEN
   SAY '  (no agents found in agents/)'
ELSE DO
   SAY '  Available agents:'
   DO a = 1 TO agentFiles.0
      af = STRIP(agentFiles.a)
      IF af = '' THEN ITERATE
      aName = FILESPEC('N', af)
      aName = LEFT(aName, LASTPOS('.', aName) - 1)
      ac = .TomlParser~parse(af)
      aRole = .TomlParser~get(ac, 'role', aName)
      aProjects = .TomlParser~get(ac, 'projects', '')
      SAY '    'aName '('aRole') — currently on:' aProjects
   END
END

SAY ''
SAY '  Enter agent names to assign (space-separated), or "all" for every agent,'
SAY '  or "none" to skip (you can assign agents later in their TOML files).'
assignAgents = ask('Assign agents', 'all')

SAY ''

/*--------------------------------------------------------------------*/
/* Summary & confirmation                                              */
/*--------------------------------------------------------------------*/
SAY '--- Summary ---'
SAY ''
SAY '  Project:    ' projCode
SAY '  Client:     ' client
SAY '  Directory:  ' workDir
SAY '  Budget:      $'FORMAT(budget,,2)
SAY '  Goal:       ' goal

IF assignAgents = 'none' THEN
   SAY '  Agents:      (none — assign later)'
ELSE IF assignAgents = 'all' THEN
   SAY '  Agents:      all existing agents'
ELSE
   SAY '  Agents:     ' assignAgents

SAY ''

proceed = askYN('Add this project?', 'y')
IF \proceed THEN DO
   SAY 'Cancelled.'
   EXIT 0
END

SAY ''
SAY 'Adding project...'

/*--------------------------------------------------------------------*/
/* 1. Append to company.toml                                           */
/*--------------------------------------------------------------------*/
tomlBlock = '0a'x
tomlBlock = tomlBlock || '[projects.'projCode']' || '0a'x
tomlBlock = tomlBlock || 'client = "'client'"' || '0a'x
tomlBlock = tomlBlock || 'budget_usd =' budget || '0a'x
tomlBlock = tomlBlock || 'working_dir = "'workDir'"' || '0a'x
tomlBlock = tomlBlock || 'context_wiki = "Projects/'projCode'/Context"' || '0a'x
tomlBlock = tomlBlock || 'goals = ["G-'projCode'-001"]' || '0a'x

/* Append to file */
CALL CHAROUT companyToml, tomlBlock, 1 + CHARS(companyToml)
CALL STREAM companyToml, 'C', 'CLOSE'
SAY '  Updated' companyToml

/*--------------------------------------------------------------------*/
/* 2. Assign agents                                                    */
/*--------------------------------------------------------------------*/
IF assignAgents \= 'none' THEN DO
   DO a = 1 TO agentFiles.0
      af = STRIP(agentFiles.a)
      IF af = '' THEN ITERATE
      aName = FILESPEC('N', af)
      aName = LEFT(aName, LASTPOS('.', aName) - 1)

      /* Check if this agent should be assigned */
      IF assignAgents \= 'all' & WORDPOS(aName, assignAgents) = 0 THEN ITERATE

      /* Read current projects list */
      ac = .TomlParser~parse(af)
      currentProjects = .TomlParser~get(ac, 'projects', '')

      /* Skip if already assigned */
      IF WORDPOS(projCode, currentProjects) > 0 THEN DO
         SAY '  'aName': already assigned to' projCode
         ITERATE
      END

      /* Append project code to the projects line in the TOML file */
      IF currentProjects = '' THEN
         newProjects = projCode
      ELSE
         newProjects = currentProjects projCode

      /* Rewrite the projects line */
      content = CHARIN(af, 1, CHARS(af))
      CALL STREAM af, 'C', 'CLOSE'

      projPos = POS('projects', content)
      IF projPos > 0 THEN DO
         /* Find the line and replace it */
         beforeLine = LEFT(content, projPos - 1)
         fromLine = SUBSTR(content, projPos)
         PARSE VAR fromLine . '0a'x afterLine
         newLine = 'projects = "'newProjects'"'
         content = beforeLine || newLine || '0a'x || afterLine
      END
      ELSE DO
         /* No projects line — append one */
         content = content || 'projects = "'newProjects'"' || '0a'x
      END

      IF SysFileExists(af) THEN CALL SysFileDelete af
      CALL CHAROUT af, content
      CALL STREAM af, 'C', 'CLOSE'
      SAY '  'aName': assigned to' projCode
   END
END

/*--------------------------------------------------------------------*/
/* 3. Seed wiki pages                                                  */
/*--------------------------------------------------------------------*/
SAY '  Seeding wiki pages...'

ctxContent = 'Project: 'projCode || '0a'x
ctxContent = ctxContent || 'Client: 'client || '0a'x
ctxContent = ctxContent || 'Goal: 'goal || '0a'x
CALL .FossilHelper~wikiCommit 'Projects/'projCode'/Context', ctxContent

goalId = 'G-'projCode'-001'
goalContent = '# 'goalId || '0a'x || '0a'x || goal || '0a'x
CALL .FossilHelper~wikiCommit 'Goals/'goalId, goalContent

SAY '  Wiki pages created'

/*--------------------------------------------------------------------*/
/* 4. Create first epic ticket                                         */
/*--------------------------------------------------------------------*/
IF goal \= '' THEN DO
   SAY '  Creating initial epic ticket...'
   CALL .FossilHelper~ticketAdd goal, -
      'type=epic assignee=cto project='projCode -
      'goal_id='goalId 'status=open'
   SAY '  Epic ticket created'
END

/*--------------------------------------------------------------------*/
/* 5. Fossil commit                                                    */
/*--------------------------------------------------------------------*/
CALL .FossilHelper~commitAll '[add-project] 'projCode': 'goal

SAY ''
SAY '================================================================'
SAY ' Project "'projCode'" added successfully.'
SAY ''
SAY ' Next steps:'
SAY '   1. Create the working directory:' workDir
SAY '   2. Run preflight: rexx' ralphclipHome'/orchestrate.rex --preflight'
SAY '   3. Dry run:       rexx' ralphclipHome'/orchestrate.rex --dry-run'
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
