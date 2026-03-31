#!/bin/bash
# M+N Computer Use Overlay trigger
# Called from PreToolUse hook when tool=computer or Bash contains screencapture

OVERLAY_DIR="/Users/teample.casper/claude/TP_skills/dummy-overlay"
ACTION="${1:-start}"  # start | stop | update

case "$ACTION" in
  start)
    # Check if overlay already running
    if ! pgrep -f "overlay_runner" > /dev/null; then
        # Update status server first
        _CU_OD="$OVERLAY_DIR" python3 -c "
import sys, os; sys.path.insert(0, os.environ['_CU_OD'])
import mn_status_server as srv
srv.update(task='Remote Control 세션', log='▶ Computer Use 시작')
" 2>/dev/null
        bash "$OVERLAY_DIR/start.sh"
    fi
    ;;
  stop)
    _CU_OD="$OVERLAY_DIR" python3 -c "
import sys, os, threading, time
sys.path.insert(0, os.environ['_CU_OD'])
import mn_status_server as srv
def _cd():
    for r in range(300, 0, -1):
        srv.update(countdown=r)
        time.sleep(1)
    srv.update(countdown=0)
    import subprocess
    subprocess.run(['bash', os.path.join(os.environ['_CU_OD'], 'kill.sh')])
threading.Thread(target=_cd, daemon=False).start()
" 2>/dev/null &
    ;;
  update)
    # $2=agent $3=task $4=progress
    _CU_OD="$OVERLAY_DIR" _CU_AGENT="${2:-}" _CU_TASK="${3:-}" _CU_PROG="${4:-50}" python3 -c "
import sys, os; sys.path.insert(0, os.environ['_CU_OD'])
import mn_status_server as srv
srv.update(agent=os.environ.get('_CU_AGENT',''), agent_task=os.environ.get('_CU_TASK',''), agent_progress=int(os.environ.get('_CU_PROG','50') or 50), agent_status='ACTIVE')
" 2>/dev/null
    ;;
esac
