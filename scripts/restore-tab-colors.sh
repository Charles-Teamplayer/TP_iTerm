#!/bin/bash
# tab-states 기반 탭 색상 복원
# 호출 시점: tmux -CC reattach 후, TP_iTerm_Restore 복원 후
# JSON 우선 읽기, 텍스트 fallback
STATE_DIR="$HOME/.claude/tab-states"
[ ! -d "$STATE_DIR" ] && exit 0

# JSON 파일에서 상태 읽기 (python3 사용)
read_json_state() {
    local json_file="$1"
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    c = d.get('color', {})
    print(f\"{d['type']}|{d['project']}|{c.get('r',0)}|{c.get('g',0)}|{c.get('b',0)}\")
except:
    sys.exit(1)
" "$json_file" 2>/dev/null
}

# 상태 → 색상 매핑 (텍스트 fallback용)
status_to_color() {
    case "$1" in
        active)   echo "0|220|0"   ;;
        working)  echo "255|230|0"   ;;
        waiting)  echo "0|120|255" ;;
        idle)     echo "255|140|0"   ;;
        stale)    echo "80|80|80"  ;;
        starting) echo "0|160|255" ;;
        crashed)  echo "255|0|0"   ;;
        attention) echo "180|0|255" ;;
        *)        return 1 ;;
    esac
}

RESTORED=0
for STATE_FILE in "$STATE_DIR"/ttys*; do
    [ ! -f "$STATE_FILE" ] && continue
    # .json 파일은 텍스트 파일 처리 루프에서 스킵
    [[ "$STATE_FILE" == *.json ]] && continue

    TTY_NAME=$(basename "$STATE_FILE")
    TTY_PATH="/dev/$TTY_NAME"
    [ ! -c "$TTY_PATH" ] || [ ! -w "$TTY_PATH" ] && continue

    JSON_FILE="${STATE_FILE}.json"
    STATUS="" PROJECT="" R="" G="" B=""

    # JSON 우선 읽기
    if [ -f "$JSON_FILE" ]; then
        PARSED=$(read_json_state "$JSON_FILE")
        if [ $? -eq 0 ] && [ -n "$PARSED" ]; then
            STATUS=$(echo "$PARSED" | cut -d'|' -f1)
            PROJECT=$(echo "$PARSED" | cut -d'|' -f2)
            R=$(echo "$PARSED" | cut -d'|' -f3)
            G=$(echo "$PARSED" | cut -d'|' -f4)
            B=$(echo "$PARSED" | cut -d'|' -f5)
        fi
    fi

    # JSON 실패 시 텍스트 fallback
    if [ -z "$STATUS" ] || [ -z "$PROJECT" ]; then
        STATUS=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null)
        PROJECT=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null)
        [ -z "$STATUS" ] || [ -z "$PROJECT" ] && continue
        COLOR=$(status_to_color "$STATUS")
        [ $? -ne 0 ] && continue
        R=$(echo "$COLOR" | cut -d'|' -f1)
        G=$(echo "$COLOR" | cut -d'|' -f2)
        B=$(echo "$COLOR" | cut -d'|' -f3)
    fi

    printf '\e]1;%s\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
    printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
        "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null
    RESTORED=$((RESTORED + 1))
done

echo "restored $RESTORED tab colors"
