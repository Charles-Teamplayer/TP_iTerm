#!/bin/bash
# Agent 완료 시 분할 pane 자동 닫기
# PostToolUse(Agent) hook에서 호출

TTY_ID="$(basename "$(tty)" 2>/dev/null || echo 'notty')"
SPLIT_MARKER="/tmp/.agent-split-${TTY_ID}"

[ -z "$SPLIT_MARKER" ] && exit 0

MODE=$(cat "$SPLIT_MARKER" 2>/dev/null)
rm -f "$SPLIT_MARKER"

case "$MODE" in
    tmux)
        if [ -n "$TMUX" ]; then
            MONITOR_PANE=$(tmux list-panes -F '#{pane_id} #{pane_title}' | grep "agent-monitor" | head -1 | awk '{print $1}')
            [ -n "$MONITOR_PANE" ] && tmux kill-pane -t "$MONITOR_PANE" 2>/dev/null
        fi
        ;;
    iterm2)
        osascript << 'APPLESCRIPT' 2>/dev/null || true
tell application "iTerm2"
    tell current tab of current window
        set paneList to sessions
        if (count of paneList) > 1 then
            repeat with s in paneList
                if name of s is "Agent Monitor" then
                    close s
                    exit repeat
                end if
            end repeat
        end if
    end tell
end tell
APPLESCRIPT
        ;;
esac

exit 0
