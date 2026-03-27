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

    _RST_DATA=$(_JF="$JSON_FILE" python3 -c "
import json, os
try:
    with open(os.environ['_JF']) as _f:
        d=json.load(_f)
    print(d.get('type','idle'))
    print(d.get('project',''))
except:
    print('idle'); print('')
" 2>/dev/null)
    STATE=$(printf '%s' "$_RST_DATA" | sed -n '1p')
    PROJECT=$(printf '%s' "$_RST_DATA" | sed -n '2p')

    TAB_TTY="$TTY_PATH" bash "$HOME/.claude/tab-color/engine/set-color.sh" "$STATE" "$PROJECT"
    RESTORED=$((RESTORED + 1))
done

echo "restored $RESTORED tab colors"
