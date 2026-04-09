# RalphClip

**Local-first multi-agent orchestration for solo operators and small teams.**

Ralph's simplicity meets Paperclip's organisational structure — without servers, databases, or npm.

## What Is This?

RalphClip coordinates multiple AI coding agents (Claude Code, Mistral Vibe, Gemini CLI, Trinity), shell scripts, and ooRexx analysis scripts into a structured operation — with org charts, budgets, governance, and audit trails.

Everything runs locally. The entire "company" lives in a single Fossil SCM repository file.

## Core Principles

- **Fossil is the database.** Tickets, wiki, versioning, and a built-in web UI — all in one SQLite-backed file.
- **TOML is the org chart.** Human-readable config files define your company, projects, agents, and governance rules.
- **Markdown is the data format.** Agents communicate via plain text. No serialisation libraries.
- **ooRexx is the orchestrator.** ~600 lines of REXX across a few files. PARSE for CLI output, native decimal arithmetic for budgets, ADDRESS SYSTEM for CLI dispatch.
- **Agents are anything.** LLM runtimes, bash scripts, ooRexx scripts — all share the same interface.
- **Budget enforcement is non-negotiable.** Three levels: company, project, and per-agent caps.
- **Governance is built from existing primitives.** Fossil ticket status for approval gates, wiki pages for audit logs, git revert for rollback.

## Prerequisites

| Component | Purpose | Install |
|-----------|---------|---------|
| [Fossil SCM](https://fossil-scm.org/) | State management, tickets, wiki, web UI | Single binary download |
| [ooRexx](https://www.oorexx.org/) | Orchestrator runtime | Package manager or source build |
| At least one AI CLI agent | The actual workers | See below |

### Supported AI Runtimes

| Runtime | Binary | Best For | Cost |
|---------|--------|----------|------|
| Claude Code | `claude` | Architecture, strategy, creative writing | $$$ |
| Mistral Vibe | `vibe` | Code implementation, refactoring | $$ |
| Trinity Large | via OpenRouter API | Agent reasoning, decomposition, long-horizon tasks | $ |
| Trinity Mini | via OpenRouter API | QA review, bulk content, social media, structured output | ¢ |
| Gemini CLI | `gemini` | Research, SEO, documentation | Free tier |

Non-AI runtimes (no install needed):

| Runtime | Purpose | Cost |
|---------|---------|------|
| `script` | Shell scripts — linting, testing, builds, deploys | Free |
| `rexx` | ooRexx scripts — analysis, metrics, invoicing, auditing | Free |

## Quick Start

```bash
# 1. Create a project directory
mkdir my-company && cd my-company

# 2. Run the setup script
bash /path/to/ralphclip/setup.sh

# 3. Follow the prompts to configure your company, projects, and agents

# 4. Seed your first goal
fossil wiki commit "Goals/G001" < my-first-goal.md

# 5. Create your first epic ticket
fossil ticket add type=epic title="Build the thing" goal_id=G001 assignee=cto status=open

# 6. Run the orchestrator
rexx /path/to/ralphclip/orchestrate.rex

# 7. Open the dashboard
fossil ui
```

## Project Structure

After setup, your company directory looks like this:

```
my-company/
├── company.fossil          # The entire company (repo + tickets + wiki + audit)
├── workspace/              # Fossil checkout
│   ├── company.toml        # Company, project, and agent configuration
│   ├── agents/             # Agent TOML configs (one per agent)
│   │   ├── cto.toml
│   │   ├── engineer-php.toml
│   │   ├── qa.toml
│   │   ├── linter.toml
│   │   └── metrics.toml
│   ├── skills/             # Prompt templates per role (Markdown)
│   │   ├── decompose.md
│   │   ├── implement-php.md
│   │   └── review.md
│   ├── scripts/            # Shell and ooRexx agent scripts
│   │   ├── run-phpcs.sh
│   │   ├── run-tests.sh
│   │   └── compute-metrics.rex
│   └── runs/               # Run logs (unversioned)
└── (working dirs for each project are separate git repos)
```

## Documentation

- [Installation](INSTALL.md) — prerequisites, verification, first run
- [Architecture Overview](docs/ARCHITECTURE.md) — how the pieces fit together
- [Tutorial: Your First Company](docs/TUTORIAL.md) — step-by-step walkthrough
- [Creating ooRexx Agents](docs/CREATING-AGENTS.md) — write your own analysis agents
- [Governance Model](docs/GOVERNANCE.md) — budgets, approvals, gates, rollback, escalation
- [TOML Configuration Reference](docs/CONFIG-REFERENCE.md) — every config option explained

## How It Works

1. The orchestrator (`orchestrate.rex`) reads `company.toml` to load the org chart.
2. For each project, it queries Fossil tickets for open work.
3. For each agent with assigned tickets, it checks budget gates and governance rules.
4. It dispatches work to the appropriate runtime (Claude, Mistral, Trinity, Gemini, bash, or ooRexx).
5. Each dispatch is a Ralph loop — fresh context per iteration, max 5 attempts.
6. On completion, quality gates run (linting, tests, scope checks).
7. If gates pass, the ticket closes. If not, a fix ticket is created and assigned back.
8. Everything is logged to the Fossil governance wiki page.
9. Run `fossil ui` to see your dashboard.

## Runtime Spectrum

```
Free/Instant          Cheap/Fast           Premium/Smart
←————————————————————————————————————————————————————————→

bash        rexx      gemini  trinity-mini  trinity-lg  mistral    claude
scripts     analysis  research  QA review   agent       code       architecture
linting     metrics   SEO       social      reasoning   PHP/tests  strategy
builds      invoices  docs      content     decompose   refactor   creative

$0          $0        $0        ~$0.001     ~$0.005     ~$0.01     ~$0.05
                                per run     per run     per run    per run
```

## Licence

MIT. Do what you want with it.
