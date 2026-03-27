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

    # BUG#5 fix: 2회 파일 읽기 → 1회 통합
    _DATA=$(python3 -c "
import json
try:
    d=json.load(open('$JSON_FILE'))
    print(d.get('type','idle')); print(d.get('project',''))
except:
    print('idle'); print('')
" 2>/dev/null)
    STATE=$(printf '%s' "$_DATA" | sed -n '1p')
    PROJECT=$(printf '%s' "$_DATA" | sed -n '2p')

    TAB_TTY="$TTY_PATH" bash "$HOME/.claude/tab-color/engine/set-color.sh" "$STATE" "$PROJECT"
    RESTORED=$((RESTORED + 1))
done

echo "restored $RESTORED tab colors"
