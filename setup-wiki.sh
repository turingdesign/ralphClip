#!/bin/bash
#---------------------------------------------------------------------
# setup-wiki.sh — Populate Fossil wiki structure for a RalphClip company
#
# Run from inside the workspace/ directory after setup.sh has been run.
# Reads company.toml to discover projects and agents, then creates
# all wiki pages with sensible defaults and templates.
#
# Usage: bash /path/to/ralphclip/setup-wiki.sh [company.toml]
#---------------------------------------------------------------------

set -euo pipefail

TOML="${1:-company.toml}"

if [ ! -f "$TOML" ]; then
    echo "ERROR: Cannot find $TOML"
    echo "Usage: bash setup-wiki.sh [path/to/company.toml]"
    exit 1
fi

# Simple TOML reader — extract a value by key
toml_get() {
    local file="$1" key="$2"
    grep "^${key} " "$file" 2>/dev/null | head -1 | sed 's/.*= *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '"'
}

# Commit a wiki page from stdin or a string
wiki_commit() {
    local page="$1"
    shift
    echo "$@" | fossil wiki commit "$page" 2>/dev/null && \
        echo "  Created: $page" || \
        echo "  Updated: $page"
}

# Commit a wiki page from a heredoc (pipe usage)
wiki_commit_pipe() {
    local page="$1"
    fossil wiki commit "$page" 2>/dev/null && \
        echo "  Created: $page" || \
        echo "  Updated: $page"
}

echo "================================================================"
echo " RalphClip Wiki Setup"
echo "================================================================"
echo ""

#---------------------------------------------------------------------
# Read company config
#---------------------------------------------------------------------
COMPANY_NAME=$(toml_get "$TOML" "name")
BUDGET=$(toml_get "$TOML" "monthly_budget_usd")
[ -z "$COMPANY_NAME" ] && COMPANY_NAME="My Company"
[ -z "$BUDGET" ] && BUDGET="0.00"

# Discover projects from [projects.*] sections
PROJECTS=$(grep '^\[projects\.' "$TOML" | sed 's/\[projects\.\(.*\)\]/\1/')

# Discover agents from agents/*.toml files
AGENTS=""
if [ -d agents ]; then
    AGENTS=$(ls agents/*.toml 2>/dev/null | xargs -I{} basename {} .toml)
fi

echo "Company: $COMPANY_NAME"
echo "Projects: $PROJECTS"
echo "Agents: $AGENTS"
echo ""

#---------------------------------------------------------------------
# Home page
#---------------------------------------------------------------------
echo "--- Core pages ---"

cat << EOF | wiki_commit_pipe "Home"
# ${COMPANY_NAME}

## Quick Actions
- [Submit Work](/tktnew) | [Ticket Board](/ticket) | [Timeline](/timeline)

## Status
- [Budget](wiki?name=Budget) | [Governance Log](wiki?name=GovernanceLog)
- [Org Chart](wiki?name=OrgChart) | [Agent Performance](wiki?name=Metrics/AgentPerformance)

## Projects
$(for p in $PROJECTS; do
    pname=$(toml_get "$TOML" "client" | head -1)
    echo "- [${p}](wiki?name=Projects/${p}/Context)"
done)

## Operations
- [Metrics](wiki?name=Metrics/CodeHealth) | [Invoices](wiki?name=Invoices/Latest)
- [Runbooks](wiki?name=Runbooks/NewProject)

## Agent Learnings
$(for a in $AGENTS; do
    echo "- [${a}](wiki?name=AgentLearnings/${a})"
done)
EOF

#---------------------------------------------------------------------
# Org Chart
#---------------------------------------------------------------------
ORGCHART="# ${COMPANY_NAME} — Org Chart

Board (Human Operator)
"
for a in $AGENTS; do
    if [ -f "agents/${a}.toml" ]; then
        role=$(toml_get "agents/${a}.toml" "role")
        runtime=$(toml_get "agents/${a}.toml" "runtime")
        [ -z "$role" ] && role="$a"
        [ -z "$runtime" ] && runtime="unknown"
        ORGCHART="${ORGCHART}  - ${a}: ${role} (${runtime})
"
    fi
done
wiki_commit "OrgChart" "$ORGCHART"

#---------------------------------------------------------------------
# Budget page
#---------------------------------------------------------------------
BUDGET_PAGE="# Budget — ${COMPANY_NAME}

cap: ${BUDGET}
spent: 0.00

## Per-Project Spend
"
for p in $PROJECTS; do
    pcap=$(grep -A5 "^\[projects\.${p}\]" "$TOML" | grep "budget_usd" | head -1 | sed 's/.*= *//')
    [ -z "$pcap" ] && pcap="0.00"
    BUDGET_PAGE="${BUDGET_PAGE}${p}: 0.00
"
done

BUDGET_PAGE="${BUDGET_PAGE}
## Per-Agent Spend
"
for a in $AGENTS; do
    BUDGET_PAGE="${BUDGET_PAGE}${a}: 0.00
"
done
wiki_commit "Budget" "$BUDGET_PAGE"

#---------------------------------------------------------------------
# Governance Log
#---------------------------------------------------------------------
wiki_commit "GovernanceLog" "# Governance Log

$(date +%Y%m%d) $(date +%H:%M:%S) | SETUP | all | Wiki structure initialised"

#---------------------------------------------------------------------
# Project Registry (drives ticket form dropdown)
#---------------------------------------------------------------------
REGISTRY="# Project Registry
# Format: code | display name | default goal | working dir | gate type
"
for p in $PROJECTS; do
    pdir=$(grep -A5 "^\[projects\.${p}\]" "$TOML" | grep "working_dir" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    [ -z "$pdir" ] && pdir="."
    REGISTRY="${REGISTRY}${p} | ${p} | G001 | ${pdir} | code
"
done
wiki_commit "ProjectRegistry" "$REGISTRY"

#---------------------------------------------------------------------
# Per-project wiki pages
#---------------------------------------------------------------------
echo ""
echo "--- Project pages ---"

for p in $PROJECTS; do
    pdir=$(grep -A5 "^\[projects\.${p}\]" "$TOML" | grep "working_dir" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    [ -z "$pdir" ] && pdir="."

    # Context
    cat << EOF | wiki_commit_pipe "Projects/${p}/Context"
# ${p} — Project Context

## Stack
- (Edit this: language, framework, tools)

## Architecture
- (Edit this: key patterns, namespaces, directory layout)

## Conventions
- (Edit this: coding standards, naming, commit message format)
- See [Decisions](wiki?name=Projects/${p}/Decisions) for rationale

## Known Issues
- (None yet — agents will append issues they discover here)

## Working Directory
${pdir}
EOF

    # Goals
    cat << EOF | wiki_commit_pipe "Projects/${p}/Goals/G001"
# G001: (Define your goal here)

(One paragraph describing what success looks like)

## Success Criteria
- [ ] (Measurable outcome 1)
- [ ] (Measurable outcome 2)
- [ ] (Measurable outcome 3)

## Constraints
- Budget: (amount)
- Timeline: (date)
EOF

    # Decisions log
    cat << EOF | wiki_commit_pipe "Projects/${p}/Decisions"
# ${p} — Decisions

Record architectural and strategic decisions here.
Agents and humans both append to this page.

## Template

### YYYY-MM-DD: (Decision title)
- Context: (What prompted this decision)
- Decision: (What was decided)
- Rationale: (Why)
- Decided by: (Agent name or Human)
EOF

    # Retrospectives
    cat << EOF | wiki_commit_pipe "Projects/${p}/Retrospectives"
# ${p} — Retrospectives

## Template

### Week of YYYY-MM-DD

**What shipped:**
- (list)

**What went wrong:**
- (list)

**What to change:**
- (list)

**Cost:** \$X.XX (budget: \$Y, remaining: \$Z)
EOF

    # Client Brief
    cat << EOF | wiki_commit_pipe "Projects/${p}/ClientBrief"
# ${p} — Client Brief

## Client
- Name:
- Contact:

## What they want
(In their words)

## What they actually need
(Your interpretation)

## Audience
(Who are they trying to reach)

## Success metrics
(How will they judge success)
EOF

    # Handover
    cat << EOF | wiki_commit_pipe "Projects/${p}/Handover"
# ${p} — Handover Notes

If someone else needs to pick up this project, they need to know:

## Current State
- (What's been built so far)
- (What's in progress)
- (What's blocked)

## Key Files
- (List the important files and what they do)

## Gotchas
- (Things that aren't obvious from the code)

## Contacts
- (Who to talk to about this project)
EOF

    # Brand Voice (useful for all projects, essential for marketing)
    cat << EOF | wiki_commit_pipe "Projects/${p}/BrandVoice"
# ${p} — Brand Voice

## Audience
(Who are we talking to?)

## Tone
- (Describe the voice: practical, formal, casual, technical?)

## Do
- (Writing rules to follow)

## Don't
- (Things to avoid)

## Example Phrases
- Good: "(example)"
- Bad: "(example)"
EOF

    # Keyword Map (for content/marketing projects)
    cat << EOF | wiki_commit_pipe "Projects/${p}/Keywords"
# ${p} — Keyword Map

Target densities:
- Primary keywords: 1.0-2.5%
- Secondary keywords: 0.5-1.5%

## Keywords
- primary: (your main keyword)
- secondary: (supporting keyword 1)
- secondary: (supporting keyword 2)
EOF

done

#---------------------------------------------------------------------
# Agent Learnings — one page per agent
#---------------------------------------------------------------------
echo ""
echo "--- Agent pages ---"

for a in $AGENTS; do
    role=""
    if [ -f "agents/${a}.toml" ]; then
        role=$(toml_get "agents/${a}.toml" "role")
    fi
    [ -z "$role" ] && role="$a"

    wiki_commit "AgentLearnings/${a}" "# ${a} — Learnings

Role: ${role}

Learnings are appended automatically after each successful task.

(No learnings yet)"
done

#---------------------------------------------------------------------
# Metrics pages
#---------------------------------------------------------------------
echo ""
echo "--- Metrics pages ---"

cat << 'EOF' | wiki_commit_pipe "Metrics/CodeHealth"
# Code Health Metrics

Updated automatically by the code-metrics agent.

(No data yet — run the orchestrator to populate)
EOF

cat << 'EOF' | wiki_commit_pipe "Metrics/BudgetHistory"
# Budget History

Weekly snapshots of spend across projects.

| Week | Company Total | Notes |
|------|--------------|-------|
| (auto-populated) | | |
EOF

cat << EOF | wiki_commit_pipe "Metrics/AgentPerformance"
# Agent Performance

| Agent | Tasks | Completed | Failed | Avg Iters | Total Cost |
|-------|-------|-----------|--------|-----------|------------|
$(for a in $AGENTS; do
    echo "| ${a} | 0 | 0 | 0 | - | \$0.00 |"
done)

(Updated weekly by metrics agent)
EOF

#---------------------------------------------------------------------
# Invoices
#---------------------------------------------------------------------
echo ""
echo "--- Invoices ---"

wiki_commit "Invoices/Latest" "# Invoices

No invoices generated yet.
Run the invoice-generator agent to produce weekly invoices.

Invoices are stored as: Invoices/YYYYMMDD"

#---------------------------------------------------------------------
# Runbooks
#---------------------------------------------------------------------
echo ""
echo "--- Runbooks ---"

cat << 'EOF' | wiki_commit_pipe "Runbooks/NewProject"
# Runbook: Adding a New Project

1. **Edit company.toml** — add a `[projects.code]` section:
   ```toml
   [projects.newproject]
   client = "Client Name"
   budget_usd = 50.00
   working_dir = "~/clients/newproject"
   context_wiki = "Projects/NewProject/Context"
   goals = ["G001"]
   ```

2. **Update ProjectRegistry wiki page** — add a line:
   ```
   newproject | Display Name | G001 | ~/clients/newproject | code
   ```

3. **Create project wiki pages** — either manually or re-run:
   ```
   bash /path/to/ralphclip/setup-wiki.sh
   ```

4. **Edit agent TOML files** — add the project code to agents' `projects` list.

5. **Create the working directory** and initialise git:
   ```
   mkdir -p ~/clients/newproject && cd ~/clients/newproject && git init
   ```

6. **Copy agent context files** to the working directory:
   ```
   cp /path/to/ralphclip/templates/*.md ~/clients/newproject/
   ```

7. **Edit Projects/NewProject/Context** wiki page with project details.

8. **Create the first epic ticket** in fossil.

9. **Run the orchestrator** — the CTO will decompose the epic.
EOF

cat << 'EOF' | wiki_commit_pipe "Runbooks/NewAgent"
# Runbook: Adding a New Agent

1. **Create agent TOML** in `agents/`:
   ```toml
   # agents/myagent.toml
   role = "My New Agent"
   runtime = "mistral"        # claude|mistral|trinity|gemini|script|rexx
   model = "devstral-2"       # model name (ignored for script/rexx)
   budget_usd = 20.00         # monthly cap (0.00 for scripts)
   skill = "my-skill"         # loads skills/my-skill.md
   projects = ["myproject"]   # which projects this agent works on
   trigger = "ticket"         # ticket|after:agent|always|manual|cron:expr
   ```

2. **Create skill prompt** in `skills/my-skill.md` — instructions for the agent.

3. **For script/rexx agents**, create the script in `scripts/` and set:
   ```toml
   script = "scripts/my-script.sh"   # or .rex
   ```

4. **Update OrgChart wiki page** to include the new agent.

5. **Test standalone** before adding to the orchestration loop:
   ```
   RALPHCLIP_WORKING_DIR=~/myproject rexx scripts/my-script.rex
   ```

See [Creating ooRexx Agents](doc/CREATING-AGENTS.md) for detailed guide.
EOF

cat << 'EOF' | wiki_commit_pipe "Runbooks/Escalation"
# Runbook: Handling Escalated Agents

When an agent fails 3+ consecutive times, the orchestrator:
1. Moves all its open tickets to `escalated` status
2. Writes to the escalation notification file
3. Logs the event to GovernanceLog

## To investigate:

1. **Check the run logs** in `runs/<latest>/<agent>-<project>.log`
   — full output from the failing iterations.

2. **Check the governance log** for the failure pattern:
   ```
   fossil wiki export GovernanceLog | grep <agent>
   ```

3. **Common causes:**
   - API rate limits (Claude Pro, Mistral PAYG) — wait or switch runtime
   - Corrupted working directory — check `git status`
   - Skill prompt issue — agent doesn't understand the task format
   - Scope violation — agent tried to touch forbidden paths

## To resume:

1. **Fix the underlying issue.**

2. **Reset the failure counter:**
   ```
   rm runs/.failures-<agent>
   ```

3. **Reopen escalated tickets:**
   ```
   fossil ticket list status=escalated assignee=<agent> --format "%u"
   # Then for each:
   fossil ticket change <id> status=open
   ```

4. **Run the orchestrator** — the agent will pick up work again.
EOF

cat << 'EOF' | wiki_commit_pipe "Runbooks/ClientOnboarding"
# Runbook: Onboarding a New Client

1. **Discovery call** — fill in [Client Brief Template](wiki?name=Templates/ClientBriefTemplate).

2. **Create the project** — follow [New Project runbook](wiki?name=Runbooks/NewProject).

3. **Define the goal** — edit `Projects/<code>/Goals/G001` with success criteria.

4. **Set the brand voice** — edit `Projects/<code>/BrandVoice`.

5. **Research phase** — create an epic ticket for audience/competitor research.

6. **Set budget** — update company.toml and the Budget wiki page.

7. **First run** — let the CTO/CMO decompose the epic.

8. **Review first output** — check agent work before enabling unattended runs.
EOF

cat << 'EOF' | wiki_commit_pipe "Runbooks/Deployment"
# Runbook: Deployment / Publishing

## WordPress Plugin (wp.org)
1. Ensure all quality gates pass (linter, tests).
2. Update `readme.txt` changelog and version.
3. Update plugin header version in main PHP file.
4. Tag the release: `git tag v1.0.0 && git push --tags`
5. Build the zip: `bash scripts/build-plugin.sh`
6. Submit to wp.org SVN (manual or scripted).

## Marketing Content (blog/social)
1. Ensure content passes word count and keyword density checks.
2. Review the draft in the working directory.
3. Change ticket status from `awaiting-approval` to `open` to trigger deploy.
4. Deploy script pushes to staging/production.

## General
- Never deploy without human approval gate.
- Always verify on staging before production.
- Record the deployment in Projects/<code>/Retrospectives.
EOF

#---------------------------------------------------------------------
# Templates
#---------------------------------------------------------------------
echo ""
echo "--- Templates ---"

cat << 'EOF' | wiki_commit_pipe "Templates/GoalTemplate"
# G00X: (Goal title)

(One paragraph describing what success looks like)

## Success Criteria
- [ ] (Measurable outcome 1)
- [ ] (Measurable outcome 2)
- [ ] (Measurable outcome 3)

## Constraints
- Budget: $X
- Timeline: (date)
- Dependencies: (other projects or external factors)
EOF

cat << 'EOF' | wiki_commit_pipe "Templates/ProjectContextTemplate"
# (Project) — Project Context

## Stack
- Language:
- Framework:
- Build tools:
- Test framework:

## Architecture
- Key patterns:
- Directory layout:
- API structure:

## Conventions
- Coding standards:
- Naming conventions:
- Commit message format:
- See [Decisions](wiki?name=Projects/<project>/Decisions) for rationale

## Known Issues
- (None yet)

## Working Directory
(path)
EOF

cat << 'EOF' | wiki_commit_pipe "Templates/ClientBriefTemplate"
# (Client) — Client Brief

## Client
- Name:
- Contact:
- Project code:

## What they want
(In their words)

## What they actually need
(Your interpretation after discovery)

## Audience
(Who are they trying to reach)

## Competitors
(Who else serves this audience)

## Budget and timeline
(What they've committed to)

## Success metrics
(How will they judge success)
EOF

#---------------------------------------------------------------------
# Summary
#---------------------------------------------------------------------
echo ""
echo "================================================================"
echo " Wiki setup complete!"
echo ""
echo " Pages created:"
echo "   - Home, OrgChart, Budget, GovernanceLog, ProjectRegistry"

for p in $PROJECTS; do
    echo "   - Projects/${p}: Context, Goals, Decisions, Retrospectives,"
    echo "     ClientBrief, Handover, BrandVoice, Keywords"
done

echo "   - AgentLearnings: one page per agent"
echo "   - Metrics: CodeHealth, BudgetHistory, AgentPerformance"
echo "   - Invoices: Latest"
echo "   - Runbooks: NewProject, NewAgent, Escalation,"
echo "     ClientOnboarding, Deployment"
echo "   - Templates: Goal, ProjectContext, ClientBrief"
echo ""
echo " View your wiki: fossil ui"
echo "================================================================"
