#!/bin/bash
# iTerm2 탭 포커스 감지 데몬 v4
# 탭 선택 시 🟡/🟠/⚫/🔵 → 🟢 자동 전환

STATE_DIR="$HOME/.claude/tab-color/states"
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

    # 상태 파일 읽기 (v3 JSON 형식)
    TTY_NAME=$(basename "$SESSION_TTY")
    STATE_FILE="${STATE_DIR}/${TTY_NAME}.json"
    [ ! -f "$STATE_FILE" ] && { sleep 1; continue; }

    TAB_STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('type',''))" 2>/dev/null)
    TAB_PROJECT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('project',''))" 2>/dev/null)

    case "$TAB_STATUS" in
        waiting|attention)
            if [ -c "$SESSION_TTY" ]; then
                # attention 상태면 flash 프로세스 먼저 kill
                if [ "$TAB_STATUS" = "attention" ]; then
                    FLASH_PID_FILE="/tmp/tab-flash-${TTY_NAME}.pid"
                    if [ -f "$FLASH_PID_FILE" ]; then
                        FLASH_PID=$(cat "$FLASH_PID_FILE" 2>/dev/null)
                        [ -n "$FLASH_PID" ] && kill "$FLASH_PID" 2>/dev/null
                        rm -f "$FLASH_PID_FILE"
                        log "flash 프로세스 종료 ($FLASH_PID, $TTY_NAME)"
                    fi
                fi

                # v3 엔진으로 active 색상 설정 (state file도 갱신됨)
                TAB_TTY="$SESSION_TTY" bash "$HOME/.claude/tab-color/engine/set-color.sh" active "$TAB_PROJECT"
                log "${TAB_STATUS} → active ($TAB_PROJECT, $TTY_NAME)"
            fi
            ;;
    esac

    sleep 1
done
