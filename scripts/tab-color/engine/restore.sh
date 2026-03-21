#!/bin/bash
# Restore — 재부팅/reattach 후 탭 색상 복원
STATE_DIR="$HOME/.claude/tab-color/states"
CONFIG="$HOME/.claude/tab-color/config.json"
RESTORED=0

for JSON_FILE in "$STATE_DIR"/*.json; do
    [ -f "$JSON_FILE" ] || continue
    TTY_NAME=$(basename "$JSON_FILE" .json)
    TTY_PATH="/dev/$TTY_NAME"
    [ -c "$TTY_PATH" ] || continue
    [ -w "$TTY_PATH" ] || continue

    STATE=$(python3 -c "import json; d=json.load(open('$JSON_FILE')); print(d.get('type','idle'))" 2>/dev/null)
    PROJECT=$(python3 -c "import json; d=json.load(open('$JSON_FILE')); print(d.get('project',''))" 2>/dev/null)

    TAB_TTY="$TTY_PATH" bash "$HOME/.claude/tab-color/engine/set-color.sh" "$STATE" "$PROJECT"
    RESTORED=$((RESTORED + 1))
done

echo "restored $RESTORED tab colors"
