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
#   attention = 보라  권한 요청 대기 (배지 ⚠️)

STATUS="${1:-active}"
CONFIG_FILE="$HOME/.claude/config/iterm-config.json"

# config 기반 프로젝트명 조회 (iterm-config.json의 project_names 맵)
_resolve_project_name() {
    local raw="${1:-$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")}"
    if [ -f "$CONFIG_FILE" ]; then
        local mapped
        mapped=$(python3 -c "
import json, sys
try:
    d = json.load(open('$CONFIG_FILE'))
    names = d.get('project_names', {})
    print(names.get(sys.argv[1], sys.argv[1]))
except:
    print(sys.argv[1])
" "$raw" 2>/dev/null)
        [ -n "$mapped" ] && echo "$mapped" || echo "$raw"
    else
        echo "$raw"
    fi
}

# Legacy: 하드코딩 매핑 (config 미사용 시 수동 fallback용, 현재 미사용)
# _get_short_name() {
#     local dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
#     case "$dir" in
#         */TP_newIMSMS)                          echo "imsms" ;;
#         */TP_newIMSMS_Agent)                    echo "imsms-agent" ;;
#         */TP_MDM)                               echo "mdm" ;;
#         */TP_TESLA_LVDS)                        echo "tesla-lvds" ;;
#         */TESLA_Status_Dashboard)               echo "tesla-dash" ;;
#         */TP_MindMap_AutoCC)                    echo "mindmap" ;;
#         */SJ_MindMap)                           echo "sj-map" ;;
#         */TP_A.iMessage_standalone_*)           echo "imessage" ;;
#         */TP_BTT)                               echo "btt" ;;
#         */TP_Infra_reduce_Project)              echo "infra" ;;
#         */TP_skills)                            echo "skills" ;;
#         */AppleTV_ScreenSaver.app)              echo "appletv" ;;
#         */imsms.im-website)                     echo "imsms-web" ;;
#         */TP_iTerm)               echo "auto-rst" ;;
#         *)                                      basename "$dir" | cut -c1-12 ;;
#     esac
# }

PROJECT=$(_resolve_project_name "${2:-}")

# config에서 badge 텍스트 읽기
_get_config() {
    local key="$1" default="$2"
    if [ -f "$CONFIG_FILE" ]; then
        local val
        val=$(python3 -c "import json,sys; d=json.load(open('$CONFIG_FILE')); print(d.get('$key',''))" 2>/dev/null)
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

_badge_enabled() {
    if [ -f "$CONFIG_FILE" ]; then
        python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('badge_enabled',True))" 2>/dev/null | grep -qi "true"
    fi
}

rotate_log() {
    local logfile="$1" maxlines="${2:-10000}" keeplines="${3:-5000}"
    if [ -f "$logfile" ] && [ "$(wc -l < "$logfile")" -gt "$maxlines" ]; then
        tail -n "$keeplines" "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    fi
}

LOG="$HOME/.claude/logs/tab-status-debug.log"
rotate_log "$LOG" 10000 5000
echo "[$(date '+%H:%M:%S')] ${STATUS} | ${PROJECT}" >> "$LOG" 2>/dev/null

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

set_badge() {
    local TTY_PATH="$1" BADGE_TEXT="$2"
    if _badge_enabled && [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
        local ENCODED
        ENCODED=$(printf '%s' "$BADGE_TEXT" | base64)
        printf '\e]1337;SetBadgeFormat=%s\a' "$ENCODED" > "$TTY_PATH" 2>/dev/null
    fi
}

set_tab() {
    local TITLE="$1" R="$2" G="$3" B="$4" BADGE="${5:-}"
    local TTY_PATH=$(find_tty)

    if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
        printf '\e]1;%s\a' "$TITLE" > "$TTY_PATH" 2>/dev/null
        if [ -n "$R" ]; then
            printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
                "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null
        fi
        set_badge "$TTY_PATH" "$BADGE"
        local TTY_NAME=$(basename "$TTY_PATH")
        atomic_write "$HOME/.claude/tab-states/${TTY_NAME}" "${STATUS}|${PROJECT}|$(date +%s)"
    else
        osascript -e "tell application \"iTerm2\" to tell current session of current tab of current window to set name to \"${TITLE}\"" 2>/dev/null || true
    fi
}

case "$STATUS" in
    active)   set_tab "${PROJECT}" 0 220 0 "" ;;
    working)  set_tab "${PROJECT}" 255 230 0 "" ;;
    waiting)  set_tab "${PROJECT}" 0 120 255 "" ;;
    idle)     set_tab "${PROJECT}" 255 140 0 "" ;;
    stale)    set_tab "${PROJECT}" 80 80 80 "$(_get_config badge_stale '💤')" ;;
    starting) set_tab "${PROJECT}" 0 160 255 "" ;;
    attention)
        BADGE_TEXT=$(_get_config badge_attention '⚠️')
        set_tab "${PROJECT}" 180 0 255 "$BADGE_TEXT"
        ;;
    crashed)
        TTY_PATH=$(find_tty)
        if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
            TTY_NAME=$(basename "$TTY_PATH")
            atomic_write "$HOME/.claude/tab-states/${TTY_NAME}" "crashed|${PROJECT}|$(date +%s)"
            set_badge "$TTY_PATH" "$(_get_config badge_crashed '🔴')"
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
