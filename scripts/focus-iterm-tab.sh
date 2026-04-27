#!/bin/bash
# focus-iterm-tab.sh — 알림 클릭 시 해당 iTerm2 탭으로 포커스 이동
# 사용법: focus-iterm-tab.sh <tty_path> [project_name_fallback]
#
# 매칭 우선순위:
#   1) tmux pane TTY 매칭 → tmux select-window (가장 정확, tmux -CC 환경 대응)
#   2) tmux window name == project 매칭 → tmux select-window
#   3) iTerm2 탭 이름 contains project (비-tmux 탭 fallback)

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

# 0. iTerm2를 무조건 활성화 (tmux select-window는 OS 포커스를 안 옮김)
osascript -e 'tell application "iTerm2" to activate' >/dev/null 2>&1

# 1. tmux pane TTY 매칭 → tmux select-window
TARGET=""
if [ -n "$TTY_PATH" ] && command -v tmux &>/dev/null; then
    TARGET=$(tmux list-panes -a -F '#{session_name}:#{window_id}|#{pane_tty}' 2>/dev/null \
             | awk -F'|' -v t="$TTY_PATH" '$2==t{print $1; exit}')
    if [ -n "$TARGET" ]; then
        if tmux select-window -t "$TARGET" 2>/dev/null; then
            log "matched-by-tmux-tty target=$TARGET"
            exit 0
        fi
    fi
fi

# 2. tmux window name == project → tmux select-window
if [ -n "$PROJECT" ] && command -v tmux &>/dev/null; then
    TARGET=$(tmux list-windows -a -F '#{session_name}:#{window_id}|#{window_name}' 2>/dev/null \
             | awk -F'|' -v p="$PROJECT" '$2==p{print $1; exit}')
    if [ -n "$TARGET" ]; then
        if tmux select-window -t "$TARGET" 2>/dev/null; then
            log "matched-by-tmux-name target=$TARGET"
            exit 0
        fi
    fi
fi

# 3. iTerm2 AppleScript fallback (비-tmux 탭용)
_esc() { printf '%s' "$1" | sed "s/'/\\\\'/g"; }
ESC_TTY=$(_esc "$TTY_PATH")
ESC_PROJ=$(_esc "$PROJECT")

RESULT=$(osascript <<EOF 2>&1
tell application "iTerm2"
    if "$ESC_TTY" is not "" then
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    try
                        if tty of s is "$ESC_TTY" then
                            tell w to select
                            tell t to select
                            tell s to select
                            return "matched-by-applescript-tty"
                        end if
                    end try
                end repeat
            end repeat
        end repeat
    end if
    if "$ESC_PROJ" is not "" then
        repeat with w in windows
            repeat with t in tabs of w
                try
                    set tName to name of current session of t
                    if tName contains "$ESC_PROJ" then
                        tell w to select
                        tell t to select
                        return "matched-by-applescript-name"
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
