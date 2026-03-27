#!/bin/bash
# tab-status.sh v3 wrapper — 하위호환 유지
# 실제 로직은 ~/.claude/tab-color/engine/set-color.sh

STATE="${1:-}"

# 사용자가 탭에 있을 때 working/waiting은 무시
if [ "$STATE" = "working" ] || [ "$STATE" = "waiting" ] || [ "$STATE" = "attention" ]; then
    STATE_DIR="$HOME/.claude/tab-color/states"
    # PPID 체인을 따라 올라가며 실제 TTY 찾기 (훅은 ?? TTY로 실행됨)
    _PID=$$
    CURRENT_TTY=""
    for _i in $(seq 1 15); do
        _TTY=$(ps -o tty= -p "$_PID" 2>/dev/null | tr -d ' ')
        if [ -n "$_TTY" ] && [ "$_TTY" != "??" ]; then
            CURRENT_TTY="$_TTY"
            break
        fi
        _PID=$(ps -o ppid= -p "$_PID" 2>/dev/null | tr -d ' ')
        [ -z "$_PID" ] || [ "$_PID" = "1" ] || [ "$_PID" = "0" ] && break
    done
    if [ -n "$CURRENT_TTY" ]; then
        STATE_FILE="$STATE_DIR/${CURRENT_TTY}.json"
        if [ -f "$STATE_FILE" ]; then
            # BUG#5 fix: 4회 파일 읽기 → 1회 통합 (race condition 제거)
            _STATE_DATA=$(python3 -c "
import json
try:
    d=json.load(open('$STATE_FILE'))
    c=d.get('color',{})
    print(d.get('type',''))
    print(c.get('r',0))
    print(c.get('g',220))
    print(c.get('b',0))
except:
    print(''); print(0); print(220); print(0)
" 2>/dev/null)
            CURRENT_STATE=$(printf '%s' "$_STATE_DATA" | sed -n '1p')
            _COLOR_R=$(printf '%s' "$_STATE_DATA" | sed -n '2p')
            _COLOR_G=$(printf '%s' "$_STATE_DATA" | sed -n '3p')
            _COLOR_B=$(printf '%s' "$_STATE_DATA" | sed -n '4p')
            echo "[$(date '+%H:%M:%S')] tab-status: state=$STATE tty=$CURRENT_TTY current=$CURRENT_STATE" >> "$HOME/.claude/logs/tab-status-debug.log"
            if [ "$CURRENT_STATE" = "active" ]; then
                echo "[$(date '+%H:%M:%S')] tab-status: BLOCKED (active 유지)" >> "$HOME/.claude/logs/tab-status-debug.log"
                # 시각적 불일치 복원: state=active이지만 TTY 색상이 달라졌을 수 있음 (watchdog 등)
                # 저장된 color값으로 즉시 재전송
                printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
                    "${_COLOR_R:-0}" "${_COLOR_G:-220}" "${_COLOR_B:-0}" > "/dev/$CURRENT_TTY" 2>/dev/null
                # timestamp 갱신 (watchdog aging 방지)
                python3 -c "
import json, datetime
f='$STATE_FILE'
with open(f) as fp: d=json.load(fp)
d['timestamp']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(f,'w') as fp: json.dump(d,fp)
" 2>/dev/null
                exit 0
            fi
        else
            echo "[$(date '+%H:%M:%S')] tab-status: state=$STATE tty=$CURRENT_TTY (state file 없음)" >> "$HOME/.claude/logs/tab-status-debug.log"
        fi
    else
        echo "[$(date '+%H:%M:%S')] tab-status: state=$STATE TTY 못 찾음" >> "$HOME/.claude/logs/tab-status-debug.log"
    fi
fi

exec bash "$HOME/.claude/tab-color/engine/set-color.sh" "$@"
