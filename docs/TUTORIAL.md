# Tutorial: Your First RalphClip Company

This tutorial walks you through setting up a small WordPress plugin development company with three AI agents, a linter, and a test runner. By the end you will have a working orchestration loop that decomposes goals, writes code, runs quality checks, and logs everything to Fossil.

> **Quick-path alternatives:** This tutorial shows the manual step-by-step process so you understand how everything fits together. For faster setup:
> - `bash setup.sh` + `rexx setup-wizard.rex` — interactive wizard, no AI needed
> - `bash setup.sh` + `bash plan.sh` — Claude designs your entire org conversationally
>
> See the [README](../README.md#quick-start) for details.

## Prerequisites

Make sure you have installed:

```bash
# Check each one
fossil version       # Fossil SCM
rexx -v              # ooRexx interpreter
claude --version     # Claude Code CLI (or at least one AI runtime)
```

## Step 1: Create the Company

```bash
mkdir ~/my-plugin-co && cd ~/my-plugin-co
```

Initialise the Fossil repository:

```bash
fossil init company.fossil
mkdir workspace
cd workspace
fossil open ../company.fossil
```

## Step 2: Set Up Custom Ticket Fields

Fossil stores tickets in a SQLite table. RalphClip needs custom columns:

```bash
# Use fossil sql to add custom fields (safe to run if they already exist)
for col in \
    "project TEXT DEFAULT ''" \
    "goal_id TEXT DEFAULT ''" \
    "goal_chain TEXT DEFAULT ''" \
    "assignee TEXT DEFAULT ''" \
    "depends TEXT DEFAULT ''" \
    "cost_usd REAL DEFAULT 0.0" \
    "acceptance TEXT DEFAULT ''" \
    "gate_type TEXT DEFAULT ''"; do
    fossil sql "ALTER TABLE ticket ADD COLUMN $col;" 2>/dev/null || true
done
```

Note: If `fossil sql` is not available on your version, use `sqlite3 ../company.fossil` instead.

## Step 3: Write the Company Configuration

Create `workspace/company.toml`:

```toml
[company]
name = "My Plugin Co"
monthly_budget_usd = 50.00

[projects.myplugin]
client = "Internal"
budget_usd = 50.00
working_dir = "~/projects/my-wp-plugin"
context_wiki = "Projects/MyPlugin/Context"
goals = ["G001"]

[governance]
require_approval = ["deploy", "client-facing"]
auto_approve = ["lint", "test", "metrics"]

[governance.gates.code]
pipeline = ["linter", "test-runner"]
on_fail = "reopen"
```

## Step 4: Define Your Agents

Create a file for each agent in `workspace/agents/`:

**CTO — decomposes goals into stories:**

```toml
# workspace/agents/cto.toml
role = "CTO"
runtime = "claude"
model = "claude-sonnet-4-20250514"
budget_usd = 10.00
skill = "decompose"
projects = ["myplugin"]
```

**Engineer — implements code:**

```toml
# workspace/agents/engineer.toml
role = "PHP Engineer"
runtime = "mistral"
model = "devstral-2"
budget_usd = 25.00
skill = "implement-php"
projects = ["myplugin"]
allowed_paths = ["includes/", "tests/"]
forbidden_paths = ["vendor/", ".git/"]
```

**Linter — runs PHPCS (shell script agent):**

```toml
# workspace/agents/linter.toml
role = "Linter"
runtime = "script"
script = "scripts/run-phpcs.sh"
budget_usd = 0.00
trigger = "after:engineer"
projects = ["myplugin"]
```

**Test Runner — runs PHPUnit (shell script agent):**

```toml
# workspace/agents/test-runner.toml
role = "Test Runner"
runtime = "script"
script = "scripts/run-tests.sh"
budget_usd = 0.00
trigger = "after:linter"
projects = ["myplugin"]
```

## Step 5: Write Skill Prompts

Skill prompts are Markdown files that tell AI agents how to behave. Create `workspace/skills/`:

**Decompose skill (for CTO):**

```markdown
# workspace/skills/decompose.md

You are the CTO of a WordPress plugin development company.

Your job is to read the open epic tickets and decompose each into
implementable stories.

Rules:
- Each story must be small enough to complete in one coding session.
- Each story must have clear acceptance criteria.
- Assign stories to the appropriate agent.
- Include goal_chain tracing back to the top-level goal.

Output each story in this exact format:

## Story: <title>
- assignee: <agent-name>
- goal_chain: <goal ancestry>
- acceptance: <clear criteria>
- points: <1-5>

When all epics are decomposed, output <promise>COMPLETE</promise>.
```

**Implement skill (for Engineer):**

```markdown
# workspace/skills/implement-php.md

You are a senior PHP engineer working on a WordPress plugin.

Rules:
- Follow WordPress coding standards (WordPress-Extra PHPCS ruleset).
- Use OOP with proper namespacing.
- Write PHPUnit tests for any logic-bearing class.
- Run existing tests before marking complete.
- Commit your work with a descriptive message.

When the task is fully implemented and tests pass,
output <promise>COMPLETE</promise>.
```

## Step 6: Create Script Agents

**Linter script:**

```bash
#!/bin/bash
# workspace/scripts/run-phpcs.sh
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"

echo "Running PHPCS..."
if vendor/bin/phpcs --standard=WordPress-Extra --extensions=php \
   --ignore=vendor/,node_modules/ . ; then
  echo "PHPCS clean."
  echo "<promise>COMPLETE</promise>"
else
  echo "## Issue: PHPCS violations found"
  echo "- assignee: engineer"
  echo "- severity: medium"
fi
```

**Test runner script:**

```bash
#!/bin/bash
# workspace/scripts/run-tests.sh
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"

echo "Running PHPUnit..."
if vendor/bin/phpunit; then
  echo "All tests pass."
  echo "<promise>COMPLETE</promise>"
else
  echo "## Issue: Test failures"
  echo "- assignee: engineer"
  echo "- severity: high"
fi
```

Make them executable:

```bash
chmod +x workspace/scripts/*.sh
```

## Step 7: Seed the Wiki

Create project context and initial wiki pages:

```bash
# Project context
echo "Stack: PHP 8.1+, WordPress 6.4+
Architecture: OOP, namespace MyPluginCo
Tests: PHPUnit via composer" | fossil wiki commit "Projects/MyPlugin/Context"

# Budget page
echo "cap: 50.00
spent: 0.00" | fossil wiki commit "Budget"

# Empty governance log
echo "# Governance Log" | fossil wiki commit "GovernanceLog"

# Empty agent learnings
echo "No learnings yet." | fossil wiki commit "AgentLearnings/cto"
echo "No learnings yet." | fossil wiki commit "AgentLearnings/engineer"
```

## Step 8: Create Your First Goal and Epic

```bash
# Write the goal
cat << 'EOF' | fossil wiki commit "Goals/G001"
# G001: Build MyPlugin v1.0

A WordPress plugin that adds a custom post type for client
testimonials with a Gutenberg block for display.

Success criteria:
- Custom post type registered with proper labels
- REST API endpoints for CRUD
- Gutenberg block renders testimonials in a grid
- Passes PHPCS and PHPUnit
EOF

# Create the first epic ticket
fossil ticket add \
  type=epic \
  title="Testimonials custom post type and REST API" \
  goal_id=G001 \
  assignee=cto \
  project=myplugin \
  status=open
```

## Step 9: Set Up the Working Directory

The actual code lives in a separate git repo:

```bash
mkdir -p ~/projects/my-wp-plugin
cd ~/projects/my-wp-plugin
git init
composer init --name="mypluginco/my-wp-plugin" --type=wordpress-plugin
composer require --dev phpunit/phpunit squizlabs/php_codesniffer
composer require --dev wp-coding-standards/wpcs
vendor/bin/phpcs --config-set installed_paths vendor/wp-coding-standards/wpcs
```

## Step 10: Run the Orchestrator

```bash
cd ~/my-plugin-co/workspace
rexx /path/to/ralphclip/orchestrate.rex
```

Watch the output:

```
[BUDGET] $0.00 / $50.00 — OK
==== myplugin ====
[cto] Decomposing epic: "Testimonials custom post type and REST API"
[cto] Iteration 1 of 5
[cto] Created ticket: Register testimonials CPT → engineer
[cto] Created ticket: REST API endpoints for testimonials → engineer
[cto] Created ticket: Gutenberg block for testimonial grid → engineer
[cto] Task complete on iteration 1 ($0.04)
[engineer] Working on: Register testimonials CPT
[engineer] Iteration 1 of 5
[engineer] Task complete on iteration 2 ($0.06)
[linter] Running scripts/run-phpcs.sh
[linter] PHPCS clean.
[test-runner] Running scripts/run-tests.sh
[test-runner] All tests pass.
[engineer] Ticket closed: Register testimonials CPT
```

## Step 11: Check the Dashboard

```bash
fossil ui
```

Your browser opens to a page showing:

- **Timeline** — commits and ticket changes interleaved
- **Tickets** — your task board with status filters
- **Wiki** — org chart, budget, governance log, agent learnings
- **Files** — your config and scripts, versioned

## Next Steps

- **Add a project:** `rexx /path/to/ralphclip/add-project.rex` — interactive, appends to existing config
- **Add an agent:** `rexx /path/to/ralphclip/add-agent.rex` — interactive, with skill browser and runtime detection
- Browse the [Skills Library](../skills/README.md) — 26 reusable skills across marketing, WordPress, Vue/PWA, and general development
- Write ooRexx agents for custom analysis — see [Creating ooRexx Agents](CREATING-AGENTS.md)
- Set up a cron job: `0 6 * * 1-5 cd ~/my-plugin-co/workspace && rexx /path/to/ralphclip/orchestrate.rex >> /var/log/ralphclip.log 2>&1`
- Access remotely via Tailscale: `fossil ui --port 8080` on your server, browse from phone
