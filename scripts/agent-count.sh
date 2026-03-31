#!/bin/bash
# Agent 카운터 관리
# 사용법: agent-count.sh [up|down|show]
COUNT_FILE="/tmp/.agent-running-count"
LOCK_FILE="/tmp/.agent-count.lock"

# macOS: flock(1) 없음 → Python fcntl.flock() 사용
_atomic_update() {
    local delta="$1"
    _COUNT_FILE="$COUNT_FILE" _LOCK_FILE="$LOCK_FILE" _DELTA="$delta" python3 - <<'EOF'
import os, fcntl

count_path = os.environ['_COUNT_FILE']
lock_path  = os.environ['_LOCK_FILE']
delta      = int(os.environ['_DELTA'])

with open(lock_path, 'w') as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    try:
        val = int(open(count_path).read().strip()) if os.path.exists(count_path) else 0
    except (ValueError, OSError):
        val = 0
    val = max(0, val + delta)
    with open(count_path, 'w') as cf:
        cf.write(str(val) + '\n')
    fcntl.flock(lf, fcntl.LOCK_UN)
EOF
}

case "${1:-show}" in
    up)
        _atomic_update 1
        ;;
    down)
        _atomic_update -1
        ;;
    show)
        count=$(cat "$COUNT_FILE" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo " 🤖 ${count} agents"
        fi
        ;;
esac
