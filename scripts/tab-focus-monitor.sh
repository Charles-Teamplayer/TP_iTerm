#!/bin/bash
# iTerm2 탭 포커스 감지 데몬 v4
# 탭 선택 시 🟡/🟠/⚫/🔵 → 🟢 자동 전환

STATE_DIR="$HOME/.claude/tab-states"
LOG="$HOME/.claude/logs/tab-focus-monitor.log"
TMP="/tmp/.iterm2-focus-tty"
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

rotate_log() {
    local logfile="$1" maxlines="${2:-10000}" keeplines="${3:-5000}"
    if [ -f "$logfile" ] && [ "$(wc -l < "$logfile")" -gt "$maxlines" ]; then
        tail -n "$keeplines" "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    fi
}

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
rotate_log "$LOG" 5000 2500
log "=== 포커스 모니터 v4 시작 ==="

# PATH 보장 (LaunchAgent용)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 원자적 파일 쓰기 (race condition 방지)
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.$$"
    echo "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null
}

LAST_TTY=""

# 시작 시 현재 탭 기록
LAST_TTY=$(osascript -e 'try' -e 'tell application "iTerm2" to return tty of current session of current tab of current window' -e 'end try' 2>/dev/null)
log "초기 TTY: ${LAST_TTY:-없음}"

while true; do
    # 현재 포커스 TTY 가져오기
    osascript -e 'try' -e 'tell application "iTerm2" to return tty of current session of current tab of current window' -e 'end try' > "$TMP" 2>/dev/null &
    OSA_PID=$!

    # 최대 2초 대기
    WAIT=0
    while [ $WAIT -lt 20 ] && kill -0 $OSA_PID 2>/dev/null; do
        sleep 0.1
        WAIT=$((WAIT + 1))
    done

    # 타임아웃 시 kill
    if kill -0 $OSA_PID 2>/dev/null; then
        kill -9 $OSA_PID 2>/dev/null
        wait $OSA_PID 2>/dev/null
        log "osascript 타임아웃 — skip"
        sleep 1
        continue
    fi
    wait $OSA_PID 2>/dev/null

    SESSION_TTY=$(cat "$TMP" 2>/dev/null | tr -d '\n\r')

    # 빈값이거나 같은 탭이면 스킵
    if [ -z "$SESSION_TTY" ] || [ "$SESSION_TTY" = "$LAST_TTY" ]; then
        sleep 1
        continue
    fi

    LAST_TTY="$SESSION_TTY"

    # 상태 파일 읽기
    TTY_NAME=$(basename "$SESSION_TTY")
    STATE_FILE="${STATE_DIR}/${TTY_NAME}"
    [ ! -f "$STATE_FILE" ] && { sleep 1; continue; }

    TAB_STATUS=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null)
    TAB_PROJECT=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null)

    case "$TAB_STATUS" in
        waiting|idle|stale|working)
            if [ -c "$SESSION_TTY" ]; then
                printf '\e]1;%s\a' "$TAB_PROJECT" > "$SESSION_TTY" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;0\a\e]6;1;bg;green;brightness;220\a\e]6;1;bg;blue;brightness;0\a' > "$SESSION_TTY" 2>/dev/null
                atomic_write "$STATE_FILE" "active|${TAB_PROJECT}|$(date +%s)"
                log "${TAB_STATUS} → active ($TAB_PROJECT, $TTY_NAME)"
            fi
            ;;
    esac

    sleep 1
done
