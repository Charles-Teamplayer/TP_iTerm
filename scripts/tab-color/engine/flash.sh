#!/bin/bash
# Flash Engine — 백그라운드 플래시 루프 (crashed는 횟수 제한, attention은 무한)
STATE="$1"
TTY_PATH="$2"
CONFIG="$3"

INTERVAL=$(python3 -c "
import json
d = json.load(open('$CONFIG'))
print(d['states'].get('$STATE', {}).get('flash_interval', 0.8))
" 2>/dev/null || echo "0.8")

# 주 색상
MAIN_COLOR=$(python3 -c "
import json
d = json.load(open('$CONFIG'))
c = d['states'].get('$STATE', {}).get('color', [255,0,0])
print(f'{c[0]}|{c[1]}|{c[2]}')
" 2>/dev/null || echo "255|0|0")
MR=$(echo "$MAIN_COLOR" | cut -d'|' -f1)
MG=$(echo "$MAIN_COLOR" | cut -d'|' -f2)
MB=$(echo "$MAIN_COLOR" | cut -d'|' -f3)

# 대체 색상
ALT_COLOR=$(python3 -c "
import json
d = json.load(open('$CONFIG'))
c = d['states'].get('$STATE', {}).get('flash_alt_color', [255,140,0])
print(f'{c[0]}|{c[1]}|{c[2]}')
" 2>/dev/null || echo "255|140|0")
AR=$(echo "$ALT_COLOR" | cut -d'|' -f1)
AG=$(echo "$ALT_COLOR" | cut -d'|' -f2)
AB=$(echo "$ALT_COLOR" | cut -d'|' -f3)

apply_color() {
    local R=$1 G=$2 B=$3
    printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
        "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null
}

if [ "$STATE" = "crashed" ]; then
    # crashed: 10회 후 종료
    for i in $(seq 1 10); do
        apply_color $AR $AG $AB; sleep "$INTERVAL"
        apply_color $MR $MG $MB; sleep "$INTERVAL"
    done
else
    # attention: 무한 루프 — TTY 사망 시 자동 종료
    trap 'exit 0' TERM INT
    FAIL_COUNT=0
    while true; do
        if [ ! -c "$TTY_PATH" ] || [ ! -w "$TTY_PATH" ]; then
            exit 0  # TTY 사라지면 자동 종료
        fi
        apply_color $AR $AG $AB
        if [ $? -ne 0 ]; then
            FAIL_COUNT=$((FAIL_COUNT + 1))
            [ $FAIL_COUNT -ge 3 ] && exit 0  # 3회 연속 실패 시 종료
        else
            FAIL_COUNT=0
        fi
        sleep "$INTERVAL"
        apply_color $MR $MG $MB; sleep "$INTERVAL"
    done
fi
