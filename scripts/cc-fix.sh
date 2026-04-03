#!/bin/bash
# cc-fix.sh — iTerm 클라이언트 없을 때 auto-restore --force 위임
# watchdog에서 호출. Apply Now와 동일한 코드 경로 사용.

LOG="$HOME/.claude/logs/cc-fix.log"
SESSION="${TMUX_SESSION:-claude-work}"

log() { echo "[$(date '+%H:%M:%S')] [$SESSION] $1" >> "$LOG"; }

# 로그 로테이션 (20000줄 초과 시 10000줄 유지)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 20000 ] 2>/dev/null; then
    tail -10000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null || true
fi

# 전역 프로세스 lock (중복 실행 방지)
LOCK_FILE="/tmp/.cc-fix-lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt 600 ]; then
        rm -f "$LOCK_FILE"
        log "오래된 lock 파일 삭제 (age=${LOCK_AGE}s)"
    else
        OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            log "cc-fix 이미 실행 중 (PID: $OLD_PID) — 스킵"
            exit 0
        else
            rm -f "$LOCK_FILE"
            log "stale PID lock 삭제 (PID=$OLD_PID)"
        fi
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# auto-restore 실행 중이면 스킵
if [ -f "/tmp/.auto-restore.lock" ]; then
    RESTORE_PID=$(cat "/tmp/.auto-restore.lock" 2>/dev/null)
    if [ -n "$RESTORE_PID" ] && kill -0 "$RESTORE_PID" 2>/dev/null; then
        log "auto-restore 실행 중 — cc-fix 스킵"
        exit 0
    fi
fi

# auto-attach 실행 중이면 스킵
if [ -f "/tmp/.auto-attach.lock" ]; then
    ATTACH_PID=$(cat "/tmp/.auto-attach.lock" 2>/dev/null)
    if [ -n "$ATTACH_PID" ] && kill -0 "$ATTACH_PID" 2>/dev/null; then
        log "auto-attach 실행 중 — cc-fix 스킵"
        exit 0
    fi
fi

# 부팅 직후 grace period: auto-restore-done 플래그 최근 5분 내면 auto-attach에 위임
RESTORE_DONE_FLAG="$HOME/.claude/logs/.auto-restore-done"
if [ -f "$RESTORE_DONE_FLAG" ]; then
    BOOT_FLAG_TIME=$(cat "$RESTORE_DONE_FLAG" 2>/dev/null || echo "0")
    AGE_GRACE=$(( $(date +%s) - ${BOOT_FLAG_TIME:-0} ))
    if [ "$AGE_GRACE" -lt 300 ]; then
        log "부팅 직후 grace (${AGE_GRACE}초 < 300) — auto-attach에 위임, cc-fix 스킵"
        exit 0
    fi
fi

# iTerm2 미실행이면 스킵 (부팅 시 auto-attach 담당)
if ! ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
    log "iTerm2 미실행 — 스킵"
    exit 0
fi

# 트리거 세션에 클라이언트 이미 있으면 스킵
CLIENT_COUNT=$(tmux list-clients -t "$SESSION" -F "#{client_name}" 2>/dev/null | wc -l | tr -d ' ')
if [ "${CLIENT_COUNT:-0}" -gt 0 ]; then
    log "클라이언트 이미 있음 (${CLIENT_COUNT}개) — 스킵"
    exit 0
fi

log "=== cc-fix: auto-restore --force 위임 ==="
bash "$HOME/.claude/scripts/auto-restore.sh" --force
log "=== cc-fix 완료 ==="
