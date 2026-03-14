#!/bin/bash
# Agent 실행 시 화면 자동 분할 + 유지
# PreToolUse(Agent) hook에서 호출

PROJECT="${1:-$(basename "$PWD")}"
AGENT_LOG="$HOME/.claude/logs/agent-activity.log"
SPLIT_MARKER="/tmp/.agent-split-active"

mkdir -p "$(dirname "$AGENT_LOG")"
touch "$AGENT_LOG"

# 이미 분할했으면 스킵
[ -f "$SPLIT_MARKER" ] && exit 0

# === iTerm2 네이티브 모드 (현재 환경) ===
if [ "$TERM_PROGRAM" = "iTerm.app" ] || pgrep -x "iTerm2" > /dev/null 2>&1; then
    osascript << APPLESCRIPT 2>/dev/null
tell application "iTerm2"
    tell current session of current tab of current window
        set newSession to (split vertically with same profile)
        tell newSession
            set name to "Agent Monitor"
            write text "clear && printf '\\n  \\033[1;36m━━━ Agent Monitor ━━━\\033[0m\\n  프로젝트: $PROJECT\\n  시작: $(date "+%H:%M:%S")\\n  (자동 종료: 5분 무활동)\\n\\n' && tail -f '$AGENT_LOG' &  TAIL_PID=\$! && (sleep 300 && kill \$TAIL_PID 2>/dev/null && exit) & wait \$TAIL_PID 2>/dev/null; exit"
        end tell
    end tell
end tell
APPLESCRIPT
    echo "iterm2" > "$SPLIT_MARKER"
    # 5분 후 마커 자동 삭제 (다음 Agent 호출 시 다시 열 수 있도록)
    (sleep 300 && rm -f "$SPLIT_MARKER") &
    exit 0
fi

# === tmux 모드 ===
if [ -n "$TMUX" ]; then
    CURRENT_PANE=$(tmux display-message -p '#{pane_id}')
    PANE_COUNT=$(tmux list-panes | wc -l | tr -d ' ')
    [ "$PANE_COUNT" -ge 2 ] && exit 0

    tmux split-window -h -l 30% -t "$CURRENT_PANE" \
        "clear; printf '\\n  \\033[1;36m━━━ Agent Monitor ━━━\\033[0m\\n  프로젝트: $PROJECT\\n  시작: $(date \"+%H:%M:%S\")\\n\\n'; tail -f \"$AGENT_LOG\" 2>/dev/null; sleep 300"
    tmux select-pane -t "$CURRENT_PANE"
    echo "tmux" > "$SPLIT_MARKER"
    (sleep 300 && rm -f "$SPLIT_MARKER") &
fi

exit 0
