#!/bin/bash
# Agent 카운터 관리
# 사용법: agent-count.sh [up|down|show]
COUNT_FILE="/tmp/.agent-running-count"
LOCK_FILE="/tmp/.agent-count.lock"

case "${1:-show}" in
    up)
        (
            flock -x 9
            count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
            echo $((count + 1)) > "$COUNT_FILE"
        ) 9>"$LOCK_FILE"
        ;;
    down)
        (
            flock -x 9
            count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
            new=$((count - 1))
            [ $new -lt 0 ] && new=0
            echo $new > "$COUNT_FILE"
        ) 9>"$LOCK_FILE"
        ;;
    show)
        count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo " 🤖 ${count} agents"
        fi
        ;;
esac
