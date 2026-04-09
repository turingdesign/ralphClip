#!/usr/bin/env rexx
/*--------------------------------------------------------------------*/
/* mutex.rex — Thread-safe Fossil access for concurrent dispatch       */
/*                                                                     */
/* All Fossil operations must go through a single FossilMutex instance */
/* when running agents concurrently. The GUARDED keyword ensures only  */
/* one activity (ooRexx thread) executes any guarded method at a time. */
/*                                                                     */
/* Usage:                                                              */
/*   mutex = .FossilMutex~new()                                       */
/*   mutex~claimTicket(agentName, projCode)  -- atomic query + claim  */
/*   mutex~commitWithTag(msg, tag)           -- serialised commit     */
/*--------------------------------------------------------------------*/

::CLASS FossilMutex PUBLIC

/*--------------------------------------------------------------------*/
/* claimTicket — atomic ticket query + status change                   */
/* Prevents two concurrent workers from grabbing the same ticket.      */
/* Returns pipe-delimited ticket string or '' if nothing available.    */
/*--------------------------------------------------------------------*/
::METHOD claimTicket GUARDED
   USE ARG agentName, projCode
   ticket = .FossilHelper~ticketNext(agentName, projCode)
   IF ticket = '' THEN RETURN ''
   PARSE VAR ticket ticketId '|' .
   CALL .FossilHelper~ticketChange STRIP(ticketId), 'status=in-progress'
   RETURN ticket

/*--------------------------------------------------------------------*/
/* Serialised wrappers for all Fossil write operations                 */
/*--------------------------------------------------------------------*/

::METHOD commitWithTag GUARDED
   USE ARG message, tagName
   CALL .FossilHelper~commitWithTag message, tagName
   RETURN

::METHOD commitAll GUARDED
   USE ARG message
   CALL .FossilHelper~commitAll message
   RETURN

::METHOD ticketChange GUARDED
   USE ARG ticketId, fields
   CALL .FossilHelper~ticketChange ticketId, fields
   RETURN

::METHOD ticketClose GUARDED
   USE ARG ticketId
   CALL .FossilHelper~ticketClose ticketId
   RETURN

::METHOD ticketAdd GUARDED
   USE ARG title, fields
   CALL .FossilHelper~ticketAdd title, fields
   RETURN

::METHOD wikiAppend GUARDED
   USE ARG pageName, line
   CALL .FossilHelper~wikiAppend pageName, line
   RETURN

::METHOD wikiCommit GUARDED
   USE ARG pageName, content
   CALL .FossilHelper~wikiCommit pageName, content
   RETURN

/*--------------------------------------------------------------------*/
/* Read operations — also guarded to prevent read-during-write issues  */
/*--------------------------------------------------------------------*/

::METHOD wikiExport GUARDED
   USE ARG pageName
   RETURN .FossilHelper~wikiExport(pageName)

::METHOD ticketField GUARDED
   USE ARG ticketId, fieldName
   RETURN .FossilHelper~ticketField(ticketId, fieldName)

::METHOD allDepsClosed GUARDED
   USE ARG deps
   RETURN .FossilHelper~allDepsClosed(deps)

/*--------------------------------------------------------------------*/
/* Budget operations — read-modify-write must be atomic                */
/*--------------------------------------------------------------------*/

::METHOD recordCost GUARDED
   USE ARG projCode, agentName, ticketId, cost
   IF cost = 0 THEN RETURN

   /* Update ticket cost field */
   existingCost = .FossilHelper~ticketField(ticketId, 'cost_usd')
   IF \DATATYPE(existingCost, 'N') THEN existingCost = 0
   newCost = existingCost + cost
   CALL .FossilHelper~ticketChange ticketId, 'cost_usd='newCost

   /* Update wiki Budget page — read, modify, write back */
   page = .FossilHelper~wikiExport('Budget')
   IF page = '' THEN page = 'cap: 0' || '0a'x || 'spent: 0' || '0a'x

   page = self~updateBudgetLine(page, 'spent:', cost)
   page = self~updateBudgetLine(page, projCode':', cost)

   IF POS(agentName':', page) = 0 THEN
      page = page || agentName':' FORMAT(cost,,4) || '0a'x
   ELSE
      page = self~updateBudgetLine(page, agentName':', cost)

   CALL .FossilHelper~wikiCommit 'Budget', page
   RETURN

/*--------------------------------------------------------------------*/
/* updateBudgetLine — find a "label: N" line and add cost to N         */
/*--------------------------------------------------------------------*/
::METHOD updateBudgetLine PRIVATE
   USE ARG page, marker, addCost
   pos = POS(marker, page)
   IF pos = 0 THEN RETURN page

   before = LEFT(page, pos - 1)
   chunk = SUBSTR(page, pos + LENGTH(marker))
   PARSE VAR chunk oldVal '0a'x afterLine
   oldVal = STRIP(oldVal)
   IF \DATATYPE(oldVal, 'N') THEN oldVal = 0

   newVal = FORMAT(oldVal + addCost,, 4)
   RETURN before || marker || ' ' || newVal || '0a'x || afterLine

/*--------------------------------------------------------------------*/
/* Budget read operations — guarded to prevent read-during-write       */
/*--------------------------------------------------------------------*/

::METHOD readBudgetSpent GUARDED
   page = .FossilHelper~wikiExport('Budget')
   IF page = '' THEN RETURN 0
   spentPos = POS('spent:', page)
   IF spentPos = 0 THEN RETURN 0
   PARSE VAR page . 'spent:' spent .
   IF DATATYPE(STRIP(spent), 'N') THEN RETURN STRIP(spent)
   RETURN 0

::METHOD readProjectSpend GUARDED
   USE ARG projCode
   page = .FossilHelper~wikiExport('Budget')
   marker = projCode || ':'
   pos = POS(marker, page)
   IF pos = 0 THEN RETURN 0
   chunk = SUBSTR(page, pos + LENGTH(marker))
   PARSE VAR chunk spent .
   IF DATATYPE(STRIP(spent), 'N') THEN RETURN STRIP(spent)
   RETURN 0

::METHOD readAgentSpend GUARDED
   USE ARG agentName
   page = .FossilHelper~wikiExport('Budget')
   marker = agentName || ':'
   pos = POS(marker, page)
   IF pos = 0 THEN RETURN 0
   chunk = SUBSTR(page, pos + LENGTH(marker))
   PARSE VAR chunk spent .
   IF DATATYPE(STRIP(spent), 'N') THEN RETURN STRIP(spent)
   RETURN 0
