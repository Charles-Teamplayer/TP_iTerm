#!/bin/bash
# Agent 실행 시 tmux pane 자동 분할
# PreToolUse(Agent) hook에서 호출

PROJECT="${1:-$(basename "$PWD")}"
AGENT_LOG="$HOME/.claude/logs/agent-activity.log"

# tmux 안에서 실행 중인지 확인
if [ -z "$TMUX" ]; then
    exit 0
fi

CURRENT_PANE=$(tmux display-message -p '#{pane_id}')
PANE_COUNT=$(tmux list-panes | wc -l | tr -d ' ')

# 이미 분할되어 있으면 스킵 (2개 이상 pane)
if [ "$PANE_COUNT" -ge 2 ]; then
    # 기존 모니터 pane에 업데이트만
    MONITOR_PANE=$(tmux list-panes -F '#{pane_id} #{pane_title}' | grep "agent-monitor" | head -1 | awk '{print $1}')
    if [ -n "$MONITOR_PANE" ]; then
        tmux send-keys -t "$MONITOR_PANE" "" 2>/dev/null
    fi
    exit 0
fi

# 오른쪽 30% 크기로 pane 분할
tmux split-window -h -l 30% -t "$CURRENT_PANE" \
    "printf '\\033]2;agent-monitor\\033\\\\'; echo '━━━ Agent Monitor ━━━'; echo '프로젝트: $PROJECT'; echo '시작: $(date \"+%H:%M:%S\")'; echo ''; echo '에이전트 활동 대기 중...'; echo ''; tail -f \"$AGENT_LOG\" 2>/dev/null || (echo 'Waiting for agent activity...'; sleep 300)"

# 원래 pane으로 포커스 복귀
tmux select-pane -t "$CURRENT_PANE"
