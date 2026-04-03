#!/bin/bash
# auto-attach.sh: 부팅 후 iTerm2에 window-groups 기반 탭 생성
# LaunchAgent com.claude.auto-attach 에서 호출

LOG="$HOME/.claude/logs/auto-restore.log"
WINDOW_GROUPS="$HOME/.claude/window-groups.json"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-attach] $1" >> "$LOG"; }
# 로그 로테이션 (10000줄 초과 시 5000줄 유지)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 10000 ] 2>/dev/null; then
    tail -5000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null || true
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 중복 실행 방지 (PID 파일 기반)
# SEC-002 fix: set -C (noclobber) 원자적 쓰기로 TOCTOU race 방지 (auto-restore.sh 패턴과 일관성)
ATTACH_LOCK="/tmp/.auto-attach.lock"
if ! (set -C; echo $$ > "$ATTACH_LOCK") 2>/dev/null; then
    OLD_PID=$(cat "$ATTACH_LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "이미 auto-attach 실행 중 (PID: $OLD_PID) — 스킵"
        exit 0
    fi
    # 이전 프로세스 종료 후 재시도
    echo $$ > "$ATTACH_LOCK"
fi
trap 'rm -f "$ATTACH_LOCK"' EXIT

FLAG_FILE="$HOME/.claude/logs/.auto-restore-done"

# BUG-FLAG-STALE fix: 현재 부팅 이후에 생성된 플래그만 유효 (이전 부팅 플래그 재사용 방지)
# BUG-BOOT-TS-ZERO fix: LaunchAgent 초기 환경에서 sysctl 파싱 실패 시 retry 3회
BOOT_TS=""
for _bts_try in 1 2 3; do
    BOOT_TS=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
    [[ "$BOOT_TS" =~ ^[0-9]{9,}$ ]] && break
    sleep 2
done
BOOT_TS=${BOOT_TS:-0}

# BUG-180SEC fix: 180초 → 30초로 단축했으나, 실측 auto-restore 61초로 타임아웃 발생
# BUG-ATTACH-TIMEOUT fix: 30초 → 120초로 증가 (부팅 16창 복원 시 최대 90초 소요 관측)
log "auto-restore 플래그 대기 시작 (최대 120초, 부팅 이후=${BOOT_TS})"
WAITED=0
while [ $WAITED -lt 120 ]; do
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

if [ $WAITED -ge 120 ]; then
    log "auto-restore 플래그 없음 (120초 대기 후) — 스킵"
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

WELOG="$HOME/.claude/logs/window-events.log"

# orphan iTerm 창 정리: tmux/claude가 실행되지 않는 창(zsh 단독)을 닫음
# 방법: 각 iTerm 탭의 TTY에서 tmux/claude 프로세스 존재 여부로 판단
_SAFE_TTYS=""
# 활성 tmux 클라이언트 TTY 수집
_TMUX_CLI_TTYS=$(tmux list-clients -F '#{client_tty}' 2>/dev/null | sed 's|/dev/||' | tr '\n' ' ')
# claude 프로세스 TTY 수집
_CLAUDE_TTYS=$(ps -A -o tty=,comm= 2>/dev/null | awk '/claude$/{print $1}' | grep -v '??' | tr '\n' ' ')
_SAFE_TTYS="$_TMUX_CLI_TTYS $_CLAUDE_TTYS"

if ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
    # iTerm TTY 목록 수집 후 orphan 판단
    _ALL_ITERM_TTYS=$(osascript 2>/dev/null << 'OSEOF'
tell application "iTerm2"
    set _out to ""
    repeat with w in windows
        try
            set _t to current tab of w
            set _s to current session of _t
            set _tty to tty of _s
            if _tty is not "" then
                set _out to _out & _tty & " "
            end if
        end try
    end repeat
    return _out
end tell
OSEOF
    )
    _ORPHAN_TTYS=""
    for _itty in $_ALL_ITERM_TTYS; do
        _short=$(echo "$_itty" | sed 's|/dev/||')
        _procs=$(ps -t "$_itty" -o comm= 2>/dev/null | grep -vE '^(zsh|bash|sh|login|-zsh|-bash|login)$' | tr '\n' ',')
        if [ -z "$_procs" ]; then
            _ORPHAN_TTYS="$_ORPHAN_TTYS $_short"
        fi
    done
    if [ -n "$_ORPHAN_TTYS" ]; then
        _ORPHAN_COUNT=$(echo "$_ORPHAN_TTYS" | tr ' ' '\n' | grep -c '.')
        # AppleScript로 orphan TTY 창만 닫기
        # SEC-005: _ORPHAN_LIST는 TTY 경로만 포함 (/dev/ttysXXX 형식 — alphanumeric 전용)
        # awk가 이미 고정 포맷으로 가공하므로 인젝션 위험 낮음. 단, heredoc 비인용 유지 필수 (변수 확장 의도적)
        _ORPHAN_LIST=$(echo "$_ORPHAN_TTYS" | tr ' ' '\n' | grep -v '^$' | awk '/^[a-zA-Z0-9]+$/{print "\"/dev/" $0 "\""}' | tr '\n' ',')
        osascript 2>/dev/null << OSEOF2
tell application "iTerm2"
    set _orphanList to {${_ORPHAN_LIST%,}}
    set _closed to 0
    repeat with w in windows
        try
            set _t to current tab of w
            set _s to current session of _t
            set _tty to tty of _s
            if _orphanList contains _tty then
                close w
                set _closed to _closed + 1
            end if
        end try
    end repeat
end tell
OSEOF2
        log "orphan iTerm 창 ${_ORPHAN_COUNT}개 정리 완료 (TTY:${_ORPHAN_TTYS})"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [iterm-window] CLEANUP orphan=${_ORPHAN_COUNT} ttys=${_ORPHAN_TTYS}" >> "$WELOG"
    fi
fi

# iTerm2 즉시 실행 (이미 실행 중이면 activate만, 미실행이면 시작)
log "iTerm2 시작/활성화 중..."
open -a iTerm 2>/dev/null || true

# iTerm2 프로세스가 올라올 때까지 최대 90초 대기 (iter59: 60s→90s, 느린 부팅 대응)
ITERM_READY=0
for i in $(seq 1 18); do
    if ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
        log "iTerm2 준비됨 (${i}번째 확인, $((i*5))초)"
        ITERM_READY=1
        break
    fi
    log "iTerm2 대기 중... (${i}/18)"
    sleep 5
done

if [ $ITERM_READY -eq 0 ]; then
    log "ERROR: iTerm2 90초 내 시작 실패 — 스킵"
    exit 1
fi

sleep 3  # 창 완전 초기화 대기

# window-groups.json에서 활성 그룹(isWaitingList=false) 읽기
GROUPS_JSON=$(_AA_WG="$WINDOW_GROUPS" python3 -c "
import json, os
path = os.environ['_AA_WG']
try:
    with open(path) as _f:
        groups = json.load(_f)
    active = [g for g in groups if not g.get('isWaitingList', False)]
    for g in active:
        print(g['sessionName'])
except Exception:
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

    # BUG-ATTACH-DUP fix v3: linked 세션 존재만으로도 중복 판단
    # (클라이언트 연결 여부만 보면 iTerm2 탭 로딩 중 타이밍 race로 dedup 실패 → 창 중복 생성)
    _LINKED_EXISTS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c "^${SESSION_NAME}-v" || echo 0)
    _LINKED_EXISTS=${_LINKED_EXISTS:-0}
    _MAIN_CLI=$(tmux list-clients -t "$SESSION_NAME" -F "#{window_name}" 2>/dev/null | grep -vcxF "monitor" | tr -d ' ')
    _MAIN_CLI=${_MAIN_CLI:-0}
    _LINKED_CLI=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${SESSION_NAME}-v" | while read -r ls; do tmux list-clients -t "$ls" -F "#{window_name}" 2>/dev/null; done | grep -vcxF "monitor" | tr -d ' ')
    _LINKED_CLI=${_LINKED_CLI:-0}
    if [ $(( _MAIN_CLI + _LINKED_CLI + _LINKED_EXISTS )) -gt 0 ]; then
        log "$SESSION_NAME 이미 존재/연결됨 (linked_sessions=${_LINKED_EXISTS}, main_cli=${_MAIN_CLI}, linked_cli=${_LINKED_CLI}) — 중복 창 생성 스킵"
        continue
    fi

    # tmux 창 목록 조회 (index|name)
    RAW_WINS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null)
    if [ -z "$RAW_WINS" ]; then
        log "$SESSION_NAME 창 없음 — 스킵"
        continue
    fi

    # AppleScript 생성 — command 파라미터 방식 (write text 불필요, 타이밍 무관)
    APPLE_SCRIPT=$(CCFIX_SESSION="$SESSION_NAME" CCFIX_RAW_WINS="$RAW_WINS" python3 << 'PYEOF'
import sys, os

session = os.environ['CCFIX_SESSION']
raw = os.environ['CCFIX_RAW_WINS']

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
# iter59 MEDIUM-05: AppleScript 문자열 이스케이프 (세션명에 \ 또는 " 포함 시 방어)
def as_escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')
safe_session = as_escape(session)
firstLinked = f"{session}-v{firstIdx}"
safe_firstLinked = as_escape(firstLinked)
firstCmd = f"/bin/bash -lc 'export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH; tmux has-session -t {safe_firstLinked} 2>/dev/null || tmux new-session -d -s {safe_firstLinked} -t {safe_session} 2>/dev/null; tmux select-window -t {safe_firstLinked}:{firstIdx} 2>/dev/null; tmux -CC attach-session -t {safe_firstLinked}; exec /bin/zsh -l'"

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
        safe_linkedName = as_escape(linkedName)
        cmd = f"/bin/bash -lc 'export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH; tmux has-session -t {safe_linkedName} 2>/dev/null || tmux new-session -d -s {safe_linkedName} -t {safe_session} 2>/dev/null; tmux select-window -t {safe_linkedName}:{winIdx} 2>/dev/null; tmux -CC attach-session -t {safe_linkedName}; exec /bin/zsh -l'"
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
        # BUG-001 fix: monitor-only(실제 탭 없음)와 진짜 실패 구분
        NON_MON=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -vxF monitor | wc -l | tr -d ' ')
        if [ "${NON_MON:-0}" -eq 0 ]; then
            log "$SESSION_NAME monitor 전용 세션 — iTerm 탭 생성 스킵 (정상)"
        else
            log "$SESSION_NAME AppleScript 생성 실패 — 스킵"
        fi
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
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [iterm-window] CREATE session=$SESSION_NAME result=$OSASCRIPT_ERR" >> "$WELOG"
    else
        log "ERROR: $SESSION_NAME osascript 실패 (exit=$OSASCRIPT_EXIT): $OSASCRIPT_ERR"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [iterm-window] CREATE_FAIL session=$SESSION_NAME error=$OSASCRIPT_ERR" >> "$WELOG"
    fi

    sleep 2  # 그룹 간 딜레이

done <<< "$GROUPS_JSON"

log "auto-attach 완료"
