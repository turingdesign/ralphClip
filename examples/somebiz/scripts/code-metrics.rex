#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* code-metrics.rex — Compute code health metrics for a WP plugin      */
/*                                                                     */
/* Counts PHP files, total lines, TODO/FIXME markers, large functions, */
/* and missing PHPDoc blocks. Updates the project wiki with results.   */
/*--------------------------------------------------------------------*/

workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')

IF workingDir = '' THEN DO
   SAY 'ERROR: RALPHCLIP_WORKING_DIR not set.'
   EXIT 1
END

SAY 'Code metrics for:' workingDir

/*--------------------------------------------------------------------*/
/* Count PHP files and total lines                                     */
/*--------------------------------------------------------------------*/
ADDRESS SYSTEM 'find' workingDir '-name "*.php"' ,
   '-not -path "*/vendor/*" -not -path "*/node_modules/*"' ,
   '| wc -l' WITH OUTPUT STEM fileCount.
phpFiles = STRIP(fileCount.1)

ADDRESS SYSTEM 'find' workingDir '-name "*.php"' ,
   '-not -path "*/vendor/*" -not -path "*/node_modules/*"' ,
   '| xargs wc -l 2>/dev/null | tail -1' WITH OUTPUT STEM locLine.
PARSE VAR locLine.1 totalLines .
IF \DATATYPE(totalLines, 'W') THEN totalLines = 0

/*--------------------------------------------------------------------*/
/* Count TODO and FIXME markers                                        */
/*--------------------------------------------------------------------*/
ADDRESS SYSTEM 'grep -rn "TODO\|FIXME"' workingDir'/includes/' ,
   '--include="*.php" 2>/dev/null | wc -l' WITH OUTPUT STEM todoCount.
todos = STRIP(todoCount.1)
IF \DATATYPE(todos, 'W') THEN todos = 0

/*--------------------------------------------------------------------*/
/* Count test files                                                    */
/*--------------------------------------------------------------------*/
ADDRESS SYSTEM 'find' workingDir'/tests -name "*.php" 2>/dev/null | wc -l' ,
   WITH OUTPUT STEM testCount.
testFiles = STRIP(testCount.1)
IF \DATATYPE(testFiles, 'W') THEN testFiles = 0

/*--------------------------------------------------------------------*/
/* Check for missing PHPDoc on public functions                        */
/*--------------------------------------------------------------------*/
ADDRESS SYSTEM 'grep -rn "public function"' workingDir'/includes/' ,
   '--include="*.php" 2>/dev/null' WITH OUTPUT STEM publicFuncs.
ADDRESS SYSTEM 'grep -B1 "public function"' workingDir'/includes/' ,
   '--include="*.php" 2>/dev/null | grep -c "@" 2>/dev/null' ,
   WITH OUTPUT STEM docCount.

totalPublic = publicFuncs.0
documented = STRIP(docCount.1)
IF \DATATYPE(documented, 'W') THEN documented = 0
undocumented = totalPublic - documented
IF undocumented < 0 THEN undocumented = 0

/*--------------------------------------------------------------------*/
/* Output report                                                       */
/*--------------------------------------------------------------------*/
SAY ''
SAY 'Code Health Report'
SAY '  PHP files:        ' phpFiles
SAY '  Total lines:      ' totalLines
SAY '  Test files:        ' testFiles
SAY '  TODO/FIXME markers:' todos
SAY '  Public functions:  ' totalPublic
SAY '  Undocumented:      ' undocumented

/*--------------------------------------------------------------------*/
/* Update wiki with metrics                                            */
/*--------------------------------------------------------------------*/
report = '# Code Metrics — ' || DATE('N') || '0a'x || '0a'x
report = report || '| Metric | Value |' || '0a'x
report = report || '|--------|-------|' || '0a'x
report = report || '| PHP files |' phpFiles '|' || '0a'x
report = report || '| Total lines |' totalLines '|' || '0a'x
report = report || '| Test files |' testFiles '|' || '0a'x
report = report || '| TODO/FIXME |' todos '|' || '0a'x
report = report || '| Public functions |' totalPublic '|' || '0a'x
report = report || '| Undocumented |' undocumented '|' || '0a'x

tmpFile = '/tmp/ralphclip_metrics_'RANDOM(100000)'.md'
CALL CHAROUT tmpFile, report
CALL STREAM tmpFile, 'C', 'CLOSE'
ADDRESS SYSTEM 'fossil wiki commit "Metrics/CodeHealth" <' tmpFile '2>/dev/null'
CALL SysFileDelete tmpFile

/*--------------------------------------------------------------------*/
/* Flag issues if thresholds exceeded                                  */
/*--------------------------------------------------------------------*/
issues = 0

IF todos > 10 THEN DO
   issues = issues + 1
   SAY ''
   SAY '## Issue: High TODO/FIXME count ('todos')'
   SAY '- assignee: engineer-php'
   SAY '- severity: low'
   SAY '- details: Review and resolve or convert to tickets'
END

IF undocumented > 5 THEN DO
   issues = issues + 1
   SAY ''
   SAY '## Issue: Missing PHPDoc on' undocumented 'public functions'
   SAY '- assignee: techwriter'
   SAY '- severity: medium'
   SAY '- details: Add @param and @return blocks to public API'
END

IF testFiles = 0 & totalLines > 200 THEN DO
   issues = issues + 1
   SAY ''
   SAY '## Issue: No test files found'
   SAY '- assignee: engineer-php'
   SAY '- severity: high'
   SAY '- details: Create tests/ directory and write PHPUnit tests'
END

IF issues = 0 THEN DO
   SAY ''
   SAY 'All metrics within acceptable range.'
   SAY '<promise>COMPLETE</promise>'
END
ELSE SAY ''

EXIT 0
