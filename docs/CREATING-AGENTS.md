# Creating ooRexx Agents

ooRexx agents are scripts that perform logic-bearing work — analysis, validation, metrics, invoicing — without calling an LLM. They run in the same orchestration loop as AI agents, use the same interface, and cost nothing.

## When to Use an ooRexx Agent

Use an ooRexx agent when the task:

- Follows deterministic rules (no judgment needed)
- Involves parsing structured data and producing formatted output
- Requires arithmetic (budget calculations, metrics, density checks)
- Cross-references data sources (tickets vs commits, keywords vs content)
- Would waste money as an LLM call

Use a **bash script** agent instead when you are just wrapping an external tool (phpcs, phpunit, rsync, curl). Use an **AI agent** when the task requires reasoning, creativity, or understanding natural language.

## The Agent Contract

Every ooRexx agent must:

1. Read its working directory from the `RALPHCLIP_WORKING_DIR` environment variable.
2. Write output to `STDOUT` — this is what the orchestrator captures.
3. Output `<promise>COMPLETE</promise>` if the task succeeded.
4. Output Markdown-formatted issues if problems were found (the orchestrator will create tickets from them).
5. Exit with code 0 on success, non-zero on failure.

## Skeleton Agent

Save this as `scripts/my-agent.rex`:

```rexx
#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* my-agent.rex — Description of what this agent does                  */
/*--------------------------------------------------------------------*/

/* Read environment */
workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')
ticketId   = VALUE('RALPHCLIP_TICKET_ID',, 'ENVIRONMENT')

/* Do the work */
SAY 'Starting analysis...'

/* ... your logic here ... */

/* Report results */
IF everythingOk THEN DO
   SAY 'All checks passed.'
   SAY '<promise>COMPLETE</promise>'
END
ELSE DO
   SAY '## Issue: Description of the problem'
   SAY '- assignee: engineer'
   SAY '- severity: medium'
   SAY '- details: What went wrong'
END

EXIT 0
```

## The TOML Config

Register it in `workspace/agents/`:

```toml
# workspace/agents/my-agent.toml
role = "My Analysis Agent"
runtime = "rexx"
script = "scripts/my-agent.rex"
budget_usd = 0.00
trigger = "after:engineer"       # or "always", "manual", "cron:..."
projects = ["myplugin"]
```

## Reading Files

ooRexx reads files with `CHARIN`. Always close the file after reading:

```rexx
/* Read a file into a string */
readFile: PROCEDURE
   PARSE ARG filePath
   IF \SysFileExists(filePath) THEN RETURN ''
   content = CHARIN(filePath, 1, CHARS(filePath))
   CALL STREAM filePath, 'C', 'CLOSE'
   RETURN content
```

For line-by-line reading:

```rexx
/* Read file line by line into a stem */
readLines: PROCEDURE EXPOSE lines.
   PARSE ARG filePath
   lines.0 = 0
   IF \SysFileExists(filePath) THEN RETURN
   DO WHILE LINES(filePath) > 0
      lines.0 = lines.0 + 1
      n = lines.0
      lines.n = LINEIN(filePath)
   END
   CALL STREAM filePath, 'C', 'CLOSE'
   RETURN
```

## Running Shell Commands

Use `ADDRESS SYSTEM` with `WITH OUTPUT STEM` to capture output:

```rexx
/* Run a command and capture output */
ADDRESS SYSTEM 'ls -la' workingDir WITH OUTPUT STEM files.

DO i = 1 TO files.0
   SAY files.i
END
```

Check return codes:

```rexx
ADDRESS SYSTEM 'vendor/bin/phpunit --filter=TestClass' WITH OUTPUT STEM out.
IF RC \= 0 THEN DO
   SAY 'Tests failed with exit code' RC
END
```

## Querying Fossil

Your agent can query the Fossil ticket database directly:

```rexx
/* Get all open tickets for a project */
ADDRESS SYSTEM 'fossil ticket list status=open project=myplugin' ,
   '--format "%u|%t|%x(assignee)|%x(cost_usd)"' ,
   WITH OUTPUT STEM tickets.

DO t = 1 TO tickets.0
   PARSE VAR tickets.t id '|' title '|' assignee '|' cost
   SAY id '-' STRIP(title) '(' STRIP(assignee) ') $'STRIP(cost)
END
```

## Writing to Fossil Wiki

```rexx
/* Write content to a wiki page */
updateWiki: PROCEDURE
   PARSE ARG pageName, content
   tmpFile = '/tmp/ralphclip_wiki_'RANDOM(100000)'.md'
   CALL CHAROUT tmpFile, content
   CALL STREAM tmpFile, 'C', 'CLOSE'
   ADDRESS SYSTEM 'fossil wiki commit "'pageName'" <' tmpFile
   CALL SysFileDelete tmpFile
   RETURN
```

## Parsing Structured Text with PARSE

REXX's `PARSE` instruction is the primary tool for extracting data. Key patterns:

```rexx
/* Split on a delimiter */
line = "engineer-php|Build REST API|G001 > Data Model"
PARSE VAR line agent '|' title '|' goalChain

/* Extract a value after a label */
configLine = "  budget_usd = 40.00"
PARSE VAR configLine . '=' value .
/* value is now "40.00" */

/* Extract from a known format */
costLine = "Total cost: $0.0432 (1,247 tokens)"
PARSE VAR costLine . 'cost: $' dollars '(' .
/* dollars is now "0.0432" */

/* Multi-part parse */
timestamp = "2026-04-05T08:30:15"
PARSE VAR timestamp year '-' month '-' day 'T' hour ':' minute ':' second
```

## Counting and Searching

```rexx
/* Count occurrences of a string */
countOccurrences: PROCEDURE
   PARSE ARG haystack, needle
   count = 0; startPos = 1
   DO FOREVER
      pos = POS(needle, haystack, startPos)
      IF pos = 0 THEN LEAVE
      count = count + 1
      startPos = pos + 1
   END
   RETURN count

/* Find lines matching a pattern */
findMatching: PROCEDURE EXPOSE results.
   PARSE ARG filePath, pattern
   results.0 = 0
   DO WHILE LINES(filePath) > 0
      line = LINEIN(filePath)
      IF POS(TRANSLATE(pattern), TRANSLATE(line)) > 0 THEN DO
         results.0 = results.0 + 1
         n = results.0
         results.n = line
      END
   END
   CALL STREAM filePath, 'C', 'CLOSE'
   RETURN
```

## Example: Word Count Validator

An agent that checks blog posts meet minimum word counts:

```rexx
#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* word-count-checker.rex — Validates content meets word count targets  */
/*--------------------------------------------------------------------*/

workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')
minWords = 1500
issues = 0

/* Find all blog markdown files */
ADDRESS SYSTEM 'find' workingDir'/content -name "blog-*.md"' ,
   WITH OUTPUT STEM blogs.

DO b = 1 TO blogs.0
   file = STRIP(blogs.b)
   IF file = '' THEN ITERATE

   content = CHARIN(file, 1, CHARS(file))
   CALL STREAM file, 'C', 'CLOSE'

   wordCount = WORDS(content)
   shortName = SUBSTR(file, LASTPOS('/', file) + 1)

   IF wordCount < minWords THEN DO
      issues = issues + 1
      SAY '## Issue: Blog post under minimum word count'
      SAY '- file:' shortName
      SAY '- words:' wordCount '(minimum:' minWords')'
      SAY '- assignee: seo-writer'
      SAY '- severity: medium'
      SAY ''
   END
   ELSE SAY shortName ':' wordCount 'words — OK'
END

IF issues = 0 THEN DO
   SAY 'All posts meet word count targets.'
   SAY '<promise>COMPLETE</promise>'
END
ELSE SAY issues 'posts below minimum.'

EXIT 0
```

Register it:

```toml
# workspace/agents/word-counter.toml
role = "Word Count Checker"
runtime = "rexx"
script = "scripts/word-count-checker.rex"
budget_usd = 0.00
trigger = "after:seo-writer"
projects = ["paddockapp"]
```

## Example: Ticket-Commit Auditor

Cross-references closed tickets against git history:

```rexx
#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* audit-tickets.rex — Finds closed tickets with no matching commit    */
/*--------------------------------------------------------------------*/

workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')

/* Get closed tickets */
ADDRESS SYSTEM 'fossil ticket list status=closed' ,
   '--format "%u|%t|%x(assignee)"' WITH OUTPUT STEM closed.

/* Get recent commits */
ADDRESS SYSTEM 'cd' workingDir '&& git log --oneline --since="7 days ago"' ,
   WITH OUTPUT STEM commits.

/* Build searchable commit text */
commitText = ''
DO c = 1 TO commits.0
   commitText = commitText TRANSLATE(commits.c)
END

orphans = 0

DO t = 1 TO closed.0
   PARSE VAR closed.t ticketId '|' title '|' assignee
   title = STRIP(title)

   /* Check if any significant word from the title appears in commits */
   matched = 0
   DO w = 1 TO WORDS(title)
      word = TRANSLATE(WORD(title, w))
      IF LENGTH(word) > 3 & POS(word, commitText) > 0 THEN matched = 1
   END

   IF \matched THEN DO
      orphans = orphans + 1
      SAY '## Issue: Closed ticket with no matching commit'
      SAY '- ticket:' STRIP(ticketId)
      SAY '- title:' title
      SAY '- assignee:' STRIP(assignee)
      SAY '- severity: high'
      SAY ''
   END
END

IF orphans = 0 THEN DO
   SAY 'All closed tickets have matching commits.'
   SAY '<promise>COMPLETE</promise>'
END
ELSE SAY orphans 'orphaned tickets found.'

EXIT 0
```

## Example: Hybrid Agent (Deterministic + Conditional AI)

An agent that computes metrics first, then only calls an AI if something looks wrong:

```rexx
#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* code-health.rex — Compute code metrics, get AI advice if needed     */
/*--------------------------------------------------------------------*/

workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')

/* Count PHP files and total lines */
ADDRESS SYSTEM 'find' workingDir '-name "*.php" -not -path "*/vendor/*"' ,
   '| xargs wc -l | tail -1' WITH OUTPUT STEM loc.
PARSE VAR loc.1 totalLines .

/* Count functions longer than 50 lines */
ADDRESS SYSTEM 'grep -c "function " ' workingDir'/includes/*.php' ,
   WITH OUTPUT STEM funcCounts.

/* Count TODO/FIXME markers */
ADDRESS SYSTEM 'grep -rn "TODO\|FIXME"' workingDir'/includes/' ,
   WITH OUTPUT STEM todos.

SAY 'Code health report:'
SAY '  Total lines:' totalLines
SAY '  TODO/FIXME markers:' todos.0

/* Only call AI if metrics look concerning */
IF todos.0 > 10 THEN DO
   SAY 'High TODO count detected. Getting AI recommendation...'

   prompt = 'This WordPress plugin has' todos.0 'TODO/FIXME markers.' ,
            'The most critical ones are:'
   DO t = 1 TO MIN(todos.0, 5)
      prompt = prompt || '0a'x || todos.t
   END
   prompt = prompt || '0a'x || 'List the top 3 to address first and why.'

   /* Shell out to a cheap model */
   tmpFile = '/tmp/ralphclip_prompt_'RANDOM(100000)'.md'
   CALL CHAROUT tmpFile, prompt
   CALL STREAM tmpFile, 'C', 'CLOSE'
   ADDRESS SYSTEM 'vibe --prompt "$(cat' tmpFile')" --max-price 0.05 2>&1' ,
      WITH OUTPUT STEM advice.

   DO a = 1 TO advice.0
      SAY advice.a
   END
   CALL SysFileDelete tmpFile
END
ELSE DO
   SAY 'Code health within acceptable range.'
   SAY '<promise>COMPLETE</promise>'
END

EXIT 0
```

This agent costs zero when the code is healthy and a few cents when it is not.

## Tips

- Always close files after reading with `CALL STREAM file, 'C', 'CLOSE'`.
- Use `TRANSLATE()` for case-insensitive comparisons.
- Use `FORMAT(number,, 2)` for currency values to get consistent decimal places.
- Use `SIGNAL ON SYNTAX NAME errorHandler` for graceful error handling.
- Use `SysFileExists(path)` before reading to avoid errors.
- Test your agent standalone: `RALPHCLIP_WORKING_DIR=~/myproject rexx scripts/my-agent.rex`
