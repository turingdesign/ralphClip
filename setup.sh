#!/bin/bash
#---------------------------------------------------------------------
# setup.sh — Bootstrap a new RalphClip company
#
# Usage: bash /path/to/ralphclip/setup.sh
# Run this from the directory where you want your company to live.
#---------------------------------------------------------------------

set -euo pipefail

RALPHCLIP_HOME="$(cd "$(dirname "$0")" && pwd)"
COMPANY_DIR="$(pwd)"

echo "================================================================"
echo " RalphClip — Company Setup"
echo "================================================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v fossil &> /dev/null; then
    echo "ERROR: fossil not found. Install from https://fossil-scm.org/"
    exit 1
fi
echo "  fossil: $(fossil version | head -1)"

if ! command -v rexx &> /dev/null; then
    echo "ERROR: rexx (ooRexx) not found. Install from https://www.oorexx.org/"
    exit 1
fi
echo "  rexx: OK"

# Check for at least one AI runtime
AI_FOUND=0
for cmd in claude vibe gemini; do
    if command -v "$cmd" &> /dev/null; then
        echo "  $cmd: found"
        AI_FOUND=1
    fi
done
# Trinity uses OpenRouter API — no binary needed
if [ -n "$OPENROUTER_API_KEY" ]; then
    echo "  trinity (OpenRouter): key set"
    AI_FOUND=1
fi
if [ "$AI_FOUND" -eq 0 ]; then
    echo "WARNING: No AI runtimes found. Script and rexx agents will work,"
    echo "         but you need at least one AI CLI for full orchestration."
fi

echo ""

# Gather company info
read -p "Company name: " COMPANY_NAME
read -p "Monthly budget (USD): " BUDGET
read -p "First project code (e.g., myplugin): " PROJECT_CODE
read -p "First project working directory: " PROJECT_DIR
read -p "First project goal (one sentence): " PROJECT_GOAL

echo ""
echo "Setting up: $COMPANY_NAME"
echo "  Project: $PROJECT_CODE → $PROJECT_DIR"
echo "  Budget: \$$BUDGET/month"
echo ""

# Initialise Fossil repository
echo "Initialising Fossil repository..."
fossil init company.fossil
mkdir -p workspace
cd workspace
fossil open ../company.fossil

# Add custom ticket fields
# Fossil manages ticket fields through its TICKET table schema.
# We add columns directly via SQL. Fossil will then recognise them
# when tickets are created with fossil ticket add field=value.
echo "Configuring custom ticket fields..."

# Try fossil sql first, fall back to sqlite3 on the repo file
FOSSIL_SQL="fossil sql"
$FOSSIL_SQL "SELECT 1;" >/dev/null 2>&1 || FOSSIL_SQL="sqlite3 ../company.fossil"

for col in \
    "project TEXT DEFAULT ''" \
    "goal_id TEXT DEFAULT ''" \
    "goal_chain TEXT DEFAULT ''" \
    "assignee TEXT DEFAULT ''" \
    "depends TEXT DEFAULT ''" \
    "cost_usd REAL DEFAULT 0.0" \
    "acceptance TEXT DEFAULT ''" \
    "gate_type TEXT DEFAULT ''"; do
    colname=$(echo "$col" | awk '{print $1}')
    $FOSSIL_SQL "ALTER TABLE ticket ADD COLUMN $col;" 2>/dev/null && \
        echo "  Added field: $colname" || \
        echo "  Field exists: $colname"
done
echo ""

# Create directory structure
echo "Creating directory structure..."
mkdir -p agents skills scripts runs

# Write company.toml
echo "Writing company.toml..."
cat > company.toml << EOF
[company]
name = "$COMPANY_NAME"
monthly_budget_usd = $BUDGET
ralphclip_home = "$RALPHCLIP_HOME"

[projects.$PROJECT_CODE]
client = "Internal"
budget_usd = $BUDGET
working_dir = "$PROJECT_DIR"
context_wiki = "Projects/${PROJECT_CODE}/Context"
goals = ["G001"]

[governance]
require_approval = ["deploy", "client-facing"]
auto_approve = ["lint", "test", "metrics"]

[governance.gates.code]
pipeline = ["linter", "test-runner"]
on_fail = "reopen"

[governance.escalation]
max_consecutive_failures = 3
notification_file = "/tmp/ralphclip-escalation.txt"

[orchestrator]
max_iterations = 5
log_dir = "runs"
EOF

# Write default agent configs
echo "Writing agent configs..."

cat > agents/cto.toml << 'EOF'
role = "CTO"
runtime = "claude"
model = "claude-sonnet-4-20250514"
budget_usd = 10.00
skill = "decompose"
trigger = "ticket"
EOF

cat > agents/linter.toml << 'EOF'
role = "Linter"
runtime = "script"
script = "scripts/run-lint.sh"
budget_usd = 0.00
trigger = "after:engineer"
EOF

cat > agents/test-runner.toml << 'EOF'
role = "Test Runner"
runtime = "script"
script = "scripts/run-tests.sh"
budget_usd = 0.00
trigger = "after:linter"
EOF

# Append project assignment to all agents
for f in agents/*.toml; do
    echo "projects = [\"$PROJECT_CODE\"]" >> "$f"
done

# Write default skill prompts
echo "Writing skill prompts..."

cat > skills/decompose.md << 'SKILL'
You are the CTO of a software development company.

Read the open epic tickets and decompose each into implementable stories.

Rules:
- Each story must be small enough to complete in a single coding session.
- Each story must have clear acceptance criteria.
- Assign each story to the appropriate agent by name.
- Include goal_chain showing the path from top-level goal to this story.

Output each story in this exact Markdown format:

## Story: <title>
- assignee: <agent-name>
- goal_chain: <goal ancestry>
- acceptance: <clear pass/fail criteria>
- points: <1-5 complexity estimate>

When all epics are fully decomposed, output <promise>COMPLETE</promise>.
SKILL

# Write default scripts
echo "Writing default scripts..."

cat > scripts/run-lint.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"
echo "Linter placeholder — replace with your lint command."
echo "Example: vendor/bin/phpcs --standard=WordPress-Extra ."
echo "<promise>COMPLETE</promise>"
SCRIPT

cat > scripts/run-tests.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"
echo "Test runner placeholder — replace with your test command."
echo "Example: vendor/bin/phpunit"
echo "<promise>COMPLETE</promise>"
SCRIPT

chmod +x scripts/*.sh

# Seed wiki pages
echo "Seeding wiki pages..."

echo "cap: $BUDGET
spent: 0.00

# Per-project spend
$PROJECT_CODE: 0.00" | fossil wiki commit "Budget"

echo "# Governance Log" | fossil wiki commit "GovernanceLog"

echo "# $COMPANY_NAME — Org Chart

Board (Human Operator)
  └── CTO" | fossil wiki commit "OrgChart"

echo "No learnings yet." | fossil wiki commit "AgentLearnings/cto"

echo "Project: $PROJECT_CODE
Goal: $PROJECT_GOAL" | fossil wiki commit "Projects/${PROJECT_CODE}/Context"

echo "# G001

$PROJECT_GOAL" | fossil wiki commit "Goals/G001"

# Create the first epic
echo "Creating first epic ticket..."
fossil ticket add \
    type=epic \
    title="$PROJECT_GOAL" \
    goal_id=G001 \
    assignee=cto \
    project="$PROJECT_CODE" \
    status=open 2>/dev/null || echo "(ticket creation — check fossil ui)"

# Commit initial state
fossil addremove 2>/dev/null || true
fossil commit -m "RalphClip company initialised: $COMPANY_NAME" 2>/dev/null || true

# Copy agent context files to working directory
echo "Setting up agent context files in working directory..."
if [ -d "$PROJECT_DIR" ]; then
    cp "$RALPHCLIP_HOME/templates/AGENTS.md" "$PROJECT_DIR/AGENTS.md" 2>/dev/null || true
    cp "$RALPHCLIP_HOME/templates/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
    cp "$RALPHCLIP_HOME/templates/GEMINI.md" "$PROJECT_DIR/GEMINI.md" 2>/dev/null || true
    echo "  Copied AGENTS.md, CLAUDE.md, GEMINI.md to $PROJECT_DIR"
else
    echo "  Working directory $PROJECT_DIR does not exist yet."
    echo "  Copy templates manually after creating it:"
    echo "    cp $RALPHCLIP_HOME/templates/*.md $PROJECT_DIR/"
fi

# Populate wiki structure
echo ""
echo "Populating wiki structure..."
bash "$RALPHCLIP_HOME/setup-wiki.sh" company.toml

echo ""
echo "================================================================"
echo " Setup complete!"
echo ""
echo " Your company: $COMPANY_DIR/company.fossil"
echo " Workspace:    $COMPANY_DIR/workspace/"
echo ""
echo " Next steps:"
echo "   1. Edit agents/*.toml to add your engineer and other agents"
echo "   2. Customise skills/*.md for your domain"
echo "   3. Replace scripts/run-lint.sh and run-tests.sh with real commands"
echo "   4. Run: cd workspace && rexx $RALPHCLIP_HOME/orchestrate.rex"
echo "   5. View: fossil ui"
echo "================================================================"
