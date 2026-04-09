#!/bin/bash
#---------------------------------------------------------------------
# run-tests.sh — PHPUnit test runner
#---------------------------------------------------------------------
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"

if [ ! -f vendor/bin/phpunit ]; then
    echo "PHPUnit not installed. Run: composer require --dev phpunit/phpunit"
    echo "## Issue: PHPUnit not installed"
    echo "- assignee: engineer-php"
    echo "- severity: high"
    exit 1
fi

echo "Running PHPUnit..."

if vendor/bin/phpunit --testdox 2>&1; then
    echo ""
    echo "All tests pass."
    echo "<promise>COMPLETE</promise>"
else
    RESULT=$?
    echo ""
    echo "## Issue: PHPUnit test failures (exit code $RESULT)"
    echo "- assignee: engineer-php"
    echo "- severity: high"
    echo "- details: Run vendor/bin/phpunit for full output"
fi
