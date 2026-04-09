#!/bin/bash
#---------------------------------------------------------------------
# check-links.sh — Validate URLs in markdown content files
#---------------------------------------------------------------------
set -euo pipefail
cd "$RALPHCLIP_WORKING_DIR"

echo "Checking links in content files..."

BROKEN=0
CHECKED=0

for md in $(find . -name "*.md" -not -path "./node_modules/*" -not -path "./.git/*"); do
    # Extract HTTP URLs from markdown links and raw URLs
    URLS=$(grep -oP 'https?://[^\s\)\]"]+' "$md" 2>/dev/null || true)

    for url in $URLS; do
        CHECKED=$((CHECKED + 1))
        STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

        if [ "$STATUS" -ge 400 ] || [ "$STATUS" = "000" ]; then
            echo "BROKEN: $md → $url (HTTP $STATUS)"
            BROKEN=$((BROKEN + 1))
        fi
    done
done

echo ""
echo "Checked $CHECKED links."

if [ "$BROKEN" -eq 0 ]; then
    echo "All links valid."
    echo "<promise>COMPLETE</promise>"
else
    echo ""
    echo "## Issue: $BROKEN broken links found in content"
    echo "- assignee: seo-writer"
    echo "- severity: medium"
    echo "- details: Fix or remove broken URLs listed above"
fi
