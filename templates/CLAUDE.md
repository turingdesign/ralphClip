# CLAUDE.md — RalphClip Context for Claude Code

This project is managed by RalphClip, a local-first multi-agent orchestrator.
You are being invoked in headless mode (`claude -p`) as part of an automated
pipeline. Other agents (Mistral Vibe, Gemini CLI, shell scripts, ooRexx
scripts) may also work on this codebase.

## Critical Rules

1. **Complete one task only.** Your prompt specifies a single task. Do that
   task and nothing else, no matter what other issues you notice.

2. **Signal completion.** When done, output `<promise>COMPLETE</promise>`.
   The orchestrator watches for this exact string.

3. **Stay in scope.** If your prompt has a SCOPE section, only touch files
   in the allowed paths. An auditor will revert out-of-scope changes.

4. **Commit your work.** Use descriptive commit messages prefixed with
   `[ralphclip]`. Do not push — the orchestrator handles remotes.

5. **Report issues, don't fix them.** If you find a problem outside your
   task, report it with `## Issue:` format (see below). Don't fix it.

6. **No global installs.** Don't `npm install -g`, `pip install`, or
   modify system state. Work within the project's existing dependencies.

## Issue Reporting Format

```
## Issue: <description>
- assignee: <agent-name>
- severity: <critical|high|medium|low>
- details: <what you found>
```

## Commit Message Format

```
[ralphclip] <what you did>

Task: <task title from prompt>
Agent: <your role from prompt>
```
