#!/bin/sh
# Ranks a change's risk from what it touches, so the review it gets is
# decided by rules, not by the agent that wrote it. Prints the tier and why.
#   scripts/risk.sh            this branch against origin/main
#   scripts/risk.sh <base>     against another base
# AGENTS.md, "How a change ships", says what each tier needs.
set -eu

base="${1:-origin/main}"
files=$(git diff --name-only "$base"...HEAD)
[ -n "$files" ] || { echo "Risk: none (no changes against $base)"; exit 0; }

# Money, keys and secrets, storage, untrusted input, the core boundary,
# the message list, and keyboard and focus handling.
high='Engine\+Payments|Engine\+Account|Invoice|PaymentHistory|Sats\.swift|MoneyArrivals|Pay[A-Za-z]*\.swift|StateCodec|Keychain|PIN|Mnemonic|Clipboard|Storage\+Migrations|Storage\+Writes|Web\.swift|WebPage|ServerAddress|MessageMarkup|Contacts\.swift|Sources/Sphinxrs|Engine\.swift|ConversationView|MessageViews|ChatSearch|Sidebar\.swift|KeyMonitor|PeelMenu|MenuPresenter'
# Everything else that runs: engine, storage, app code, scripts.
medium='^Sources/|^Apps/|^scripts/|^Package'

# Only shipped code can be high: a test or doc named after a risky file is not.
reasons_high=$(printf '%s\n' "$files" | grep -E '^(Sources|Apps|scripts)/' | grep -E "$high" || true)
reasons_medium=$(printf '%s\n' "$files" | grep -E "$medium" || true)
lines=$(git diff --shortstat "$base"...HEAD | awk '{print $4 + $6}')

if [ -n "$reasons_high" ]; then
    tier=high
elif [ -n "$reasons_medium" ] || [ "${lines:-0}" -gt 400 ]; then
    tier=medium
else
    tier=low
fi

echo "Risk: $tier ($lines lines changed)"
[ -z "$reasons_high" ] || printf '%s\n' "$reasons_high" | sed 's/^/  high: /'
[ "$tier" != medium ] || [ -z "$reasons_medium" ] || printf '%s\n' "$reasons_medium" | sed 's/^/  medium: /'
[ "${lines:-0}" -le 400 ] || echo "  size: over 400 lines"
