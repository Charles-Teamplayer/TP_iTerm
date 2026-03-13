#!/bin/bash
# iTerm2 탭 상태 표시 유틸리티
# 사용법: tab-status.sh <상태> [프로젝트명]
#
# 상태 체계 (이모지 + 탭 배경색):
#   active   = 🟢 초록   세션 정상 / 스탠바이
#   working  = 🔵 파랑   작업 중 (도구 실행 + 응답 생성)
#   waiting  = 🟡 노랑   응답 완료, 사용자 입력 대기
#   idle     = 🟠 주황   1일+ 입력 없음
#   stale    = ⚫ 어두움  7일+ 입력 없음
#   starting = 🔄 하늘   세션 시작/복원 중
#   crashed  = 🔴 빨강   세션 끊김 (⚪🔴 깜빡임)
#
# 방식: TTY escape sequence
#   탭 타이틀: \e]1;title\a
#   탭 색상:   \e]6;1;bg;red;brightness;N\a + green + blue

STATUS="${1:-active}"
PROJECT="${2:-$(basename "$PWD")}"

find_tty() {
    if [ -n "${TTY:-}" ] && [ -c "$TTY" ]; then
        echo "$TTY"
        return
    fi

    local PID=$$
    local TTY_DEV=""
    for i in 1 2 3 4 5; do
        PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -z "$PID" ] && break
        TTY_DEV=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
        if [ -n "$TTY_DEV" ] && [ "$TTY_DEV" != "??" ]; then
            echo "/dev/$TTY_DEV"
            return
        fi
    done

    if [ -n "$PROJECT" ]; then
        local MATCH_TTY=""
        while read -r tty pid rest; do
            [ "$tty" = "??" ] && continue
            local ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -z "$ppid" ] && continue
            local cwd=$(lsof -p "$ppid" 2>/dev/null | grep cwd | awk '{print $NF}')
            if echo "$cwd" | grep -q "$PROJECT"; then
                MATCH_TTY="/dev/$tty"
                break
            fi
        done < <(ps -o tty,pid -ax | grep "[c]laude" | grep -v "Helper\|ShipIt\|watchdog\|auto-restore\|Claude.app")
        if [ -n "$MATCH_TTY" ] && [ -c "$MATCH_TTY" ]; then
            echo "$MATCH_TTY"
            return
        fi
    fi

    return 1
}

# 탭 타이틀 + 배경색 + 사용자 변수 동시 설정
set_tab() {
    local TITLE="$1"
    local R="$2" G="$3" B="$4"
    local TTY_PATH=$(find_tty)

    if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
        # 탭 타이틀
        printf '\e]1;%s\a' "$TITLE" > "$TTY_PATH" 2>/dev/null
        # 탭 배경색
        if [ -n "$R" ]; then
            printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
                "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null
        fi
        # 파일에 상태 저장 (포커스 모니터가 읽음)
        local TTY_NAME=$(basename "$TTY_PATH")
        echo "${STATUS}|${PROJECT}" > "$HOME/.claude/tab-states/${TTY_NAME}" 2>/dev/null
    else
        osascript -e "tell application \"iTerm2\" to tell current session of current tab of current window to set name to \"${TITLE}\"" 2>/dev/null || true
    fi
}

# 탭 배경색 리셋
reset_tab_color() {
    local TTY_PATH=$(find_tty)
    if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
        printf '\e]6;1;bg;*;default\a' > "$TTY_PATH" 2>/dev/null
    fi
}

case "$STATUS" in
    active)
        set_tab "🟢 ${PROJECT}" 0 220 0
        ;;
    working)
        set_tab "🔵 ${PROJECT}" 0 120 255
        ;;
    waiting)
        set_tab "🟡 ${PROJECT}" 255 230 0
        ;;
    idle)
        set_tab "🟠 ${PROJECT} [1d+]" 255 140 0
        ;;
    stale)
        set_tab "⚫ ${PROJECT} [7d+]" 80 80 80
        ;;
    starting)
        set_tab "🔄 ${PROJECT}" 0 160 255
        ;;
    crashed)
        TTY_PATH=$(find_tty)
        if [ -n "$TTY_PATH" ] && [ -c "$TTY_PATH" ]; then
            for i in $(seq 1 10); do
                # claude 재시작 감지 시 조기 탈출
                if ps -o tty,command -ax | grep "$(basename "$TTY_PATH")" | grep -q "[c]laude" 2>/dev/null; then
                    printf '\e]1;🔄 %s\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
                    printf '\e]6;1;bg;red;brightness;80\a\e]6;1;bg;green;brightness;160\a\e]6;1;bg;blue;brightness;220\a' > "$TTY_PATH" 2>/dev/null
                    exit 0
                fi
                # ⚪ 흰 배경
                printf '\e]1;⚪ %s [CRASHED]\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;200\a\e]6;1;bg;green;brightness;200\a\e]6;1;bg;blue;brightness;200\a' > "$TTY_PATH" 2>/dev/null
                sleep 1
                # 🔴 빨간 배경
                printf '\e]1;🔴 %s [CRASHED]\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
                printf '\e]6;1;bg;red;brightness;220\a\e]6;1;bg;green;brightness;40\a\e]6;1;bg;blue;brightness;40\a' > "$TTY_PATH" 2>/dev/null
                sleep 1
            done
            printf '\e]1;🔴 %s [CRASHED]\a' "$PROJECT" > "$TTY_PATH" 2>/dev/null
        else
            for i in $(seq 1 10); do
                osascript -e "tell application \"iTerm2\" to tell current session of current tab of current window to set name to \"⚪ ${PROJECT} [CRASHED]\"" 2>/dev/null
                sleep 1
                osascript -e "tell application \"iTerm2\" to tell current session of current tab of current window to set name to \"🔴 ${PROJECT} [CRASHED]\"" 2>/dev/null
                sleep 1
            done
        fi
        ;;
    *)
        reset_tab_color
        set_tab "${PROJECT}" "" "" ""
        ;;
esac

exit 0
