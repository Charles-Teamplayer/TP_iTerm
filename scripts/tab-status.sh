#!/bin/bash
# iTerm2 탭 상태 표시 유틸리티
# 사용법: tab-status.sh <상태> [프로젝트명]
#
# 상태 체계 (탭 배경색만, 이모지 없음):
#   active   = 초록   세션 정상 / 스탠바이
#   working  = 노랑   입력 + 작업 중
#   waiting  = 파랑   작업 완료
#   idle     = 주황   1시간+ 입력 없음
#   stale    = 어두움  3일+ 입력 없음
#   starting = 하늘   세션 시작/복원 중
#   crashed  = 빨강   세션 끊김 (깜빡임)

STATUS="${1:-active}"

# dir → 짧은 탭 이름 매핑
_get_short_name() {
    local dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    case "$dir" in
        */TP_newIMSMS)                          echo "imsms" ;;
        */TP_newIMSMS_Agent)                    echo "imsms-agent" ;;
        */TP_MDM)                               echo "mdm" ;;
        */TP_TESLA_LVDS)                        echo "tesla-lvds" ;;
        */TESLA_Status_Dashboard)               echo "tesla-dash" ;;
        */TP_MindMap_AutoCC)                    echo "mindmap" ;;
        */SJ_MindMap)                           echo "sj-map" ;;
        */TP_A.iMessage_standalone_*)           echo "imessage" ;;
        */TP_BTT)                               echo "btt" ;;
        */TP_Infra_reduce_Project)              echo "infra" ;;
        */TP_skills)                            echo "skills" ;;
        */AppleTV_ScreenSaver.app)              echo "appletv" ;;
        */imsms.im-website)                     echo "imsms-web" ;;
        */TP_iTerm)               echo "auto-rst" ;;
        *)                                      basename "$dir" | cut -c1-12 ;;
    esac
}

PROJECT="${2:-$(_get_short_name)}"

# 로그 (최대 10000줄 유지)
LOG="$HOME/.claude/logs/tab-status-debug.log"
echo "[$(date '+%H:%M:%S')] ${STATUS} | ${PROJECT}" >> "$LOG" 2>/dev/null
if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 10000 ] 2>/dev/null; then
    tail -5000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null
fi

find_tty() {
    # 1. 환경변수
    if [ -n "${TTY:-}" ] && [ -c "$TTY" ]; then
        echo "$TTY"; return
    fi

    # 2. 부모 PID 체인 (hook에서 호출 시 항상 성공)
    local PID=$$
    for i in 1 2 3 4 5; do
        PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -z "$PID" ] && break
        local TTY_DEV=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
        if [ -n "$TTY_DEV" ] && [ "$TTY_DEV" != "??" ]; then
            echo "/dev/$TTY_DEV"; return
        fi
    done

    return 1
}

# 원자적 파일 쓰기 (race condition 방지)
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.$$"
    echo "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null
}

set_tab() {
    local TITLE="$1" R="$2" G="$3" B="$4"
    local TTY_PATH=$(find_tty)

    if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
        printf '\e]1;%s\a' "$TITLE" > "$TTY_PATH" 2>/dev/null
        if [ -n "$R" ]; then
            printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
                "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null
        fi
        local TTY_NAME=$(basename "$TTY_PATH")
        atomic_write "$HOME/.claude/tab-states/${TTY_NAME}" "${STATUS}|${PROJECT}|$(date +%s)"
    else
        osascript -e "tell application \"iTerm2\" to tell current session of current tab of current window to set name to \"${TITLE}\"" 2>/dev/null || true
    fi
}

case "$STATUS" in
    active)   set_tab "${PROJECT}" 0 220 0 ;;
    working)  set_tab "${PROJECT}" 255 230 0 ;;
    waiting)  set_tab "${PROJECT}" 0 120 255 ;;
    idle)     set_tab "${PROJECT}" 255 140 0 ;;
    stale)    set_tab "${PROJECT}" 80 80 80 ;;
    starting) set_tab "${PROJECT}" 0 160 255 ;;
    crashed)
        TTY_PATH=$(find_tty)
        if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
            TTY_NAME=$(basename "$TTY_PATH")
            atomic_write "$HOME/.claude/tab-states/${TTY_NAME}" "crashed|${PROJECT}|$(date +%s)"
            for i in $(seq 1 10); do
                if ps -o tty,command -ax | grep "$(basename "$TTY_PATH")" | grep -q "[c]laude" 2>/dev/null; then
                    printf '\e]1;%s\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
                    printf '\e]6;1;bg;red;brightness;0\a\e]6;1;bg;green;brightness;160\a\e]6;1;bg;blue;brightness;255\a' > "$TTY_PATH" 2>/dev/null
                    exit 0
                fi
                printf '\e]1;%s [CRASHED]\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;200\a\e]6;1;bg;green;brightness;200\a\e]6;1;bg;blue;brightness;200\a' > "$TTY_PATH" 2>/dev/null
                sleep 1
                printf '\e]1;%s [CRASHED]\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;255\a\e]6;1;bg;green;brightness;0\a\e]6;1;bg;blue;brightness;0\a' > "$TTY_PATH" 2>/dev/null
                sleep 1
            done
        fi
        ;;
esac

exit 0
