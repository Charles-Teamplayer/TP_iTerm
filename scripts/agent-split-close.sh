#!/bin/bash
# Agent 완료 시 분할 pane 자동 닫기
# PostToolUse(Agent) hook에서 호출

if [ -z "$TMUX" ]; then
    exit 0
fi

PANE_COUNT=$(tmux list-panes | wc -l | tr -d ' ')

# pane이 2개 이상일 때만 모니터 pane 닫기
if [ "$PANE_COUNT" -ge 2 ]; then
    MONITOR_PANE=$(tmux list-panes -F '#{pane_id} #{pane_title}' | grep "agent-monitor" | head -1 | awk '{print $1}')
    if [ -n "$MONITOR_PANE" ]; then
        tmux kill-pane -t "$MONITOR_PANE" 2>/dev/null
    fi
fi
