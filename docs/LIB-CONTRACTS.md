# RalphClip Library Contracts

This document specifies the public API, return types, and failure modes for
each module in `lib/`. Any agent or contributor modifying these libraries must
preserve these contracts.

---

## lib/toml.rex — TomlParser

Minimal TOML parser. Supports tables, key-value pairs, inline arrays, and
dotted key access. Does **not** support: inline tables, multi-line strings,
datetime types, or nested inline arrays.

### Public Methods

| Method | Signature | Returns | Failure Mode |
|--------|-----------|---------|-------------|
| `parse` | `::method parse(filePath)` | `.Directory` — nested key→value map | Returns empty `.Directory` if file not found. **Does not raise a condition.** Caller must check for expected keys. |
| `get` | `::method get(config, dottedKey, default)` | `String` — the value, or `default` if key absent | Never fails. Returns `default` on missing key. |
| `sections` | `::method sections(config, prefix)` | `.Array` of section key strings matching `prefix.*` | Returns empty `.Array` if no matches. |

### Failure Modes

- **File not found:** Silent — returns empty directory. The orchestrator must
  check for the presence of `company.name` or similar sentinel key.
- **Malformed TOML:** Lines that don't parse are silently skipped. No error
  is raised. This is the biggest risk surface — a typo in a budget field
  means it reads as the default (usually 0), which can silently disable
  budget enforcement.
- **Encoding:** Assumes UTF-8. Non-UTF-8 bytes produce undefined parse results.

### Hardening Recommendations

- Add a `parseStrict` method that raises `SYNTAX` on unparseable lines.
- Add a `getRequired` method that raises `USER` condition on missing keys.

---

## lib/fossil.rex — FossilHelper

Wraps Fossil CLI commands. All methods use `ADDRESS SYSTEM` to shell out.

### Public Methods

| Method | Signature | Returns | Failure Mode |
|--------|-----------|---------|-------------|
| `preflight` | `::method preflight()` | `1` (ok) or `0` (fail) | Checks `fossil version` exits 0. Returns 0 if fossil not on PATH. |
| `isoTimestamp` | `::method isoTimestamp()` | `String` — `YYYY-MM-DD HH:MM:SS` | Never fails. |
| `isoTimestampCompact` | `::method isoTimestampCompact()` | `String` — `YYYYMMDD-HHMMSS` | Never fails. |
| `wikiExport` | `::method wikiExport(pageName)` | `String` — wiki page content, or `''` if page doesn't exist | Silent empty return on missing page. RC from `fossil wiki export` is not checked. |
| `wikiAppend` | `::method wikiAppend(pageName, entry)` | void | Appends to wiki page. Creates page if absent. **Failure is silent** — if Fossil is locked or repo is corrupt, the append is lost with no error. |
| `ticketPeek` | `::method ticketPeek(assignee, project)` | `String` — pipe-delimited ticket fields, or `''` if none | Returns empty string if no matching tickets. |
| `ticketField` | `::method ticketField(ticketId, fieldName)` | `String` — field value | Returns `''` if ticket or field not found. |
| `ticketClose` | `::method ticketClose(ticketId)` | void | Silent failure if ticket doesn't exist. |
| `ticketChange` | `::method ticketChange(ticketId, changes)` | void | Silent failure. |
| `commitAll` | `::method commitAll(message)` | void | Runs `fossil addremove` then `fossil commit`. **If the repo is locked by another process, the commit fails silently.** |
| `commitWithTag` | `::method commitWithTag(message, tag)` | void | Same as `commitAll` plus `fossil tag add`. |

### Failure Modes

- **Fossil not in PATH:** Caught by `preflight()`. All other methods will
  fail with RC != 0 from ADDRESS SYSTEM, but this RC is not checked.
- **Repository locked:** Fossil uses file-level locking. Concurrent `fossil commit`
  calls from parallel workers will fail. The mutex (lib/mutex.rex) is intended
  to serialise these, but relies on its own correctness.
- **Corrupt repository:** All operations fail silently. No detection mechanism.

### Hardening Recommendations

- Check `RC` after every `ADDRESS SYSTEM` call and raise on non-zero.
- Add a `commitSafe` method that retries with backoff on lock contention.

---

## lib/mutex.rex — FossilMutex

Serialises access to Fossil operations (ticket claims, budget reads, commits)
across parallel workers within a single orchestrator run.

### Public Methods

| Method | Signature | Returns | Failure Mode |
|--------|-----------|---------|-------------|
| `claimTicket` | `::method claimTicket(agentName, projCode)` | `String` — pipe-delimited ticket, or `''` | Returns `''` if no eligible ticket. Uses `fossil ticket change` to atomically set status to `in-progress`. |
| `readBudgetSpent` | `::method readBudgetSpent()` | `Number` — total company spend | Reads from wiki or ticket aggregation. Returns 0 if unreadable. |
| `readProjectSpend` | `::method readProjectSpend(projCode)` | `Number` | Same as above, scoped to project. |
| `readAgentSpend` | `::method readAgentSpend(agentName)` | `Number` | Same as above, scoped to agent. |
| `allDepsClosed` | `::method allDepsClosed(deps)` | `1` or `0` | Checks each dep ticket's status. Returns 0 if any dep is not `closed`. |
| `ticketChange` | `::method ticketChange(ticketId, changes)` | void | Delegates to FossilHelper. |
| `ticketClose` | `::method ticketClose(ticketId)` | void | Delegates to FossilHelper. |

### Failure Modes

- **Race conditions:** The claim-ticket pattern (read list → pick first → change status)
  is not truly atomic. Two parallel workers could both read the same ticket
  before either claims it. In practice this is mitigated by wave scheduling
  (agents within a wave have different assignments), but it's not guaranteed.
- **Budget reads returning 0:** If the wiki page or aggregation query fails,
  spend reads as 0, which means budget gates are open. This is a **fail-open**
  design — the opposite of what you want for cost control.

### Hardening Recommendations

- Use a lockfile (`flock`) around ticket claims for true atomicity.
- Make budget reads **fail-closed**: if the spend can't be determined, halt.

---

## lib/trace.rex — TraceWriter

OpenTelemetry-inspired tracing. Writes JSONL span records to `traces/`.

### Public Methods

| Method | Signature | Returns |
|--------|-----------|---------|
| `new` | `::method init(runId, dir, costTable, version)` | instance |
| `start` | `::method start()` | void — writes root span |
| `span` | `::method span(name, parent, timestamp, duration, inputTokens, outputTokens, status, error, tags, description)` | void |
| `countTask` | `::method countTask(outcome)` | void — increments counter |
| `finish` | `::method finish()` | void — writes summary span, closes file |
| `buildCostTable` | `::method buildCostTable(config)` | `.Directory` — runtime→cost-per-call map |

### Failure Modes

- **File I/O:** Silent failure if traces directory doesn't exist or is not writable.
- **Cost table:** Returns 0 for unknown runtimes. Cost tracking will undercount.

---

## lib/handoff.rex — HandoffWriter / HandoffReader

Markdown-based inter-agent context passing.

### HandoffWriter

| Method | Signature | Returns |
|--------|-----------|---------|
| `write` | `::method write(sourceTask, targetTask, adapter, fossilRef, runId, outputFiles, recordCount, confidence, summary, schema, validationRules, onFailure, directory)` | `String` — file path of written handoff |

### HandoffReader

| Method | Signature | Returns |
|--------|-----------|---------|
| `parse` | `::method parse(filePath)` | `.Directory` — keys: source_task, target_task, adapter, fossil_ref, run_id, output_files, record_count, confidence, summary, schema, validation_rules, on_failure |
| `validate` | `::method validate(ho)` | `.Directory` — keys: ok (1/0), errors (.Array) |

### Failure Modes

- **Missing fields:** `parse` returns `''` for any field not found in the file.
  `validate` checks for required fields and populates the errors array.
- **Title-based matching:** The orchestrator matches handoffs to dependencies
  using `POS(sourceTask, upstreamTasks)` which is substring-based and fragile.
  **Fix 2 in this hardening set replaces this with ticket-ID-based matching.**

---

## lib/parked.rex — ParkedWriter

Writes parked-task Markdown documents for failed tasks.

| Method | Signature | Returns |
|--------|-----------|---------|
| `write` | `::method write(taskName, attempts, finalAdapter, errorClass, errorMessage, attemptLog, taskConfig, lastOutput, directory)` | `String` — file path |

### Failure Modes

- Silent file I/O failure. No return code check.

---

## lib/escalation.rex — EscalationWriter / EscalationReader

### EscalationWriter

| Method | Signature | Returns |
|--------|-----------|---------|
| `write` | `::method write(taskName, ticketId, agentName, projCode, attempts, attemptLog, lastResult, prompt, runId, reason, directory)` | `String` — file path |

### EscalationReader

| Method | Signature | Returns |
|--------|-----------|---------|
| `scanPending` | `::method scanPending(directory)` | `.Array` of `.Directory` — each with keys: action, task, ticket_id, ... |
| `applyResponse` | `::method applyResponse(resp)` | void — changes ticket status per human response |

### Failure Modes

- `scanPending` returns empty array if directory doesn't exist or has no `.md` files.
- `applyResponse` delegates to FossilHelper and inherits its silent-failure behaviour.

---

## lib/worker.rex — TaskWorker

Wraps a single agent dispatch with retry logic.

| Method | Signature | Returns |
|--------|-----------|---------|
| `new` | `::method init(taskSpec, mutex, tracer, runId)` | instance |
| `start` | `::method start(methodName)` | `.Message` — ooRexx async message. Call `~result` to block. |
| `execute` | `::method execute()` | `.Directory` — keys: completed (1/0), lastResult (.Directory or .nil), attemptLog (.Array), taskSafeName, adapterUsed, totalCost |

### Failure Modes

- **Worker crash:** If the adapter throws an unhandled condition, `execute`
  returns `.nil` for `lastResult`. The orchestrator checks for this case
  (the "nil result" branch in wave commit).
- **Infinite retry:** Bounded by `taskMaxRetries` from agent config.
- **Cost tracking:** Cost is accumulated per-attempt. If an attempt crashes
  before reporting cost, that attempt's cost is lost (undercounted).

---

## lib/scheduler.rex — WaveScheduler

Dependency-aware wave builder.

| Method | Signature | Returns |
|--------|-----------|---------|
| `new` | `::method init()` | instance |
| `addCandidate` | `::method addCandidate(candidate)` | void |
| `buildWaves` | `::method buildWaves(completedAgents)` | `.Array` of `.Array` of candidates |
| `describeWaves` | `::method describeWaves(waves)` | void — prints wave plan to stdout |

### Failure Modes

- **Circular dependencies:** Not detected. Will result in agents never being
  scheduled (their deps never appear in `completedAgents`). The run completes
  with those agents simply skipped — no error is raised.
- **Empty waves:** Possible if all candidates have unmet deps. Results in idle run.

### Hardening Recommendations

- Add cycle detection in `buildWaves` and raise an error with the cycle path.
