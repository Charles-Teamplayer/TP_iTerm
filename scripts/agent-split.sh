#!/bin/bash
# Agent 실행 시 화면 자동 분할
# PreToolUse(Agent) hook에서 호출
# tmux / iTerm2 네이티브 모두 지원

PROJECT="${1:-$(basename "$PWD")}"
AGENT_LOG="$HOME/.claude/logs/agent-activity.log"
SPLIT_MARKER="/tmp/.agent-split-$$-$(basename "$(tty)" 2>/dev/null || echo 'notty')"

mkdir -p "$(dirname "$AGENT_LOG")"
touch "$AGENT_LOG"

# === tmux 모드 ===
if [ -n "$TMUX" ]; then
    CURRENT_PANE=$(tmux display-message -p '#{pane_id}')
    PANE_COUNT=$(tmux list-panes | wc -l | tr -d ' ')

    if [ "$PANE_COUNT" -ge 2 ]; then
        exit 0
    fi

    tmux split-window -h -l 30% -t "$CURRENT_PANE" \
        "printf '\\033]2;agent-monitor\\033\\\\'; echo '━━━ Agent Monitor ━━━'; echo '프로젝트: $PROJECT'; echo '시작: $(date \"+%H:%M:%S\")'; echo ''; tail -f \"$AGENT_LOG\" 2>/dev/null || sleep 300"
    tmux select-pane -t "$CURRENT_PANE"
    echo "tmux" > "$SPLIT_MARKER"
    exit 0
fi

# === iTerm2 네이티브 모드 ===
if [ "$TERM_PROGRAM" = "iTerm.app" ] || pgrep -x "iTerm2" > /dev/null 2>&1; then
    # 이미 분할했으면 스킵
    if ls /tmp/.agent-split-*-"$(basename "$(tty)" 2>/dev/null || echo 'notty')" 2>/dev/null | grep -q .; then
        exit 0
    fi

    osascript << APPLESCRIPT
tell application "iTerm2"
    tell current session of current tab of current window
        set newSession to (split vertically with default profile)
        tell newSession
            set name to "Agent Monitor"
            write text "echo '━━━ Agent Monitor ━━━'; echo '프로젝트: $PROJECT'; echo '시작: $(date "+%H:%M:%S")'; echo ''; tail -f '$AGENT_LOG'"
        end tell
    end tell
end tell
APPLESCRIPT

    echo "iterm2" > "$SPLIT_MARKER"
fi

exit 0
