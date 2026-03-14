#!/bin/bash
# Agent 완료 시 분할 pane 자동 닫기
# PostToolUse(Agent) hook에서 호출

SPLIT_MARKER="/tmp/.agent-split-active"

[ ! -f "$SPLIT_MARKER" ] && exit 0

MODE=$(cat "$SPLIT_MARKER" 2>/dev/null)
rm -f "$SPLIT_MARKER"

case "$MODE" in
    tmux)
        if [ -n "$TMUX" ]; then
            PANE_COUNT=$(tmux list-panes | wc -l | tr -d ' ')
            if [ "$PANE_COUNT" -ge 2 ]; then
                # 현재 pane이 아닌 다른 pane 닫기
                CURRENT=$(tmux display-message -p '#{pane_id}')
                for PANE in $(tmux list-panes -F '#{pane_id}'); do
                    [ "$PANE" != "$CURRENT" ] && tmux kill-pane -t "$PANE" 2>/dev/null
                done
            fi
        fi
        ;;
    iterm2)
        osascript << 'APPLESCRIPT' 2>/dev/null || true
tell application "iTerm2"
    tell current tab of current window
        set sessionList to sessions
        if (count of sessionList) > 1 then
            -- 마지막 세션(=분할된 모니터) 닫기
            close (last item of sessionList)
        end if
    end tell
end tell
APPLESCRIPT
        ;;
esac

exit 0
