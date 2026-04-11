#!/bin/bash
#---------------------------------------------------------------------
# tests/test-dry-run.sh — RalphClip integration test
#
# Creates a temporary Fossil repo, seeds a ticket, runs orchestrate.rex
# in --dry-run mode, and asserts on output/exit code.
#
# Prerequisites: fossil, rexx (ooRexx) on PATH.
# No API keys or LLM runtimes needed.
#
# Usage:  bash tests/test-dry-run.sh [path-to-ralphclip-dir]
#---------------------------------------------------------------------
set -euo pipefail

RALPHCLIP_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"
TMPDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (output did not contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== RalphClip Dry-Run Integration Test ==="
echo "  RalphClip dir: $RALPHCLIP_DIR"
echo "  Temp dir:      $TMPDIR"
echo ""

#--- Check prerequisites ---
echo "--- Prerequisites ---"
if ! command -v fossil &>/dev/null; then
  echo "  SKIP: fossil not found on PATH. Install fossil to run tests."
  exit 77  # standard skip code
fi
if ! command -v rexx &>/dev/null; then
  echo "  SKIP: rexx (ooRexx) not found on PATH."
  exit 77
fi
echo "  fossil: $(which fossil)"
echo "  rexx:   $(which rexx)"
echo ""

#--- Set up test company ---
echo "--- Setup ---"
cd "$TMPDIR"

# Create Fossil repo
fossil init company.fossil --project-name "TestCo" 2>/dev/null
mkdir workspace && cd workspace
fossil open ../company.fossil 2>/dev/null

# Copy fixtures into workspace
cp "$FIXTURE_DIR/company.toml" .
mkdir -p agents scripts skills runs parked_tasks handoffs traces escalations
cp "$FIXTURE_DIR/agents/test-agent.toml" agents/
cp "$FIXTURE_DIR/scripts/test-noop.sh" scripts/
chmod +x scripts/test-noop.sh

# Add custom ticket fields (mirror RalphClip's schema)
fossil ticket add-field project text 2>/dev/null || true
fossil ticket add-field assignee text 2>/dev/null || true
fossil ticket add-field depends text 2>/dev/null || true
fossil ticket add-field goal_chain text 2>/dev/null || true
fossil ticket add-field gate_type text 2>/dev/null || true

# Seed a test ticket
fossil ticket add type story \
  title "Test task: echo hello" \
  status open \
  assignee test-agent \
  project testproj \
  gate_type "" \
  2>/dev/null

# Initial commit
fossil addremove 2>/dev/null
fossil commit -m "test setup" --no-warnings 2>/dev/null || true

echo "  Repo created, ticket seeded."
echo ""

#--- Test 1: --preflight ---
echo "--- Test 1: Preflight ---"
set +e
PREFLIGHT_OUT=$(rexx "$RALPHCLIP_DIR/orchestrate.rex" company.toml --preflight 2>&1)
PREFLIGHT_RC=$?
set -e

assert_contains "preflight mentions test-agent" "test-agent" "$PREFLIGHT_OUT"
assert_contains "preflight shows script runtime" "script" "$PREFLIGHT_OUT"
echo ""

#--- Test 2: --dry-run ---
echo "--- Test 2: Dry Run ---"
set +e
DRYRUN_OUT=$(rexx "$RALPHCLIP_DIR/orchestrate.rex" company.toml --dry-run 2>&1)
DRYRUN_RC=$?
set -e

assert_eq "dry-run exit code is 0" "0" "$DRYRUN_RC"
assert_contains "dry-run header shows TestCo" "TestCo" "$DRYRUN_OUT"
assert_contains "dry-run shows DRY RUN mode" "DRY RUN" "$DRYRUN_OUT"
assert_contains "dry-run mentions test-agent" "test-agent" "$DRYRUN_OUT"
echo ""

#--- Test 3: No open tickets = idle ---
echo "--- Test 3: Idle run (no tickets) ---"
# Close the test ticket by changing its status
fossil ticket list --format "%u" 2>/dev/null | while read -r tid; do
  [ -z "$tid" ] && continue
  fossil ticket change "$tid" status closed 2>/dev/null || true
done

set +e
IDLE_OUT=$(rexx "$RALPHCLIP_DIR/orchestrate.rex" company.toml --dry-run 2>&1)
IDLE_RC=$?
set -e

assert_eq "idle exit code is 0" "0" "$IDLE_RC"
assert_contains "idle run reports no work" "idle" "$IDLE_OUT"
echo ""

#--- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
