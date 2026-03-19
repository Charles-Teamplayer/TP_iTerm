#!/bin/bash
# auto-attach.sh: 부팅 후 iTerm2를 tmux claude-work에 자동 연결
# LaunchAgent com.claude.auto-attach 에서 호출
# auto-restore.sh가 tmux 세션을 생성한 뒤 iTerm2 연결 담당

LOG="$HOME/.claude/logs/auto-restore.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-attach] $1" >> "$LOG"; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 부팅 직후(5분 이내)가 아니면 스킵 (수동 launchctl bootstrap 오작동 방지)
UP_ELAPSED=$(python3 -c "
import subprocess, re, time
try:
    out = subprocess.check_output(['sysctl','-n','kern.boottime'], text=True)
    m = re.search(r'sec = (\d+)', out)
    if m:
        print(int(time.time()) - int(m.group(1)))
except:
    pass
" 2>/dev/null)
if [ -n "$UP_ELAPSED" ] && [ "$UP_ELAPSED" -gt 300 ]; then
    log "부팅 후 ${UP_ELAPSED}초 경과 — 부팅 직후가 아니므로 스킵"
    exit 0
fi

log "auto-attach 대기 시작 (90초, 부팅 후 ${UP_ELAPSED:-?}초)"
sleep 90  # auto-restore.sh(최대 65초 delay) + 여유 25초

# claude-work 세션 없으면 종료
if ! tmux has-session -t claude-work 2>/dev/null; then
    log "claude-work 세션 없음 — attach 스킵"
    exit 0
fi

log "claude-work 세션 확인됨 — iTerm2 attach 시작"

# iTerm2 실행 대기 (최대 60초)
for i in $(seq 1 12); do
    if ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
        break
    fi
    log "iTerm2 대기 중... (${i}/12)"
    sleep 5
done

# iTerm2 미실행 시 직접 실행
if ! ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
    log "iTerm2 미실행 — open으로 실행"
    open -a iTerm 2>/dev/null || true
    sleep 5
fi

# AppleScript로 tmux -CC attach
cat > /tmp/magi-attach.scpt << 'EOF'
tell application "iTerm2"
    activate
    create window with default profile command "tmux -CC attach -t claude-work"
end tell
EOF

osascript /tmp/magi-attach.scpt 2>/dev/null && \
    log "iTerm2 tmux -CC attach 완료" || \
    log "ERROR: osascript 실패"
