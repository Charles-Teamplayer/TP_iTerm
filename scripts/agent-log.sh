#!/bin/bash
# Agent 활동 로그 기록
# PreToolUse/PostToolUse(Agent) hook에서 호출

ACTION="${1:-start}"
PROJECT="$(basename "$PWD")"
LOG="$HOME/.claude/logs/agent-activity.log"

mkdir -p "$(dirname "$LOG")"

# 로그 로테이션 (5000줄)
if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 5000 ] 2>/dev/null; then
    tail -2500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null
fi

case "$ACTION" in
    start)
        echo "[$(date '+%H:%M:%S')] ▶ Agent 시작 | $PROJECT" >> "$LOG"
        ;;
    end)
        echo "[$(date '+%H:%M:%S')] ✓ Agent 완료 | $PROJECT" >> "$LOG"
        echo "" >> "$LOG"
        ;;
esac
