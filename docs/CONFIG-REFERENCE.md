# Configuration Reference

All configuration is in TOML format. The company-level config is `workspace/company.toml`. Per-agent configs are in `workspace/agents/<n>.toml`.

## company.toml

```toml
[company]
name = "Company Name"                # display name
monthly_budget_usd = 150.00          # hard ceiling for all spending
ralphclip_home = "/path/to/ralphclip" # where orchestrate.rex lives

# --- Projects ---

[projects.<code>]
client = "Client Name"               # for invoicing
budget_usd = 60.00                   # per-project monthly cap
working_dir = "~/projects/myproject" # git repo for this project
context_wiki = "Projects/<Code>/Context"  # Fossil wiki page with domain context
goals = ["G001", "G002"]             # top-level goal IDs

# --- Governance ---

[governance]
require_approval = ["deploy", "client-facing", "delete"]
auto_approve = ["lint", "test", "metrics"]

[governance.gates.code]
pipeline = ["linter", "test-runner", "scope-auditor"]
on_fail = "reopen"                   # reopen | park

[governance.gates.content]
pipeline = ["word-counter", "link-checker"]
on_fail = "reopen"

[governance.gates.deploy]
pipeline = ["all-tests-pass", "human-approval"]
on_fail = "park"

[governance.escalation]
max_consecutive_failures = 3
notification_file = "/tmp/ralphclip-escalation.txt"

# --- Cost Accounting ---
# Rates per million tokens. Used by the tracer for cost estimates.
# Override defaults here if pricing changes.

[cost_per_million_tokens.claude-code]
input = 3.00
output = 15.00

[cost_per_million_tokens.gemini-cli]
input = 0.50
output = 1.50

[cost_per_million_tokens.mistral-vibe]
input = 0.25
output = 0.75

[cost_per_million_tokens.trinity-mini]
input = 0.045
output = 0.15

[cost_per_million_tokens.trinity-large]
input = 0.50
output = 0.90

# bash, oorexx, mcp-bridge default to 0.00/0.00

# --- Orchestrator Settings ---

[orchestrator]
max_iterations = 5                   # Ralph loop iterations per ticket
log_dir = "runs"                     # run log directory (unversioned)
```

## CLI Flags

```bash
rexx orchestrate.rex [company.toml] [--dry-run] [--preflight]
```

| Flag | Description |
|------|-------------|
| `--preflight` | Verify all agent runtimes (binary availability), API keys, script paths, and working directories. Exits with error count as return code. Run this after setup or config changes. |
| `--dry-run` | Run full candidate discovery, wave scheduling, prompt building, and budget checks. Prints the dispatch plan without executing adapters or spending money. Claimed tickets are released back to open. |

## agents/<n>.toml

```toml
# --- Identity ---
role = "Senior PHP Engineer"         # human-readable role description

# --- Runtime ---
runtime = "mistral"                  # claude | mistral | gemini | trinity | script | rexx | bash | oorexx | mcp-bridge
model = "devstral-2"                 # model identifier (ignored for script/rexx)
script = "scripts/run-phpcs.sh"      # path to script (script/rexx runtimes only)

# --- Budget ---
budget_usd = 40.00                   # per-agent monthly cap (0.00 for scripts)

# --- Work Assignment ---
skill = "implement-php"              # skill prompt file: skills/<skill>.md
projects = ["myplugin", "otherplugin"]  # which projects this agent works on

# --- Scope Control ---
allowed_paths = ["includes/", "tests/"]
forbidden_paths = ["vendor/", ".git/", "config/production.php"]

# --- Permissions ---
skip_permissions = false             # if true, passes --dangerously-skip-permissions to Claude Code
                                     # only enable for trusted high-privilege agents

# --- Trigger ---
trigger = "ticket"                   # ticket (default) | after:<agent> | always | manual | cron:<expr>
                                     # cron supports: *, ranges (1-5), lists (1,3,5), steps (*/5, 1-10/2)

# --- Error Recovery & Retry (v2) ---
fallback_adapters = ["gemini-cli", "mistral-vibe"]  # ordered adapter cascade on failure
max_retries = 3                      # total attempts (primary + fallbacks)
backoff = "exponential"              # fixed | linear | exponential
backoff_base_seconds = 5             # base wait time between retries
retry_on = ["timeout", "adapter_error", "malformed_output"]  # error types to retry (omit = all non-fatal)
fail_action = "park"                 # park | escalate | skip — action after all retries exhausted

# --- Legacy Fallback (v1 compat) ---
# These are still supported but superseded by fallback_adapters/max_retries.
# If fallback_adapters is empty, fallback_runtime is used as a single-entry list.
fallback_runtime = "gemini"          # optional: try this runtime if primary fails
fallback_model = "gemini-3-flash"    # model for fallback runtime

# --- Context ---
context = """
Optional multi-line context string injected into every prompt.
Use for domain-specific instructions that apply to all tasks.
"""
```

### Retry Defaults (backward compatible)

If retry fields are omitted, the orchestrator uses these defaults:

| Field | Default | Notes |
|-------|---------|-------|
| `max_retries` | 1 | Single attempt, no retry |
| `backoff` | "fixed" | No escalating wait |
| `backoff_base_seconds` | 0 | No wait between retries |
| `retry_on` | (all non-fatal) | Retries on transient and semantic errors |
| `fail_action` | "park" | Write to parked_tasks/ on final failure |
| `fallback_adapters` | (empty) | Uses only primary adapter |

### Error Classification

Every adapter classifies errors into one of three classes:

| Class | Meaning | Orchestrator Action |
|-------|---------|-------------------|
| `transient` | Timeout, rate limit, 502/503, connection reset | Retry with backoff |
| `semantic` | Empty/malformed output, schema violation | Retry with error context appended to prompt |
| `fatal` | Auth failure (401/403), missing command, permission denied | Park immediately, do not retry |

### Fail Actions

| Action | Behaviour |
|--------|-----------|
| `park` | Write full error context to `parked_tasks/<name>_<timestamp>.md`, set Fossil tag `parked:<name>` |
| `escalate` | Change ticket status to `escalated`, log to governance, notify via escalation file |
| `skip` | Log the failure and continue processing the task queue |

## Adapter Config: MCP Bridge (Stub)

The MCP bridge is a seventh adapter type for future Model Context Protocol integration.

```toml
runtime = "mcp-bridge"
model = ""                           # MCP server name or identifier
```

Current behaviour: logs the would-be MCP JSON-RPC `tools/call` request to `debug/mcp_dry_run/` and returns a fatal error. When a real MCP server URL is configured, this adapter will send actual requests.

## Supported Runtimes

| Value | Binary/Method | Headless Flag | Cost Tracking | Aliases |
|-------|---------------|---------------|---------------|---------|
| `claude` | `claude` | `-p --model <m>` | Parsed from output | `claude-code` |
| `mistral` | `vibe` | `--prompt <p> --max-price <$>` | Parsed from output | `mistral-vibe` |
| `trinity` | OpenRouter API via `curl` | N/A (API call) | Parsed from API response | |
| `gemini` | `gemini` | `-p --output-format json` | Estimated from tokens | `gemini-cli` |
| `script` | `bash` | N/A | Always $0.00 | `bash` |
| `rexx` | `rexx` | N/A | Always $0.00 | `oorexx` |
| `mcp-bridge` | (stub) | N/A | $0.00 | |

### Adapter Result Object

Every adapter returns a Directory with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `ok` | boolean | `.true` if execution succeeded |
| `error_class` | string/nil | `"transient"`, `"semantic"`, `"fatal"`, or `.nil` on success |
| `error_message` | string | Human-readable error description |
| `output` | string | Text output from the agent |
| `duration_ms` | integer | Wall-clock execution time in milliseconds |
| `token_in` | integer | Input token count (0 for non-AI) |
| `token_out` | integer | Output token count (0 for non-AI) |
| `complete` | boolean | `1` if `<promise>COMPLETE</promise>` found in output |
| `cost` | number | Estimated cost in USD (legacy compatibility field) |
| `success` | boolean | `1` if ok (legacy compatibility field) |

### Trinity Models

| Model String | Size | API Pricing (input/output per M) | Best For |
|-------------|------|----------------------------------|----------|
| `trinity-mini` | 26B | $0.045 / $0.15 | QA, bulk content, structured output |
| `trinity-large-thinking` | 400B (13B active) | ~$0.50 / $0.90 | Reasoning, decomposition, long-horizon agents |

Trinity requires `OPENROUTER_API_KEY` environment variable set.
Weights also available on Hugging Face for self-hosting (Apache 2.0).

## Trigger Types

| Trigger | Meaning |
|---------|---------|
| `ticket` | Run when there are open tickets assigned to this agent (default) |
| `after:<agent>` | Run after the named agent completes a ticket this cycle |
| `always` | Run every orchestrator cycle regardless of tickets |
| `manual` | Never run automatically; only when human changes ticket status |
| `cron:<expr>` | Run when the 5-field cron expression matches current time |

### Cron Expression Format

Standard 5-field: `minute hour day-of-month month day-of-week`

Supports: `*` (any), exact numbers, comma lists (`1,3,5`), ranges (`1-5`).

Examples:
- `cron:0 6 * * 1-5` — weekday mornings at 6:00 AM
- `cron:0 8 * * 5` — Friday mornings at 8:00 AM
- `cron:30 * * * *` — every hour at :30
- `cron:0 0 1 * *` — midnight on the 1st of each month

Day-of-week: 0=Sunday, 1=Monday, ..., 6=Saturday.

## Dependency Format

The `depends` field on tickets supports two formats:

- **Literal ticket IDs:** comma-separated Fossil ticket UUIDs (or prefixes).
  Example: `depends: abc123,def456`
- **Symbolic references:** `story:Title Of Story` resolved after creation.
  Example: `depends: story:Register CPT, story:Create REST API`

Symbolic references are resolved by the orchestrator when the CTO
creates stories from an epic decomposition. They match against
story titles created in the same batch (case-insensitive).

## Fossil Custom Ticket Fields

RalphClip adds these columns to Fossil's ticket table during setup (via SQL).
They are created automatically by `setup.sh` or can be added manually:

```bash
fossil sql "ALTER TABLE ticket ADD COLUMN <n> <type> DEFAULT <default>;"
```

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `project` | TEXT | '' | Project code from company.toml |
| `goal_id` | TEXT | '' | Top-level goal reference |
| `goal_chain` | TEXT | '' | Full goal ancestry string |
| `assignee` | TEXT | '' | Agent name |
| `depends` | TEXT | '' | Comma-separated ticket IDs or `story:Title` symbolic refs |
| `cost_usd` | REAL | 0.0 | Accumulated cost |
| `acceptance` | TEXT | '' | Acceptance criteria |
| `gate_type` | TEXT | '' | Quality gate pipeline name |

## Fossil Commit Message Convention

All orchestrator commits follow this pattern for searchable `fossil timeline`:

```
[<event_type>] task:<task_name> adapter:<adapter> run:<run_id> [optional detail]
```

Event types: `attempt`, `success`, `parked`, `skipped`, `handoff`, `trace`.

Examples:
```
[attempt] task:extract_wire_data attempt:1 adapter:claude-code run:run-20260409T142300Z
[success] task:extract_wire_data adapter:gemini-cli run:run-20260409T142300Z
[parked]  task:validate_schema reason:fatal:auth_failure run:run-20260409T142300Z
[handoff] task:extract_wire_data run:run-20260409T142300Z
[trace]   run:run-20260409T142300Z tasks:4/5 cost:$0.032
```

## Directory Structure (v2)

After setup, the workspace includes these directories:

```
workspace/
├── company.fossil          # The entire company state
├── workspace/
│   ├── company.toml        # Configuration
│   ├── agents/             # Per-agent TOML configs
│   ├── skills/             # Skill prompt templates (.md)
│   ├── scripts/            # Shell/ooRexx scripts
│   ├── runs/               # Per-run log files
│   ├── traces/             # Per-run trace files (.md)       ← NEW
│   ├── parked_tasks/       # Failed tasks for human review   ← NEW
│   ├── escalations/        # Human-in-the-loop escalation docs ← NEW
│   ├── handoffs/           # Inter-agent handoff documents   ← NEW
│   └── debug/
│       └── mcp_dry_run/    # MCP bridge dry-run output       ← NEW
```
