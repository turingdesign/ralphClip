#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* tests/test-unit.rex — Unit tests for RalphClip library modules      */
/*                                                                     */
/* Tests: TomlParser, cron matching, budget line matching               */
/*                                                                     */
/* Usage:  rexx tests/test-unit.rex [path-to-ralphclip-dir]            */
/* Prerequisites: ooRexx only. No Fossil or AI runtimes needed.        */
/*--------------------------------------------------------------------*/

PARSE ARG ralphclipHome
IF ralphclipHome = '' THEN DO
   PARSE SOURCE . . sourceFile
   ralphclipHome = LEFT(sourceFile, LASTPOS('/', sourceFile) - 1)
   /* Go up one level from tests/ */
   ralphclipHome = LEFT(ralphclipHome, LASTPOS('/', ralphclipHome) - 1)
END

CALL (ralphclipHome'/lib/toml.rex')

pass = 0
fail = 0

SAY '=== RalphClip Unit Tests ==='
SAY ''

/*====================================================================*/
/* TOML Parser Tests                                                   */
/*====================================================================*/
SAY '--- TOML Parser ---'

fixtureDir = ralphclipHome'/tests/fixtures'
config = .TomlParser~parse(fixtureDir'/test-parser.toml')

/* Basic key=value */
CALL assertEq 'string value',       'Test Co',   .TomlParser~get(config, 'company.name')
CALL assertEq 'numeric value',      50.00,       .TomlParser~get(config, 'company.monthly_budget_usd')
CALL assertEq 'boolean true → 1',   1,           .TomlParser~get(config, 'company.active')
CALL assertEq 'boolean false → 0',  0,           .TomlParser~get(config, 'company.disabled')

/* Subsections */
CALL assertEq 'subsection number',  25,          .TomlParser~get(config, 'projects.alpha.budget_usd')
CALL assertEq 'subsection string',  '~/code/alpha', .TomlParser~get(config, 'projects.alpha.working_dir')

/* Arrays become space-separated strings */
CALL assertEq 'string array',       'cto engineer qa', .TomlParser~get(config, 'projects.alpha.agents')
CALL assertEq 'number array',       '1 2 3',           .TomlParser~get(config, 'flat.array_numbers')
CALL assertEq 'single-element array', 'engineer',      .TomlParser~get(config, 'projects.beta.agents')

/* Bare values */
CALL assertEq 'bare integer',       42,          .TomlParser~get(config, 'flat.simple_number')
CALL assertEq 'bare float',         3.14,        .TomlParser~get(config, 'flat.float_number')
CALL assertEq 'bare string',        'hello',     .TomlParser~get(config, 'flat.bare_string')
CALL assertEq 'quoted string',      'world',     .TomlParser~get(config, 'flat.quoted_string')

/* Inline comments stripped */
CALL assertEq 'inline comment stripped', 100,    .TomlParser~get(config, 'flat.inline_comment')

/* Default values */
CALL assertEq 'missing key default', 'fallback', .TomlParser~get(config, 'nonexistent.key', 'fallback')
CALL assertEq 'missing key empty',   '',          .TomlParser~get(config, 'nonexistent.key')

/* sections() method */
sections = .TomlParser~sections(config, 'projects')
CALL assertEq 'sections count', 2, sections~items
SAY ''

/*====================================================================*/
/* Cron Field Matching Tests                                           */
/*====================================================================*/
SAY '--- Cron Field Matching ---'

/* We test cronFieldMatches via the orchestrate.rex PROCEDURE.
   Since it's a PROCEDURE, we duplicate the logic here. */

/* Wildcard */
CALL assertEq 'cron * matches anything',       1, cronFieldMatches('*', 5)
CALL assertEq 'cron * matches zero',            1, cronFieldMatches('*', 0)

/* Exact match */
CALL assertEq 'cron exact match',               1, cronFieldMatches('5', 5)
CALL assertEq 'cron exact no match',            0, cronFieldMatches('5', 3)

/* Range */
CALL assertEq 'cron range match low',           1, cronFieldMatches('1-5', 1)
CALL assertEq 'cron range match mid',           1, cronFieldMatches('1-5', 3)
CALL assertEq 'cron range match high',          1, cronFieldMatches('1-5', 5)
CALL assertEq 'cron range no match below',      0, cronFieldMatches('1-5', 0)
CALL assertEq 'cron range no match above',      0, cronFieldMatches('1-5', 6)

/* Step on wildcard */
CALL assertEq 'cron */5 matches 0',             1, cronFieldMatches('*/5', 0)
CALL assertEq 'cron */5 matches 15',            1, cronFieldMatches('*/5', 15)
CALL assertEq 'cron */5 no match 7',            0, cronFieldMatches('*/5', 7)

/* Comma-separated list */
CALL assertEq 'cron list match first',          1, cronFieldMatches('1,3,5', 1)
CALL assertEq 'cron list match last',           1, cronFieldMatches('1,3,5', 5)
CALL assertEq 'cron list no match',             0, cronFieldMatches('1,3,5', 2)

/* Step on range */
CALL assertEq 'cron range/step match',          1, cronFieldMatches('0-10/2', 4)
CALL assertEq 'cron range/step no match',       0, cronFieldMatches('0-10/2', 3)
CALL assertEq 'cron range/step boundary',       1, cronFieldMatches('0-10/2', 0)

SAY ''

/*====================================================================*/
/* Budget Line Matching Tests                                          */
/*====================================================================*/
SAY '--- Budget Line Matching ---'

/* Test the anchored matching logic inline */
page = 'cap: 50' || '0a'x
page = page || 'spent: 10.0000' || '0a'x
page = page || 'qa: 3.0000' || '0a'x
page = page || 'qa-lead: 5.0000' || '0a'x

/* readLineValue should match "qa:" exactly, not "qa-lead:" */
CALL assertEq 'anchored match qa',        3.0000, readLineValue(page, 'qa:')
CALL assertEq 'anchored match qa-lead',   5.0000, readLineValue(page, 'qa-lead:')
CALL assertEq 'anchored match spent',    10.0000, readLineValue(page, 'spent:')
CALL assertEq 'anchored no match missing', 0,     readLineValue(page, 'engineer:')

/* Edge case: marker at start of string */
startPage = 'alpha: 7.0000' || '0a'x || 'beta: 2.0000' || '0a'x
CALL assertEq 'match at start of string', 7.0000, readLineValue(startPage, 'alpha:')
CALL assertEq 'match not at start',       2.0000, readLineValue(startPage, 'beta:')

/* Edge case: substring that's NOT at a line boundary */
trickPage = 'spent: 10.0000' || '0a'x || 'overspent: 99.0000' || '0a'x
CALL assertEq 'no false match on overspent', 10.0000, readLineValue(trickPage, 'spent:')

SAY ''

/*====================================================================*/
/* Shell Sanitisation Tests                                            */
/*====================================================================*/
SAY '--- Shell Sanitisation ---'

/* Need fossil.rex loaded for these */
CALL (ralphclipHome'/lib/fossil.rex')

CALL assertEq 'shellSafe strips backtick',   'hello world', .FossilHelper~shellSafe('hello `world`')
CALL assertEq 'shellSafe strips semicolon',  'abc', .FossilHelper~shellSafe('a;b;c')
CALL assertEq 'shellSafe strips pipe',       'ab',  .FossilHelper~shellSafe('a|b')
CALL assertEq 'shellSafe strips dollar',     'HOME', .FossilHelper~shellSafe('$HOME')
CALL assertEq 'shellSafe allows safe chars', 'hello-world_1.0', .FossilHelper~shellSafe('hello-world_1.0')
CALL assertEq 'shellSafe allows slash',      '/tmp/foo', .FossilHelper~shellSafe('/tmp/foo')

CALL assertEq 'shellSafeStrict strips slash', 'tmpfoo', .FossilHelper~shellSafeStrict('/tmp/foo')
CALL assertEq 'shellSafeStrict strips colon', 'ab', .FossilHelper~shellSafeStrict('a:b')

SAY ''

/*====================================================================*/
/* Summary                                                             */
/*====================================================================*/
SAY '=== Results:' pass 'passed,' fail 'failed ==='
IF fail > 0 THEN EXIT 1
EXIT 0


/*====================================================================*/
/* Test helpers                                                        */
/*====================================================================*/

assertEq: PROCEDURE EXPOSE pass fail
   PARSE ARG label, expected, actual
   IF expected = actual THEN DO
      SAY '  PASS:' label
      pass = pass + 1
   END
   ELSE DO
      SAY '  FAIL:' label '(expected "'expected'", got "'actual'")'
      fail = fail + 1
   END
   RETURN


/*====================================================================*/
/* Duplicated logic from orchestrate.rex (PROCEDURE = local scope)     */
/*====================================================================*/

cronFieldMatches: PROCEDURE
   PARSE ARG field, value

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


/*--------------------------------------------------------------------*/
/* readLineValue — duplicated from mutex.rex for standalone testing    */
/*--------------------------------------------------------------------*/
readLineValue: PROCEDURE
   USE ARG page, marker
   IF page = '' THEN RETURN 0

   nlMarker = '0a'x || marker
   pos = POS(nlMarker, page)
   IF pos > 0 THEN
      pos = pos + 1
   ELSE DO
      IF LEFT(page, LENGTH(marker)) = marker THEN
         pos = 1
      ELSE
         RETURN 0
   END

   chunk = SUBSTR(page, pos + LENGTH(marker))
   PARSE VAR chunk spent .
   IF DATATYPE(STRIP(spent), 'N') THEN RETURN STRIP(spent)
   RETURN 0
