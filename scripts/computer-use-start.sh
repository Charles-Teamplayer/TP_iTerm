#!/bin/bash
# Computer Use 전용 세션 시작
# autoRestart가 remote-control 탭 생성 시 호출
OVERLAY_DIR="/Users/teample.casper/claude/TP_skills/dummy-overlay"

# M+N 상태 서버 시작 (이미 실행 중이면 무시)
_CS_OD="$OVERLAY_DIR" python3 -c "
import sys, os, threading
sys.path.insert(0, os.environ['_CS_OD'])
import mn_status_server as srv
try:
    srv.start()
except:
    pass
" 2>/dev/null &

# 오버레이 시작
bash "$OVERLAY_DIR/start.sh"
echo "[M+N] Computer Use 세션 시작됨"
