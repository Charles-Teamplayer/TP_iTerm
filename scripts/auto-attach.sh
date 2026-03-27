#!/bin/bash
# auto-attach.sh: 부팅 후 iTerm2에 window-groups 기반 탭 생성
# LaunchAgent com.claude.auto-attach 에서 호출

LOG="$HOME/.claude/logs/auto-restore.log"
WINDOW_GROUPS="$HOME/.claude/window-groups.json"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-attach] $1" >> "$LOG"; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 중복 실행 방지 (PID 파일 기반)
ATTACH_LOCK="/tmp/.auto-attach.lock"
if [ -f "$ATTACH_LOCK" ]; then
    OLD_PID=$(cat "$ATTACH_LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "이미 auto-attach 실행 중 (PID: $OLD_PID) — 스킵"
        exit 0
    fi
fi
echo $$ > "$ATTACH_LOCK"
trap 'rm -f "$ATTACH_LOCK"' EXIT

FLAG_FILE="$HOME/.claude/logs/.auto-restore-done"

# BUG-FLAG-STALE fix: 현재 부팅 이후에 생성된 플래그만 유효 (이전 부팅 플래그 재사용 방지)
BOOT_TS=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
BOOT_TS=${BOOT_TS:-0}

# auto-restore.sh 완료 플래그를 기다림 (최대 3분)
log "auto-restore 플래그 대기 시작 (최대 180초, 부팅 이후=${BOOT_TS})"
WAITED=0
while [ $WAITED -lt 180 ]; do
    if [ -f "$FLAG_FILE" ]; then
        FLAG_TIME=$(cat "$FLAG_FILE" 2>/dev/null)
        NOW=$(date +%s)
        AGE=$((NOW - ${FLAG_TIME:-0}))
        # 플래그가 현재 부팅 이후에 생성된 것인지 확인 (이전 부팅 플래그 무시)
        if [ "${FLAG_TIME:-0}" -le "${BOOT_TS}" ]; then
            log "이전 부팅 플래그 감지 (FLAG=${FLAG_TIME}, BOOT=${BOOT_TS}) — 대기 계속"
            rm -f "$FLAG_FILE"  # 오래된 플래그 삭제 후 대기
        elif [ "$AGE" -lt 1800 ]; then
            log "auto-restore 완료 플래그 확인 (${AGE}초 전, 부팅 후 ${FLAG_TIME:-0}>${BOOT_TS}) — attach 시작"
            rm -f "$FLAG_FILE"
            break
        else
            log "플래그가 오래됨 (${AGE}초 전) — 스킵"
            exit 0
        fi
    fi
    sleep 10
    WAITED=$((WAITED + 10))
done

if [ $WAITED -ge 180 ]; then
    log "auto-restore 플래그 없음 (180초 대기 후) — 스킵"
    exit 0
fi

# tmux 세션 준비 대기
log "tmux 세션 준비 대기 (10초)"
sleep 10

# window-groups.json 확인
if [ ! -f "$WINDOW_GROUPS" ]; then
    log "window-groups.json 없음 — attach 스킵"
    exit 0
fi

# iTerm2 즉시 실행 (이미 실행 중이면 activate만, 미실행이면 시작)
log "iTerm2 시작/활성화 중..."
open -a iTerm 2>/dev/null || true

# iTerm2 프로세스가 올라올 때까지 최대 60초 대기
ITERM_READY=0
for i in $(seq 1 12); do
    if ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
        log "iTerm2 준비됨 (${i}번째 확인, $((i*5))초)"
        ITERM_READY=1
        break
    fi
    log "iTerm2 대기 중... (${i}/12)"
    sleep 5
done

if [ $ITERM_READY -eq 0 ]; then
    log "ERROR: iTerm2 60초 내 시작 실패 — 스킵"
    exit 1
fi

sleep 3  # 창 완전 초기화 대기

# window-groups.json에서 활성 그룹(isWaitingList=false) 읽기
GROUPS_JSON=$(python3 -c "
import json, sys
path = '$WINDOW_GROUPS'
try:
    groups = json.load(open(path))
    active = [g for g in groups if not g.get('isWaitingList', False)]
    for g in active:
        print(g['sessionName'])
except Exception as e:
    pass
" 2>/dev/null)

if [ -z "$GROUPS_JSON" ]; then
    log "활성 그룹 없음 — attach 스킵"
    exit 0
fi

# 각 그룹에 대해 iTerm2 창 + 탭 생성
while IFS= read -r SESSION_NAME; do
    [ -z "$SESSION_NAME" ] && continue

    # tmux 세션 존재 확인
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "$SESSION_NAME tmux 세션 없음 — 스킵"
        continue
    fi

    # tmux 창 목록 조회 (index|name)
    RAW_WINS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null)
    if [ -z "$RAW_WINS" ]; then
        log "$SESSION_NAME 창 없음 — 스킵"
        continue
    fi

    # AppleScript 생성 — command 파라미터 방식 (write text 불필요, 타이밍 무관)
    APPLE_SCRIPT=$(python3 << PYEOF
import sys

session = "$SESSION_NAME"
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

# monitor 제외한 실제 세션 탭만 생성
realPairs = [(idx, name) for idx, name in winPairs if name != 'monitor']

if not realPairs:
    sys.exit(0)

firstIdx, firstName = realPairs[0]
# Close Sessions On End=true 대비: tmux 종료 후에도 탭이 닫히지 않도록 exec zsh 추가
# /bin/bash -lc: login shell → homebrew PATH 포함, tmux 실패해도 zsh가 탭 유지
# linked session 방식: 각 탭이 독립적인 tmux 창 추적
# tmux attach-session -t session:N은 session 전체 current window를 변경하므로 사용 불가
firstLinked = f"{session}-v{firstIdx}"
firstCmd = f"/bin/bash -lc 'tmux has-session -t {firstLinked} 2>/dev/null || tmux new-session -d -s {firstLinked} -t {session} 2>/dev/null; tmux select-window -t {firstLinked}:{firstIdx} 2>/dev/null; tmux attach-session -t {firstLinked}; exec /bin/zsh -l'"

# BUG-ITERM-GROUPTABS fix: 단일 tell newWin 블록 + delay 1 (레퍼런스 불안정 방지)
# BUG-010 fix (auto-attach): try-on-error 추가 — 첫 창 실패 시 silent fail 방지
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
lines.append('        -- 창 생성 실패 로그 (iTerm2 미준비 또는 권한 오류)')
lines.append('    end try')
lines.append('end tell')

print('\n'.join(lines))
PYEOF
)

    if [ -z "$APPLE_SCRIPT" ]; then
        log "$SESSION_NAME AppleScript 생성 실패 — 스킵"
        continue
    fi

    log "$SESSION_NAME AppleScript 실행 시작"

    # osascript 실행 (stderr도 캡처)
    OSASCRIPT_ERR=$(osascript << __APPLES__ 2>&1
$APPLE_SCRIPT
__APPLES__
)
    OSASCRIPT_EXIT=$?

    if [ $OSASCRIPT_EXIT -eq 0 ]; then
        log "$SESSION_NAME iTerm2 창+탭 생성 완료 (window $OSASCRIPT_ERR)"
    else
        log "ERROR: $SESSION_NAME osascript 실패 (exit=$OSASCRIPT_EXIT): $OSASCRIPT_ERR"
    fi

    sleep 2  # 그룹 간 딜레이

done <<< "$GROUPS_JSON"

log "auto-attach 완료"
