#!/bin/bash
# Agent 실행 시 화면 자동 분할
# PreToolUse(Agent) hook에서 호출

PROJECT="${1:-$(basename "$PWD")}"
AGENT_LOG="$HOME/.claude/logs/agent-activity.log"
SPLIT_MARKER="/tmp/.agent-split-active"

mkdir -p "$(dirname "$AGENT_LOG")"
touch "$AGENT_LOG"

# 이미 분할했으면 스킵
[ -f "$SPLIT_MARKER" ] && exit 0

# === tmux 모드 ===
if [ -n "$TMUX" ]; then
    CURRENT_PANE=$(tmux display-message -p '#{pane_id}')
    PANE_COUNT=$(tmux list-panes | wc -l | tr -d ' ')
    [ "$PANE_COUNT" -ge 2 ] && exit 0

    tmux split-window -h -l 30% -t "$CURRENT_PANE" \
        "clear; printf '\\n  ━━━ Agent Monitor ━━━\\n  프로젝트: $PROJECT\\n  시작: $(date \"+%H:%M:%S\")\\n\\n'; tail -f \"$AGENT_LOG\" 2>/dev/null; sleep 300"
    tmux select-pane -t "$CURRENT_PANE"
    echo "tmux" > "$SPLIT_MARKER"
    exit 0
fi

# === iTerm2 네이티브 모드 ===
if [ "$TERM_PROGRAM" = "iTerm.app" ] || pgrep -x "iTerm2" > /dev/null 2>&1; then
    osascript << APPLESCRIPT 2>/dev/null
tell application "iTerm2"
    tell current session of current tab of current window
        set newSession to (split vertically with same profile)
        tell newSession
            set name to "Agent Monitor"
            write text "clear; printf '\\n  ━━━ Agent Monitor ━━━\\n  프로젝트: $PROJECT\\n  시작: $(date "+%H:%M:%S")\\n\\n'; tail -f '$AGENT_LOG'"
        end tell
    end tell
end tell
APPLESCRIPT
    echo "iterm2" > "$SPLIT_MARKER"
fi

exit 0
