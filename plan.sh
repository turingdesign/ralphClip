#!/bin/bash
#---------------------------------------------------------------------
# plan.sh — Launch a Claude-powered company planning session
#
# Uses Claude Code in interactive mode with the company-planning skill
# to have a structured conversation about your business, then generates
# all RalphClip configuration files.
#
# Usage:
#   bash /path/to/ralphclip/plan.sh
#   bash /path/to/ralphclip/plan.sh --output-dir ./my-company
#
# Prerequisites: Claude Code CLI (claude) must be installed and logged in.
#---------------------------------------------------------------------

set -euo pipefail

RALPHCLIP_HOME="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$(pwd)}"

# Strip --output-dir flag if present
if [ "$OUTPUT_DIR" = "--output-dir" ]; then
    OUTPUT_DIR="${2:-.}"
fi

echo "================================================================"
echo " RalphClip — AI-Powered Company Planning Session"
echo "================================================================"
echo ""
echo " This will start an interactive conversation with Claude to"
echo " design your agent organisation, assign skills, allocate budgets,"
echo " and generate all configuration files."
echo ""
echo " Output directory: $OUTPUT_DIR"
echo ""

# Check Claude is available
if ! command -v claude &> /dev/null; then
    echo "ERROR: Claude Code CLI not found."
    echo ""
    echo "Install it with: npm install -g @anthropic-ai/claude-code"
    echo ""
    echo "Alternative: use the setup wizard instead (no AI needed):"
    echo "  rexx $RALPHCLIP_HOME/setup-wizard.rex"
    exit 1
fi

# Read the planning skill
SKILL_FILE="$RALPHCLIP_HOME/skills/general/company-planning.md"
if [ ! -f "$SKILL_FILE" ]; then
    echo "ERROR: Planning skill not found at $SKILL_FILE"
    exit 1
fi

SKILL_CONTENT=$(cat "$SKILL_FILE")

# Read the skills library index for context
SKILLS_INDEX=""
if [ -f "$RALPHCLIP_HOME/skills/README.md" ]; then
    SKILLS_INDEX=$(cat "$RALPHCLIP_HOME/skills/README.md")
fi

# Build the system prompt
SYSTEM_PROMPT="$SKILL_CONTENT

## Available Skills Library

$SKILLS_INDEX

## Runtime Cost Reference

| Runtime | Cost | Best For |
|---------|------|----------|
| claude-code | ~\$0.05/run | Architecture, strategy, creative |
| mistral-vibe | ~\$0.01/run | Code implementation, refactoring |
| trinity-large | ~\$0.005/run | Agent reasoning, decomposition |
| trinity-mini | ~\$0.001/run | QA, bulk content, structured output |
| gemini-cli | Free tier | Research, SEO, documentation |
| script (bash) | \$0.00 | Linting, testing, builds |
| rexx (ooRexx) | \$0.00 | Analysis, metrics, invoicing |

## Output Directory

Write all generated files to: $OUTPUT_DIR
If directories don't exist, create them.

Begin the planning conversation now. Start with Phase 1: Discovery."

# Create temp file for system prompt
PROMPT_FILE=$(mktemp /tmp/ralphclip-plan-XXXXXXXX.md)
echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"

echo "Starting planning session with Claude..."
echo "Type your answers naturally. Claude will guide you through the process."
echo ""
echo "================================================================"
echo ""

# Launch Claude in interactive mode with the planning prompt
# Using --system-prompt to inject the planning skill
claude \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    --model "claude-sonnet-4-20250514" \
    2>&1

# Cleanup
rm -f "$PROMPT_FILE"

echo ""
echo "================================================================"
echo " Planning session complete."
echo ""
echo " Check $OUTPUT_DIR for generated configuration files."
echo ""
echo " Next steps:"
echo "   1. Review the generated company.toml and agents/*.toml"
echo "   2. Run preflight: rexx $RALPHCLIP_HOME/orchestrate.rex --preflight"
echo "   3. Dry run:       rexx $RALPHCLIP_HOME/orchestrate.rex --dry-run"
echo "   4. Go live:       rexx $RALPHCLIP_HOME/orchestrate.rex"
echo "================================================================"
