#!/bin/bash
#---------------------------------------------------------------------
# run-phpcs.sh — WordPress coding standards check
#---------------------------------------------------------------------
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"

if [ ! -f vendor/bin/phpcs ]; then
    echo "PHPCS not installed. Run: composer require --dev squizlabs/php_codesniffer wp-coding-standards/wpcs"
    echo "## Issue: PHPCS not installed"
    echo "- assignee: engineer-php"
    echo "- severity: high"
    exit 1
fi

echo "Running PHPCS with WordPress-Extra ruleset..."

OUTPUT=$(vendor/bin/phpcs \
    --standard=WordPress-Extra \
    --extensions=php \
    --ignore=vendor/,node_modules/,tests/ \
    --report=summary \
    . 2>&1) || true

ERRORS=$(echo "$OUTPUT" | grep -oP '\d+ ERROR' | grep -oP '\d+' || echo "0")

if [ "$ERRORS" = "0" ]; then
    echo "PHPCS clean — no violations found."
    echo "<promise>COMPLETE</promise>"
else
    echo "$OUTPUT"
    echo ""
    echo "## Issue: PHPCS found $ERRORS coding standard violations"
    echo "- assignee: engineer-php"
    echo "- severity: medium"
    echo "- details: Run vendor/bin/phpcs --standard=WordPress-Extra for full report"
fi
