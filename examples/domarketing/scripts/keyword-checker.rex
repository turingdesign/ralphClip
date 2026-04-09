#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* keyword-checker.rex — Validate keyword density in SEO blog posts    */
/* Reads target keywords from Fossil wiki, checks each blog draft.    */
/*--------------------------------------------------------------------*/

workingDir = VALUE('RALPHCLIP_WORKING_DIR',, 'ENVIRONMENT')

/* Read keyword targets from Fossil wiki */
ADDRESS SYSTEM 'fossil wiki export "Projects/PaddockApp/Keywords" 2>/dev/null' ,
   WITH OUTPUT STEM kwPage.

primary. = ''; primary.0 = 0
secondary. = ''; secondary.0 = 0

DO k = 1 TO kwPage.0
   line = STRIP(kwPage.k)
   IF LEFT(line, 10) = '- primary:' THEN DO
      primary.0 = primary.0 + 1
      n = primary.0
      primary.n = STRIP(SUBSTR(line, 11))
   END
   IF LEFT(line, 12) = '- secondary:' THEN DO
      secondary.0 = secondary.0 + 1
      n = secondary.0
      secondary.n = STRIP(SUBSTR(line, 13))
   END
END

IF primary.0 = 0 THEN DO
   SAY 'No keywords defined in wiki page Projects/PaddockApp/Keywords.'
   SAY 'Expected format:'
   SAY '  - primary: paddock rotation'
   SAY '  - secondary: horse property management'
   SAY '<promise>COMPLETE</promise>'
   EXIT 0
END

SAY 'Loaded' primary.0 'primary and' secondary.0 'secondary keywords.'

/* Scan each blog draft */
ADDRESS SYSTEM 'find' workingDir'/content -name "blog-*.md" 2>/dev/null' ,
   WITH OUTPUT STEM blogs.

issues = 0

DO b = 1 TO blogs.0
   file = STRIP(blogs.b)
   IF file = '' THEN ITERATE

   content = CHARIN(file, 1, CHARS(file))
   CALL STREAM file, 'C', 'CLOSE'
   contentUpper = TRANSLATE(content)
   totalWords = WORDS(content)
   shortName = SUBSTR(file, LASTPOS('/', file) + 1)

   SAY ''
   SAY 'Checking:' shortName '('totalWords 'words)'

   /* Check primary keywords — target 1.0-2.5% */
   DO p = 1 TO primary.0
      kw = primary.p
      kwUpper = TRANSLATE(kw)
      count = countOccurrences(contentUpper, kwUpper)
      IF totalWords > 0 THEN
         density = FORMAT((count / totalWords) * 100,, 2)
      ELSE
         density = 0

      SAY '  "'kw'":' count 'occurrences,' density'%'

      IF density < 1.0 THEN DO
         issues = issues + 1
         SAY ''
         SAY '## Issue: Primary keyword density too low'
         SAY '- file:' shortName
         SAY '- keyword:' kw
         SAY '- density:' density'% (target: 1.0-2.5%)'
         SAY '- assignee: seo-writer'
         SAY '- severity: medium'
         SAY ''
      END
      ELSE IF density > 2.5 THEN DO
         issues = issues + 1
         SAY ''
         SAY '## Issue: Primary keyword density too high (stuffing risk)'
         SAY '- file:' shortName
         SAY '- keyword:' kw
         SAY '- density:' density'% (target: 1.0-2.5%)'
         SAY '- assignee: seo-writer'
         SAY '- severity: medium'
         SAY ''
      END
   END

   /* Check secondary keywords — target 0.5-1.5% */
   DO s = 1 TO secondary.0
      kw = secondary.s
      kwUpper = TRANSLATE(kw)
      count = countOccurrences(contentUpper, kwUpper)
      IF totalWords > 0 THEN
         density = FORMAT((count / totalWords) * 100,, 2)
      ELSE
         density = 0

      SAY '  "'kw'":' count 'occurrences,' density'%'

      IF density < 0.3 THEN DO
         issues = issues + 1
         SAY ''
         SAY '## Issue: Secondary keyword barely present'
         SAY '- file:' shortName
         SAY '- keyword:' kw
         SAY '- density:' density'% (target: 0.5-1.5%)'
         SAY '- assignee: seo-writer'
         SAY '- severity: low'
         SAY ''
      END
   END
END

IF issues = 0 THEN DO
   SAY ''
   SAY 'All keyword densities within target ranges.'
   SAY '<promise>COMPLETE</promise>'
END

EXIT 0

/*--------------------------------------------------------------------*/
/* countOccurrences — count needle in haystack                         */
/*--------------------------------------------------------------------*/
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
