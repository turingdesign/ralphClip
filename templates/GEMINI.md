# GEMINI.md — RalphClip Context for Gemini CLI

This project is managed by RalphClip, a local-first multi-agent orchestrator.
You are being invoked in headless mode (`gemini -p`) as part of an automated
pipeline. Other agents also work on this codebase.

## Rules

1. Complete the single task in your prompt. Nothing else.
2. When done, output `<promise>COMPLETE</promise>`.
3. Respect SCOPE constraints in your prompt — stay in allowed paths.
4. Commit work with `[ralphclip] <description>` message format.
5. Do not push to remotes.
6. Report problems outside your task scope with `## Issue:` format.

## Issue Format

```
## Issue: <description>
- assignee: <agent-name>
- severity: <critical|high|medium|low>
- details: <specifics>
```
