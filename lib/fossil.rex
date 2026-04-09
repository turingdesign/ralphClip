#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* fossil.rex — Fossil SCM helper routines for RalphClip               */
/*--------------------------------------------------------------------*/

::CLASS FossilHelper PUBLIC

/*--------------------------------------------------------------------*/
/* preflight — verify Fossil is installed and CWD is inside a checkout */
/* Returns 1 if ok, 0 if not. Prints diagnostic to SAY.               */
/*--------------------------------------------------------------------*/
::METHOD preflight CLASS
   /* Check fossil binary exists */
   ADDRESS SYSTEM 'fossil version 2>/dev/null' WITH OUTPUT STEM ver.
   IF ver.0 = 0 THEN DO
      SAY '[FATAL] fossil binary not found. Install from https://fossil-scm.org/'
      RETURN 0
   END

   /* Check we're inside a checkout */
   ADDRESS SYSTEM 'fossil status 2>&1' WITH OUTPUT STEM stat.
   IF stat.0 = 0 THEN DO
      SAY '[FATAL] Not inside a Fossil checkout. Run from your workspace directory.'
      RETURN 0
   END
   /* fossil status returns "NOT_A_CHECKOUT" if not in a checkout */
   firstLine = ''
   IF stat.0 > 0 THEN firstLine = TRANSLATE(stat.1)
   IF POS('NOT_A_CHECKOUT', firstLine) > 0 | POS('NOT A CHECKOUT', firstLine) > 0 THEN DO
      SAY '[FATAL] Not inside a Fossil checkout. Run from your workspace directory.'
      RETURN 0
   END

   RETURN 1

/*--------------------------------------------------------------------*/
/* shellSafe — strip shell metacharacters from a string                */
/* Prevents command injection when interpolating into shell commands.  */
/* Allows: alphanumeric, space, underscore, hyphen, dot, colon,       */
/*         slash, comma, equals, at-sign, parentheses, plus, hash     */
/* Strips: backtick, semicolon, pipe, ampersand, dollar, quotes,      */
/*         angle brackets, newlines, backslash, exclamation            */
/*--------------------------------------------------------------------*/
::METHOD shellSafe CLASS
   USE ARG input
   safe = ''
   allowed = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.:,/=@()+#'
   DO i = 1 TO LENGTH(input)
      c = SUBSTR(input, i, 1)
      IF POS(c, allowed) > 0 THEN safe = safe || c
   END
   RETURN safe

/*--------------------------------------------------------------------*/
/* shellSafeStrict — restrictive sanitisation for general use          */
/* Only allows: alphanumeric, space, underscore, hyphen, dot          */
/* Use this for user-sourced content outside Fossil CLI context.      */
/*--------------------------------------------------------------------*/
::METHOD shellSafeStrict CLASS
   USE ARG input
   safe = ''
   allowed = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.'
   DO i = 1 TO LENGTH(input)
      c = SUBSTR(input, i, 1)
      IF POS(c, allowed) > 0 THEN safe = safe || c
   END
   RETURN safe

/*--------------------------------------------------------------------*/
/* safeTmpFile — generate a collision-resistant temp file path          */
/* Requires mktemp (POSIX). Fails fast if unavailable.                */
/*--------------------------------------------------------------------*/
::METHOD safeTmpFile CLASS
   USE ARG prefix
   IF prefix = '' THEN prefix = 'ralphclip'
   ADDRESS SYSTEM 'mktemp /tmp/'prefix'_XXXXXXXX.md 2>/dev/null' WITH OUTPUT STEM mk.
   IF mk.0 > 0 & STRIP(mk.1) \= '' THEN RETURN STRIP(mk.1)
   /* mktemp unavailable — fatal error rather than unsafe fallback */
   SAY '[FATAL] mktemp is required but not available. Install coreutils.'
   RAISE SYNTAX 40.900 ARRAY('mktemp not available — cannot create safe temp files')

/*--------------------------------------------------------------------*/
/* wikiExport — read a wiki page and return its content as a string     */
/*--------------------------------------------------------------------*/
::METHOD wikiExport CLASS
   USE ARG pageName
   pageName = .FossilHelper~shellSafe(pageName)
   ADDRESS SYSTEM 'fossil wiki export "' || pageName || '" 2>/dev/null' ,
      WITH OUTPUT STEM lines.
   content = ''
   DO j = 1 TO lines.0
      content = content || lines.j || '0a'x
   END
   RETURN content

/*--------------------------------------------------------------------*/
/* wikiCommit — write content to a wiki page                           */
/*--------------------------------------------------------------------*/
::METHOD wikiCommit CLASS
   USE ARG pageName, content
   pageName = .FossilHelper~shellSafe(pageName)
   tmpFile = .FossilHelper~safeTmpFile('wiki')
   CALL CHAROUT tmpFile, content
   CALL STREAM tmpFile, 'C', 'CLOSE'
   ADDRESS SYSTEM 'fossil wiki commit "' || pageName || '" <' tmpFile '2>/dev/null'
   CALL SysFileDelete tmpFile
   RETURN

/*--------------------------------------------------------------------*/
/* wikiAppend — append a line to a wiki page                           */
/*--------------------------------------------------------------------*/
::METHOD wikiAppend CLASS
   USE ARG pageName, line
   existing = .FossilHelper~wikiExport(pageName)
   CALL .FossilHelper~wikiCommit pageName, existing || line || '0a'x
   RETURN

/*--------------------------------------------------------------------*/
/* ticketList — query tickets with filters, return stem of results      */
/* Returns a stem: result.0 = count, result.N = pipe-delimited row     */
/*--------------------------------------------------------------------*/
::METHOD ticketList CLASS
   USE ARG filters, format
   IF ARG(2, 'O') THEN format = '%u|%t|%x(assignee)|%x(goal_chain)'

   cmd = 'fossil ticket list' filters '--format "' || format || '" 2>/dev/null'
   ADDRESS SYSTEM cmd WITH OUTPUT STEM results.
   RETURN results.

/*--------------------------------------------------------------------*/
/* ticketNext — get next open ticket for an agent, optionally filtered  */
/*              by project. Returns pipe-delimited string or ''        */
/*--------------------------------------------------------------------*/
::METHOD ticketNext CLASS
   USE ARG agentName, projectCode
   agentName = .FossilHelper~shellSafe(agentName)
   projectCode = .FossilHelper~shellSafe(projectCode)
   filters = 'assignee="'agentName'" status=open'
   IF projectCode \= '' THEN filters = filters 'project="'projectCode'"'
   filters = filters '--limit 1'

   format = '%u|%t|%x(goal_chain)|%x(depends)|%x(gate_type)'
   results. = .FossilHelper~ticketList(filters, format)

   IF results.0 = 0 THEN RETURN ''
   IF STRIP(results.1) = '' THEN RETURN ''
   RETURN STRIP(results.1)

/*--------------------------------------------------------------------*/
/* ticketPeek — read-only peek at an agent's next ticket               */
/* Same as ticketNext but clearly read-only — does NOT change status.  */
/* Returns pipe-delimited string or ''. Used by scheduler to get deps. */
/*--------------------------------------------------------------------*/
::METHOD ticketPeek CLASS
   USE ARG agentName, projectCode
   RETURN .FossilHelper~ticketNext(agentName, projectCode)

/*--------------------------------------------------------------------*/
/* ticketAdd — create a new ticket with given fields                    */
/*--------------------------------------------------------------------*/
::METHOD ticketAdd CLASS
   USE ARG title, fields
   title = .FossilHelper~shellSafe(title)
   fields = .FossilHelper~shellSafe(fields)
   cmd = 'fossil ticket add title="'title'"' fields '2>/dev/null'
   ADDRESS SYSTEM cmd
   RETURN

/*--------------------------------------------------------------------*/
/* ticketChange — update a ticket's fields                             */
/*--------------------------------------------------------------------*/
::METHOD ticketChange CLASS
   USE ARG ticketId, fields
   ticketId = .FossilHelper~shellSafe(ticketId)
   fields = .FossilHelper~shellSafe(fields)
   cmd = 'fossil ticket change' ticketId fields '2>/dev/null'
   ADDRESS SYSTEM cmd
   RETURN

/*--------------------------------------------------------------------*/
/* ticketClose — close a ticket                                        */
/*--------------------------------------------------------------------*/
::METHOD ticketClose CLASS
   USE ARG ticketId
   CALL .FossilHelper~ticketChange ticketId, 'status=closed'
   RETURN

/*--------------------------------------------------------------------*/
/* ticketField — read a single field from a ticket                     */
/*--------------------------------------------------------------------*/
::METHOD ticketField CLASS
   USE ARG ticketId, fieldName
   ticketId = .FossilHelper~shellSafe(ticketId)
   fieldName = .FossilHelper~shellSafe(fieldName)
   format = '%x(' || fieldName || ')'
   cmd = 'fossil ticket list uuid="'ticketId'" --format "'format'" --limit 1 2>/dev/null'
   ADDRESS SYSTEM cmd WITH OUTPUT STEM val.
   IF val.0 = 0 THEN RETURN ''
   RETURN STRIP(val.1)

/*--------------------------------------------------------------------*/
/* commitAll — add all changes and commit with a message                */
/*--------------------------------------------------------------------*/
::METHOD commitAll CLASS
   USE ARG message
   message = .FossilHelper~shellSafe(message)
   ADDRESS SYSTEM 'fossil addremove 2>/dev/null'
   ADDRESS SYSTEM 'fossil commit -m "' || message || '" 2>/dev/null'
   RETURN

/*--------------------------------------------------------------------*/
/* allDepsClosed — check if all dependencies are closed                 */
/* deps is a comma-separated list of ticket IDs                        */
/*--------------------------------------------------------------------*/
::METHOD allDepsClosed CLASS
   USE ARG deps
   IF deps = '' THEN RETURN 1  /* no deps = all clear */

   DO WHILE deps \= ''
      PARSE VAR deps dep ',' deps
      dep = STRIP(dep)
      IF dep = '' THEN ITERATE

      status = .FossilHelper~ticketField(dep, 'status')
      IF status \= 'closed' THEN RETURN 0
   END
   RETURN 1

/*--------------------------------------------------------------------*/
/* commitWithTag — addremove, commit with message, then tag the commit */
/*--------------------------------------------------------------------*/
::METHOD commitWithTag CLASS
   USE ARG message, tagName
   message = .FossilHelper~shellSafe(message)
   ADDRESS SYSTEM 'fossil addremove 2>/dev/null'
   ADDRESS SYSTEM 'fossil commit -m "' || message || '" --allow-empty 2>/dev/null'
   IF tagName \= '' THEN
      CALL .FossilHelper~tag tagName
   RETURN

/*--------------------------------------------------------------------*/
/* tag — apply a tag to the current (tip) checkin                      */
/*--------------------------------------------------------------------*/
::METHOD tag CLASS
   USE ARG tagName
   tagName = .FossilHelper~shellSafe(tagName)
   ADDRESS SYSTEM 'fossil tag add "' || tagName || '" tip 2>/dev/null'
   RETURN

/*--------------------------------------------------------------------*/
/* tagExists — check whether a tag/checkin ref exists                   */
/* Returns 1 if found, 0 otherwise                                     */
/*--------------------------------------------------------------------*/
::METHOD tagExists CLASS
   USE ARG ref
   ref = .FossilHelper~shellSafe(ref)
   ADDRESS SYSTEM 'fossil info "' || ref || '" 2>/dev/null' WITH OUTPUT STEM info.
   /* fossil info returns RC=0 and output lines when ref exists */
   RETURN (info.0 > 0)

/*--------------------------------------------------------------------*/
/* isoTimestamp — return current UTC timestamp in ISO 8601 format      */
/* Returns: 2026-04-09T14:23:00Z                                      */
/*--------------------------------------------------------------------*/
::METHOD isoTimestamp CLASS
   /* Get UTC date+time via date -u (POSIX) */
   ADDRESS SYSTEM "date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null" WITH OUTPUT STEM ts.
   IF ts.0 > 0 THEN RETURN STRIP(ts.1)
   /* Fallback: local time (no TZ conversion) */
   d = DATE('S')
   t = TIME()
   RETURN LEFT(d,4)'-'SUBSTR(d,5,2)'-'SUBSTR(d,7,2)'T't'Z'

/*--------------------------------------------------------------------*/
/* isoTimestampCompact — return compact timestamp for filenames        */
/* Returns: 20260409T142300Z                                           */
/*--------------------------------------------------------------------*/
::METHOD isoTimestampCompact CLASS
   ADDRESS SYSTEM "date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null" WITH OUTPUT STEM ts.
   IF ts.0 > 0 THEN RETURN STRIP(ts.1)
   d = DATE('S')
   t = TRANSLATE(TIME(), '', ':')
   RETURN d'T't'Z'

/*--------------------------------------------------------------------*/
/* elapsedMs — return milliseconds between two TIME('E') calls         */
/* Usage: start = TIME('R'); ...; ms = .FossilHelper~elapsedMs(start) */
/* Actually: pass the elapsed seconds value from TIME('E')             */
/*--------------------------------------------------------------------*/
::METHOD elapsedMs CLASS
   USE ARG elapsedSec
   IF \DATATYPE(elapsedSec, 'N') THEN RETURN 0
   RETURN TRUNC(elapsedSec * 1000)
