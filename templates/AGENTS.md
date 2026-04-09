# AGENTS.md — RalphClip Working Directory Context

This project is managed by RalphClip, a local-first multi-agent orchestrator.
You are one of several AI agents working on this codebase. Follow these rules.

## How You Are Invoked

You receive a single prompt containing your role, goal ancestry, task title,
and any scope constraints. You run in a fresh context each iteration — you
have no memory of previous runs. Shared knowledge is in the "Learnings"
section of your prompt.

## Completion Protocol

When your task is fully complete:
1. Ensure all code compiles / lints / tests pass.
2. Commit your work with a descriptive message referencing the task.
3. Output the exact string `<promise>COMPLETE</promise>` as the last
   meaningful line of your output.

If you cannot complete the task, explain what's blocking you. Do NOT
output the completion marker unless the work is genuinely done.

## Scope Rules

If your prompt includes a SCOPE section, you may ONLY modify files in
the listed paths. Do not touch files outside your scope. A scope auditor
runs after you and will automatically revert out-of-scope changes.

## What NOT To Do

- Do not modify `.git/` or any version control internals.
- Do not install global packages or modify system configuration.
- Do not delete files outside your scope without explicit instruction.
- Do not modify `vendor/`, `node_modules/`, or dependency directories.
- Do not push to remote repositories — the orchestrator handles that.
- Do not create files in `/tmp` and leave them — clean up after yourself.

## Commit Messages

Use this format:

```
[ralphclip] <short description of what you did>

Task: <task title from your prompt>
Agent: <your role>
```

## Reporting Issues

If you discover a problem during your work that is outside your current
task scope, report it in your output using this format:

```
## Issue: <description>
- assignee: <agent who should fix it>
- severity: <critical|high|medium|low>
- details: <specifics>
```

The orchestrator will create a ticket from this automatically.

## Project Structure

Refer to the project's own README or documentation for codebase structure.
Your prompt's "Project context" section contains domain-specific information.
