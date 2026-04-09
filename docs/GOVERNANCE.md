# Governance Model

RalphClip governance is built from existing primitives: Fossil ticket status fields, wiki pages, TOML config, git revert, and ooRexx logic. No RBAC frameworks, no approval UIs, no additional dependencies.

## Seven Layers

### Layer 1: Budget Hard Stops

Three levels checked before every dispatch:

```
Company cap  →  Project cap  →  Agent cap
```

If any level is exhausted, work stops at that scope. Other projects and agents continue unaffected. Every budget check is logged to the GovernanceLog wiki page.

### Layer 2: Approval Gates

Tickets tagged with certain types require human approval before execution. The ticket status is set to `awaiting-approval` and the orchestrator skips it. You approve by changing the status back to `open` via `fossil ui` or `fossil ticket change <id> status=open`.

Configure in `company.toml`:

```toml
[governance]
require_approval = ["deploy", "client-facing", "delete"]
auto_approve = ["lint", "test", "metrics"]
```

### Layer 3: Audit Trail

The GovernanceLog wiki page accumulates a timestamped record of every significant action. Because it is a Fossil wiki page, every edit is versioned. The log is append-only from the orchestrator's perspective — agents cannot rewrite history.

### Layer 4: Scope Control

Agents are restricted to specific file paths via their TOML config. Violations are detected by the scope auditor agent (an ooRexx agent) and automatically reverted via `git revert`.

### Layer 5: Quality Gates

Configurable pipelines of script and ooRexx agents that must pass before a ticket can close. Failures reopen the ticket with a fix ticket attached.

### Layer 6: Rollback

Code: `git revert` in the working directory. State: `fossil undo` for ticket and wiki changes. Automated rollback is triggered by scope violations and test regressions.

### Layer 7: Escalation

After N consecutive failures, the agent is suspended and a notification file is written for external alerting (cron job to email, Pushover, etc.).

Configure thresholds in `company.toml`:

```toml
[governance.escalation]
max_consecutive_failures = 3
notification_file = "/tmp/ralphclip-escalation.txt"
```
