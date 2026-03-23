#!/bin/bash
# iTerm2 탭 포커스 감지 데몬 v5 — tmux 기반 (osascript 제거)
# tmux display-message로 활성 윈도우 감지 → waiting/attention → active 복원

STATE_DIR="$HOME/.claude/tab-color/states"
LOG="$HOME/.claude/logs/tab-focus-monitor.log"
TMUX_SESSION="claude-work"
mkdir -p "$(dirname "$LOG")"

rotate_log() {
    local logfile="$1"
    if [ -f "$logfile" ] && [ "$(wc -l < "$logfile")" -gt 5000 ]; then
        tail -n 2500 "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    fi
}

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
rotate_log "$LOG"
log "=== 포커스 모니터 v5 시작 (tmux 기반) ==="

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LAST_WIN=""

while true; do
    # tmux 세션 존재 확인
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        sleep 5
        continue
    fi

    # 현재 활성 윈도우 인덱스
    CUR_WIN=$(tmux display-message -t "$TMUX_SESSION" -p '#{window_index}' 2>/dev/null)
    [ -z "$CUR_WIN" ] && { sleep 1; continue; }

    # 윈도우 변경 감지
    if [ "$CUR_WIN" = "$LAST_WIN" ]; then
        sleep 1
        continue
    fi
    LAST_WIN="$CUR_WIN"

    # 새로 포커스된 윈도우의 모든 pane TTY 확인
    while IFS= read -r PANE_TTY; do
        [ -z "$PANE_TTY" ] && continue
        TTY_NAME=$(basename "$PANE_TTY")
        STATE_FILE="${STATE_DIR}/${TTY_NAME}.json"
        [ ! -f "$STATE_FILE" ] && continue

        TAB_STATUS=$(python3 -c "
import json
try:
    d=json.load(open('$STATE_FILE'))
    print(d.get('type',''))
except: print('')
" 2>/dev/null)

        case "$TAB_STATUS" in
            waiting|attention|idle_10m|idle_1h|idle_1d|idle_3d)
                if [ -c "$PANE_TTY" ]; then
                    # flash 종료
                    FLASH_PID_FILE="/tmp/tab-flash-${TTY_NAME}.pid"
                    if [ -f "$FLASH_PID_FILE" ]; then
                        FLASH_PID=$(cat "$FLASH_PID_FILE" 2>/dev/null)
                        [ -n "$FLASH_PID" ] && kill "$FLASH_PID" 2>/dev/null
                        rm -f "$FLASH_PID_FILE"
                    fi
                    # active 복원
                    TAB_PROJECT=$(python3 -c "
import json
try:
    d=json.load(open('$STATE_FILE'))
    print(d.get('project',''))
except: print('')
" 2>/dev/null)
                    TAB_TTY="$PANE_TTY" bash "$HOME/.claude/tab-color/engine/set-color.sh" active "$TAB_PROJECT"
                    log "${TAB_STATUS} → active ($TAB_PROJECT, $TTY_NAME, win=$CUR_WIN)"
                fi
                ;;
        esac
    done < <(tmux list-panes -t "${TMUX_SESSION}:${CUR_WIN}" -F '#{pane_tty}' 2>/dev/null)

    sleep 1
done
