#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* word-count-checker.rex — Validate blog posts meet minimum word count */
/*--------------------------------------------------------------------*/

workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')
minWords = 1500
issues = 0

/* Find all blog markdown files */
ADDRESS SYSTEM 'find' workingDir'/content -name "blog-*.md" 2>/dev/null' ,
   WITH OUTPUT STEM blogs.

IF blogs.0 = 0 THEN DO
   SAY 'No blog files found in content/ directory.'
   SAY '<promise>COMPLETE</promise>'
   EXIT 0
END

SAY 'Checking word counts (minimum:' minWords 'words)...'
SAY ''

DO b = 1 TO blogs.0
   file = STRIP(blogs.b)
   IF file = '' THEN ITERATE

   content = CHARIN(file, 1, CHARS(file))
   CALL STREAM file, 'C', 'CLOSE'

   wordCount = WORDS(content)
   shortName = SUBSTR(file, LASTPOS('/', file) + 1)

   IF wordCount < minWords THEN DO
      issues = issues + 1
      SAY shortName ':' wordCount 'words — BELOW MINIMUM'
      SAY ''
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
   SAY ''
   SAY 'All posts meet word count targets.'
   SAY '<promise>COMPLETE</promise>'
END

EXIT 0
