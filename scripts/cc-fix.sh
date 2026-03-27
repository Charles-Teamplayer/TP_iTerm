#!/bin/bash
# cc-fix.sh — tmux -CC 크래시 복구
# raw %extended-output 라인이 노출될 때 CC 클라이언트를 재연결

LOG="$HOME/.claude/logs/cc-fix.log"
SESSION="${TMUX_SESSION:-claude-work}"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

# 세션별 프로세스 lock (동일 세션에 대한 동시 실행 방지)
LOCK_FILE="/tmp/.cc-fix-lock-${SESSION//[^a-zA-Z0-9]/_}"
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "cc-fix 이미 실행 중 (PID: $OLD_PID, session: $SESSION) — 스킵"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# auto-restore 실행 중이면 cc-fix 스킵 (복구 중 불필요한 창 생성 방지)
if [ -f "/tmp/.auto-restore.lock" ]; then
    RESTORE_PID=$(cat "/tmp/.auto-restore.lock" 2>/dev/null)
    if [ -n "$RESTORE_PID" ] && kill -0 "$RESTORE_PID" 2>/dev/null; then
        log "auto-restore 실행 중 — cc-fix 스킵 ($SESSION)"
        exit 0
    fi
fi

log "=== cc-fix 시작 ($SESSION) ==="

# CC 클라이언트 목록 확인
clients=$(tmux list-clients -t "$SESSION" -F "#{client_name}" 2>/dev/null)
if [ -z "$clients" ]; then
    log "CC 클라이언트 없음 — 바로 재attach"
else
    # 모든 CC 클라이언트 detach
    while IFS= read -r client; do
        log "detach: $client"
        tmux detach-client -t "$client" 2>/dev/null
    done <<< "$clients"
    log "전체 detach 완료, 2초 대기"
    sleep 2
fi

# 새 iTerm2 창으로 tmux -CC attach (TMUX 변수 unset 필수: 중첩 tmux 방지)
osascript -e "
tell application \"iTerm2\"
    activate
    set newWindow to (create window with default profile)
    delay 1
    tell current session of newWindow
        write text \"unset TMUX; tmux -CC attach -t $SESSION\"
    end tell
end tell
" 2>>"$LOG"

log "새 iTerm2 창에서 CC 재attach 실행"
log "=== cc-fix 완료 ==="
