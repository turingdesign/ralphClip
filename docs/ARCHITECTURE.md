# RalphClip Architecture

## Overview

RalphClip is a local-first orchestration system that coordinates AI agents, shell scripts, and ooRexx analysis scripts into structured business operations. It combines Ralph's autonomous agent loop pattern with Paperclip's organisational model — without servers, databases, or web frameworks.

## Component Map

```
┌─────────────────────────────────────────────────────┐
│                   YOU (The Board)                     │
│          Review, approve, set goals, override         │
└──────────────────────┬──────────────────────────────┘
                       │
                       │ fossil ui / fossil ticket change
                       │
┌──────────────────────▼──────────────────────────────┐
│              Fossil SCM Repository                    │
│  ┌──────────┐ ┌──────────┐ ┌───────────────────┐    │
│  │ Tickets  │ │   Wiki   │ │  Version Control  │    │
│  │ (tasks)  │ │ (state)  │ │    (history)      │    │
│  └──────────┘ └──────────┘ └───────────────────┘    │
│  Single SQLite file — company.fossil                 │
└──────────────────────┬──────────────────────────────┘
                       │
                       │ fossil ticket list / fossil wiki export
                       │
┌──────────────────────▼──────────────────────────────┐
│             orchestrate.rex (ooRexx)                  │
│  ┌────────────┐ ┌────────────┐ ┌────────────────┐   │
│  │ Budget     │ │ Governance │ │ Dispatch Loop   │   │
│  │ Gates      │ │ Engine     │ │ (Ralph pattern) │   │
│  └────────────┘ └────────────┘ └───────┬────────┘   │
│                                        │             │
│  ┌─────────────────────────────────────▼──────────┐  │
│  │              adapters.rex                       │  │
│  │  ┌───────┐ ┌───────┐ ┌──────┐ ┌────────┐      │  │
│  │  │claude │ │mistral│ │gemini│ │trinity │      │  │
│  │  └───────┘ └───────┘ └──────┘ └────────┘      │  │
│  │  ┌───────┐ ┌───────┐                           │  │
│  │  │script │ │ rexx  │                           │  │
│  │  └───────┘ └───────┘                           │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
                       │
           ┌───────────┼───────────┐
           ▼           ▼           ▼
    ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ git repo │ │ git repo │ │ git repo │
    │ project1 │ │ project2 │ │ project3 │
    └──────────┘ └──────────┘ └──────────┘
```

## Data Flow

### Single Orchestration Run

```
1. orchestrate.rex starts
2. Reads company.toml → loads projects, agents, governance rules
3. Checks company budget → HALT if exhausted
4. For each project:
   a. Check project budget → SKIP if exhausted
   b. Run leader agent (CTO/CMO) to decompose any open epics
   c. For each agent assigned to this project:
      i.   Check agent budget → SKIP if exhausted
      ii.  Query Fossil tickets: status=open, assignee=<agent>, project=<project>
      iii. Check dependencies → SKIP if deps not closed
      iv.  Check approval gates → PARK if approval required
      v.   Check triggers → SKIP if trigger conditions not met
      vi.  Load skill prompt from skills/<skill>.md
      vii. Load agent learnings from wiki
      viii. Ralph loop (max N iterations):
           - Build prompt (skill + role + goal ancestry + task + learnings + scope)
           - Dispatch to runtime adapter (claude/mistral/trinity/gemini/script/rexx)
           - Parse result: output, cost, success, complete
           - Record cost in budget
           - If complete: run quality gates
           - If gates pass: close ticket, update learnings
           - If gates fail: reopen ticket, create fix ticket
      ix.  Log all actions to GovernanceLog wiki page
5. Final fossil commit with run summary
```

### Ticket Lifecycle

```
                    ┌──────────┐
                    │  EPIC    │ (created by human or CTO)
                    └────┬─────┘
                         │ CTO decomposes
                    ┌────▼─────┐
                    │  OPEN    │ (assigned to agent)
                    └────┬─────┘
                         │ orchestrator dispatches
                    ┌────▼─────┐
                    │IN-PROGRESS│
                    └────┬─────┘
                    ┌────┤
         ┌─────────▼┐   │   ┌──────────────┐
         │ COMPLETE  │   │   │   FAILED      │
         │(tentative)│   │   │ (retries left)│──→ back to OPEN
         └────┬──────┘   │   └──────────────┘
              │ quality   │
              │ gates     │   ┌──────────────────┐
              │ run       ├──→│AWAITING-APPROVAL │ (parked)
              │           │   └───────┬──────────┘
         ┌────▼─────┐    │           │ human approves
         │GATE PASS │    │      ┌────▼─────┐
         └────┬─────┘    │      │  OPEN    │ (re-queued)
              │          │      └──────────┘
         ┌────▼─────┐   │
         │  CLOSED   │   │   ┌──────────────┐
         └──────────┘    └──→│ ESCALATED    │ (suspended)
                             └──────────────┘
```

## Fossil as Infrastructure

Fossil replaces multiple infrastructure components:

| Traditional Tool | Fossil Feature | How RalphClip Uses It |
|-----------------|----------------|----------------------|
| PostgreSQL/SQLite | Ticket database | Task queue, story backlog, cost tracking |
| Jira/Linear | Ticket web UI | `fossil ui` → browse tickets, filter, search |
| GitHub Wiki | Wiki system | Org chart, budget, learnings, governance log |
| Git | Version control | Code history, config history, audit trail |
| Express/React dashboard | Built-in web server | `fossil ui` on localhost |
| Backup system | Single file repo | `cp company.fossil company.fossil.bak` |

### Custom Ticket Fields

RalphClip adds these fields to Fossil's ticket system:

```
project      — project code (e.g., "paddockapp", "bricksfit")
goal_id      — top-level goal reference (e.g., "G001")
goal_chain   — full ancestry (e.g., "G001 > Plugin Architecture > Data Model")
assignee     — agent name (e.g., "engineer-php")
depends      — comma-separated ticket IDs this depends on
cost_usd     — accumulated cost for this ticket
acceptance   — acceptance criteria text
gate_type    — which quality gate pipeline applies (code, content, deploy)
```

## The Adapter Pattern

Every runtime — LLM or otherwise — implements the same interface:

```
Input:  prompt (string) — may be ignored by script/rexx agents
Output: result. (stem)
        result.output   — text output from the agent
        result.cost     — cost in USD (0.00 for scripts)
        result.success  — 1 if ran cleanly, 0 if error
        result.complete — 1 if <promise>COMPLETE</promise> found
```

This normalisation means the orchestrator never needs to know what kind of agent it is dispatching to. An ooRexx metrics script and a Claude Opus session look identical from the dispatch loop's perspective.

## Separation of Concerns

| Component | Responsibility | Location |
|-----------|---------------|----------|
| `company.toml` | Company structure, projects, agents, governance rules | Versioned in Fossil |
| `agents/*.toml` | Per-agent config: runtime, model, budget, scope | Versioned in Fossil |
| `skills/*.md` | Domain-specific prompt templates | Versioned in Fossil |
| `scripts/*.sh` | Deterministic automation (lint, test, build) | Versioned in Fossil |
| `scripts/*.rex` | Logic-bearing analysis (metrics, audits, invoices) | Versioned in Fossil |
| `orchestrate.rex` | Main dispatch loop | RalphClip install dir |
| `adapters.rex` | Runtime normalisation | RalphClip install dir |
| `lib/*.rex` | Shared utilities (TOML, Fossil helpers, governance) | RalphClip install dir |
| `company.fossil` | All state (tickets, wiki, history) | Project root |

Domain knowledge lives in TOML and Markdown. Orchestration logic lives in ooRexx. State lives in Fossil. Nothing is mixed.
