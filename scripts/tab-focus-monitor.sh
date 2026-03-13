#!/bin/bash
# iTerm2 탭 포커스 감지 데몬
# 탭 선택 시 🟡/🟠/⚫ → 🟢 자동 전환
# 파일 기반 상태 판별: ~/.claude/tab-states/{tty}

STATE_DIR="$HOME/.claude/tab-states"
LOG="$HOME/.claude/logs/tab-focus-monitor.log"
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
log "=== 포커스 모니터 시작 ==="

LAST_TTY=""

while true; do
    # 현재 포커스된 세션의 TTY
    SESSION_TTY=$(osascript 2>/dev/null <<'SCPT'
tell application "iTerm2"
    if (count of windows) = 0 then return ""
    tell current session of current tab of current window
        return tty
    end tell
end tell
SCPT
    )

    if [ -z "$SESSION_TTY" ]; then
        sleep 2
        continue
    fi

    # 같은 탭이면 스킵
    if [ "$SESSION_TTY" = "$LAST_TTY" ]; then
        sleep 2
        continue
    fi

    LAST_TTY="$SESSION_TTY"

    # 해당 TTY의 상태 파일 읽기
    TTY_NAME=$(basename "$SESSION_TTY")
    STATE_FILE="${STATE_DIR}/${TTY_NAME}"

    if [ ! -f "$STATE_FILE" ]; then
        sleep 2
        continue
    fi

    TAB_STATUS=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null)
    TAB_PROJECT=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null)

    # waiting/idle/stale → 🟢 active 전환
    case "$TAB_STATUS" in
        waiting|idle|stale|working)
            if [ -c "$SESSION_TTY" ]; then
                printf '\e]1;🟢 %s\a' "$TAB_PROJECT" > "$SESSION_TTY" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;0\a\e]6;1;bg;green;brightness;220\a\e]6;1;bg;blue;brightness;0\a' > "$SESSION_TTY" 2>/dev/null
                echo "active|${TAB_PROJECT}" > "$STATE_FILE"
                log "${TAB_STATUS} → active ($TAB_PROJECT, $TTY_NAME)"
            fi
            ;;
    esac

    sleep 2
done
