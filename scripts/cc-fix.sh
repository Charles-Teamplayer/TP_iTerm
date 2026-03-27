#!/bin/bash
# cc-fix.sh — tmux CC 클라이언트 없을 때 linked session 기반 iTerm 탭 재생성
# watchdog에서 호출: TMUX_SESSION=<session> bash cc-fix.sh

LOG="$HOME/.claude/logs/cc-fix.log"
SESSION="${TMUX_SESSION:-claude-work}"

log() { echo "[$(date '+%H:%M:%S')] [$SESSION] $1" >> "$LOG"; }

# 세션별 프로세스 lock
LOCK_FILE="/tmp/.cc-fix-lock-${SESSION//[^a-zA-Z0-9]/_}"
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "cc-fix 이미 실행 중 (PID: $OLD_PID) — 스킵"
        exit 0
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

log "=== cc-fix 시작 ==="

# 이중 체크: 실제로 클라이언트 없는지 재확인
CLIENT_COUNT=$(tmux list-clients -t "$SESSION" -F "#{client_name}" 2>/dev/null | wc -l | tr -d ' ')
if [ "${CLIENT_COUNT:-0}" -gt 0 ]; then
    log "클라이언트 이미 있음 (${CLIENT_COUNT}개) — 스킵"
    exit 0
fi

# tmux 세션 존재 확인
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "tmux 세션 없음 — 스킵"
    exit 0
fi

# tmux 창 목록 조회 (monitor 제외)
RAW_WINS=$(tmux list-windows -t "$SESSION" -F '#{window_index}|#{window_name}' 2>/dev/null)
if [ -z "$RAW_WINS" ]; then
    log "창 없음 — 스킵"
    exit 0
fi

# iTerm2 실행 중인지 확인 (미실행 시 auto-attach가 부팅 때 담당)
if ! ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
    log "iTerm2 미실행 — 스킵 (부팅 시 auto-attach 담당)"
    exit 0
fi

# AppleScript 생성 — auto-attach.sh와 동일한 linked session 방식
APPLE_SCRIPT=$(python3 << PYEOF
import sys

session = "$SESSION"
raw = """$RAW_WINS"""

winPairs = []
for line in raw.strip().split('\n'):
    if not line.strip():
        continue
    parts = line.split('|', 1)
    if len(parts) == 2:
        try:
            winPairs.append((int(parts[0]), parts[1]))
        except ValueError:
            pass

# monitor 제외한 실제 탭만 생성
realPairs = [(idx, name) for idx, name in winPairs if name != 'monitor']

if not realPairs:
    sys.exit(0)

firstIdx, firstName = realPairs[0]
firstLinked = f"{session}-v{firstIdx}"
firstCmd = f"/bin/bash -lc 'tmux has-session -t {firstLinked} 2>/dev/null || tmux new-session -d -s {firstLinked} -t {session} 2>/dev/null; tmux select-window -t {firstLinked}:{firstIdx} 2>/dev/null; tmux attach-session -t {firstLinked}; exec /bin/zsh -l'"

# BUG-ITERM-GROUPTABS fix: 단일 tell newWin 블록 + delay 1
# BUG-010 fix (cc-fix): try-on-error 추가 — 첫 창 실패 시 전체 탭 생성 포기 방지
lines = [
    'tell application "iTerm2"',
    '    activate',
    '    try',
    f'        set newWin to (create window with default profile command "{firstCmd}")',
    '        delay 1',
]

if realPairs[1:]:
    lines.append('        tell newWin')
    for (winIdx, name) in realPairs[1:]:
        linkedName = f"{session}-v{winIdx}"
        cmd = f"/bin/bash -lc 'tmux has-session -t {linkedName} 2>/dev/null || tmux new-session -d -s {linkedName} -t {session} 2>/dev/null; tmux select-window -t {linkedName}:{winIdx} 2>/dev/null; tmux attach-session -t {linkedName}; exec /bin/zsh -l'"
        lines.append('            delay 0.5')
        lines.append(f'            create tab with default profile command "{cmd}"')
    lines.append('        end tell')

lines.append('    on error errMsg')
lines.append('        -- 창 생성 실패 (iTerm2 미준비 또는 권한 오류)')
lines.append('    end try')
lines.append('end tell')
print('\n'.join(lines))
PYEOF
)

if [ -z "$APPLE_SCRIPT" ]; then
    log "AppleScript 생성 실패 — 스킵"
    exit 1
fi

TAB_COUNT=$(echo "$RAW_WINS" | grep -v '^$' | grep -cv 'monitor' || echo 0)
log "linked session 기반 iTerm 창+탭 생성 시작 (${TAB_COUNT}개 탭)"

OSASCRIPT_ERR=$(osascript << __APPLES__ 2>&1
$APPLE_SCRIPT
__APPLES__
)
OSASCRIPT_EXIT=$?

if [ $OSASCRIPT_EXIT -eq 0 ]; then
    log "iTerm 창+탭 생성 완료"
else
    log "ERROR: osascript 실패 (exit=$OSASCRIPT_EXIT): $OSASCRIPT_ERR"
fi

log "=== cc-fix 완료 ==="
