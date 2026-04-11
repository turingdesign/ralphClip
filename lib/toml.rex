#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* toml.rex — Minimal TOML parser for RalphClip                       */
/*                                                                     */
/* Handles: flat key=value pairs, quoted strings, numbers, booleans,  */
/*          single-line arrays, [section] and [section.subsection]     */
/*          headers, multi-line strings (triple-quote), comments.     */
/*                                                                     */
/* Does NOT handle: inline tables, nested arrays, date types.         */
/* These are not needed for RalphClip configs.                        */
/*--------------------------------------------------------------------*/

::CLASS TomlParser PUBLIC

/*--------------------------------------------------------------------*/
/* parse — reads a TOML file and returns a Directory of values         */
/* Keys are flattened: [agents.cto] model = "x" → agents.cto.model    */
/*--------------------------------------------------------------------*/
::METHOD parse CLASS
   USE ARG filePath

   config = .Directory~new
   IF \SysFileExists(filePath) THEN DO
      SAY '[toml] File not found:' filePath
      RETURN config
   END

   currentSection = ''
   inMultiline = .false
   multilineKey = ''
   multilineVal = ''

   DO WHILE LINES(filePath) > 0
      line = LINEIN(filePath)
      stripped = STRIP(line)

      /* Skip blank lines and comments */
      IF stripped = '' THEN ITERATE
      IF LEFT(stripped, 1) = '#' THEN ITERATE

      /* Handle multi-line strings (triple-quote) */
      IF inMultiline THEN DO
         /* Close multi-line only when """ is the entire line or ends the line.
            This prevents premature closure when """ appears mid-content. */
         IF stripped = '"""' | RIGHT(stripped, 3) = '"""' THEN DO
            IF stripped = '"""' THEN
               before = ''
            ELSE
               before = LEFT(stripped, LENGTH(stripped) - 3)
            multilineVal = multilineVal || before
            fullKey = currentSection || '.' || multilineKey
            IF LEFT(fullKey, 1) = '.' THEN fullKey = SUBSTR(fullKey, 2)
            config[fullKey] = multilineVal
            inMultiline = .false
         END
         ELSE multilineVal = multilineVal || stripped || '0a'x
         ITERATE
      END

      /* Section header: [section] or [section.subsection] */
      IF LEFT(stripped, 1) = '[' THEN DO
         PARSE VAR stripped '[' sectionName ']'
         currentSection = STRIP(sectionName)
         ITERATE
      END

      /* Key = value pair */
      eqPos = POS('=', stripped)
      IF eqPos = 0 THEN ITERATE

      key = STRIP(LEFT(stripped, eqPos - 1))
      rawVal = STRIP(SUBSTR(stripped, eqPos + 1))

      /* Strip inline comments (not inside quotes) */
      /* TOML spec: inline comments must be preceded by whitespace */
      IF LEFT(rawVal, 1) \= '"' & LEFT(rawVal, 1) \= '[' THEN DO
         /* Scan for ' #' or tab+'#' pattern — not bare '#' mid-word */
         commentPos = 0
         DO ci = 2 TO LENGTH(rawVal)
            IF SUBSTR(rawVal, ci, 1) = '#' THEN DO
               prevChar = SUBSTR(rawVal, ci - 1, 1)
               IF prevChar = ' ' | prevChar = '09'x THEN DO
                  commentPos = ci - 1  /* trim from the whitespace */
                  LEAVE
               END
            END
         END
         IF commentPos > 0 THEN rawVal = STRIP(LEFT(rawVal, commentPos))
      END

      /* Determine value type and parse */
      val = .TomlParser~parseValue(rawVal)

      /* Check for multi-line string start */
      IF val = '"""' | LEFT(rawVal, 3) = '"""' THEN DO
         inMultiline = .true
         multilineKey = key
         /* Content after opening """ */
         PARSE VAR rawVal '"""' rest
         multilineVal = rest || '0a'x
         ITERATE
      END

      /* Build the full dotted key */
      IF currentSection \= '' THEN
         fullKey = currentSection || '.' || key
      ELSE
         fullKey = key

      config[fullKey] = val
   END

   CALL STREAM filePath, 'C', 'CLOSE'
   RETURN config


/*--------------------------------------------------------------------*/
/* parseValue — determine type and extract value                       */
/*--------------------------------------------------------------------*/
::METHOD parseValue CLASS PRIVATE
   USE ARG rawVal

   /* Quoted string */
   IF LEFT(rawVal, 1) = '"' THEN DO
      PARSE VAR rawVal '"' val '"'
      RETURN val
   END

   /* Array: ["a", "b", "c"] */
   IF LEFT(rawVal, 1) = '[' THEN DO
      PARSE VAR rawVal '[' inner ']'
      result = ''
      remaining = STRIP(inner)
      DO WHILE remaining \= ''
         /* Handle quoted elements */
         IF LEFT(remaining, 1) = '"' THEN DO
            PARSE VAR remaining '"' element '"' rest
            IF result \= '' THEN result = result || ' '
            result = result || element
            PARSE VAR rest ',' remaining
            remaining = STRIP(remaining)
         END
         ELSE DO
            /* Unquoted (number or boolean) */
            PARSE VAR remaining element ',' remaining
            element = STRIP(element)
            remaining = STRIP(remaining)
            IF element \= '' THEN DO
               IF result \= '' THEN result = result || ' '
               result = result || element
            END
         END
      END
      RETURN result  /* space-separated list */
   END

   /* Boolean */
   IF rawVal = 'true' THEN RETURN 1
   IF rawVal = 'false' THEN RETURN 0

   /* Number (integer or float) — return as-is, REXX handles both */
   IF DATATYPE(rawVal, 'N') THEN RETURN rawVal

   /* Fallback: return raw */
   RETURN rawVal


/*--------------------------------------------------------------------*/
/* get — convenience method for reading a dotted key with default      */
/*--------------------------------------------------------------------*/
::METHOD get CLASS
   USE ARG config, key, default
   IF ARG(3, 'O') THEN default = ''
   IF config~hasIndex(key) THEN RETURN config[key]
   RETURN default


/*--------------------------------------------------------------------*/
/* sections — list all unique section prefixes                         */
/*--------------------------------------------------------------------*/
::METHOD sections CLASS
   USE ARG config, prefix
   result = .Array~new
   supplier = config~supplier
   DO WHILE supplier~available
      key = supplier~index
      IF LEFT(key, LENGTH(prefix)) = prefix THEN DO
         /* Extract the next segment */
         rest = SUBSTR(key, LENGTH(prefix) + 2)  /* skip prefix. */
         PARSE VAR rest segment '.' .
         candidate = prefix || '.' || segment
         /* Add if not already present */
         found = .false
         DO i = 1 TO result~items
            IF result[i] = candidate THEN found = .true
         END
         IF \found THEN result~append(candidate)
      END
      supplier~next
   END
   RETURN result
