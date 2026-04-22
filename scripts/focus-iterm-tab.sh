#!/bin/bash
# focus-iterm-tab.sh — 알림 클릭 시 해당 iTerm2 탭으로 포커스 이동
# 사용법: focus-iterm-tab.sh <tty_path> [project_name_fallback]
# 1순위: TTY 경로 매칭 (정확)
# 2순위: 탭 이름에 프로젝트명 포함 여부 (fallback)

TTY_PATH="${1:-}"
PROJECT="${2:-}"
LOG_FILE="$HOME/.claude/logs/focus-iterm-tab.log"
mkdir -p "$(dirname "$LOG_FILE")"

# 로그 로테이션 (1000줄 초과 시 500줄 유지)
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 1000 ]; then
    tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null; }

log "request tty=$TTY_PATH project=$PROJECT"

if [ -z "$TTY_PATH" ] && [ -z "$PROJECT" ]; then
    log "skip: no args"
    exit 0
fi

# AppleScript escape (single quote)
_esc() { printf '%s' "$1" | sed "s/'/\\\\'/g"; }
ESC_TTY=$(_esc "$TTY_PATH")
ESC_PROJ=$(_esc "$PROJECT")

RESULT=$(osascript <<EOF 2>&1
tell application "iTerm2"
    activate
    -- 1순위: TTY 경로로 세션 찾기
    if "$ESC_TTY" is not "" then
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    try
                        if tty of s is "$ESC_TTY" then
                            tell w to select
                            tell t to select
                            tell s to select
                            return "matched-by-tty"
                        end if
                    end try
                end repeat
            end repeat
        end repeat
    end if
    -- 2순위: 탭/세션 이름에 프로젝트명 포함
    if "$ESC_PROJ" is not "" then
        repeat with w in windows
            repeat with t in tabs of w
                try
                    set tName to name of current session of t
                    if tName contains "$ESC_PROJ" then
                        tell w to select
                        tell t to select
                        return "matched-by-name"
                    end if
                end try
            end repeat
        end repeat
    end if
    return "no-match"
end tell
EOF
)

log "result=$RESULT"
