#!/bin/bash
# tab-status.sh v3 wrapper — 하위호환 유지
# 실제 로직은 ~/.claude/tab-color/engine/set-color.sh

STATE="${1:-}"

# active 상태일 때 working/waiting은 무시 (사용자가 탭 보는 중)
if [ "$STATE" = "working" ] || [ "$STATE" = "waiting" ]; then
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
            CURRENT_STATE=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('type',''))" 2>/dev/null)
            if [ "$CURRENT_STATE" = "active" ]; then
                exit 0  # 사용자가 탭에 있는 중 — 색상 변경 안 함
            fi
        fi
    fi
fi

exec bash "$HOME/.claude/tab-color/engine/set-color.sh" "$@"
