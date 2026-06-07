#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS="$SCRIPT_DIR/.secrets"
TEMPLATE="$SCRIPT_DIR/user-data.tpl"
OUTPUT="$SCRIPT_DIR/user-data"

if [[ ! -f "$SECRETS" ]]; then
  echo "Error: $SECRETS not found. Create it with PASSWORD_HASH='...'"
  exit 1
fi

source "$SECRETS"

if [[ -z "${PASSWORD_HASH:-}" ]]; then
  echo "Error: PASSWORD_HASH not set in $SECRETS"
  exit 1
fi

sed "s|PASSWORD_HASH|${PASSWORD_HASH}|" "$TEMPLATE" > "$OUTPUT"
echo "Written: $OUTPUT"
