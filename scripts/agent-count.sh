#!/bin/bash
# Agent 카운터 관리
# 사용법: agent-count.sh [up|down|show]
COUNT_FILE="/tmp/.agent-running-count"

case "${1:-show}" in
    up)
        count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
        echo $((count + 1)) > "$COUNT_FILE"
        ;;
    down)
        count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
        new=$((count - 1))
        [ $new -lt 0 ] && new=0
        echo $new > "$COUNT_FILE"
        ;;
    show)
        count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo " 🤖 ${count} agents"
        fi
        ;;
esac
