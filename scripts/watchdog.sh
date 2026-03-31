#!/bin/bash
# Claude Code Watchdog (VERDANDI-5 검증 + 민수 구현)
# LaunchAgent KeepAlive로 보호됨

LOG_FILE="$HOME/.claude/logs/watchdog.log"
REGISTRY="$HOME/.claude/active-sessions.json"
RESTART_COOLDOWN=60  # 같은 프로젝트 재시작 간 최소 대기시간(초)
RESTART_LOG="$HOME/.claude/logs/restart-history.log"
CRASH_COUNT_DIR="$HOME/.claude/crash-counts"  # 연속 크래시 카운터 (타임스탬프 기반 만료)
CRASH_MAX=5  # 이 횟수 초과 시 intentional-stop 등록
CRASH_COUNT_TTL=86400  # 24시간 이상된 카운터 자동 만료
mkdir -p "$CRASH_COUNT_DIR"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    # 로그 로테이션 (50000줄 초과 시)
    if [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 50000 ] 2>/dev/null; then
        tail -25000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
    fi
}

# 디스크 여유 공간 체크 (MB)
disk_free_mb() {
    df -k "$HOME" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

# 원자적 파일 쓰기 (디스크 부족 시 스킵)
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.$$"
    local free_mb
    free_mb=$(disk_free_mb)
    if [ "${free_mb:-0}" -lt 200 ]; then
        return 0  # 디스크 부족 시 조용히 스킵
    fi
    echo "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

# stderr.log 자체 로테이션 (10MB 초과 시)
rotate_stderr_log() {
    local stderr_log="$HOME/.claude/logs/watchdog.stderr.log"
    if [ -f "$stderr_log" ]; then
        local size
        size=$(stat -f%z "$stderr_log" 2>/dev/null || echo 0)
        if [ "${size:-0}" -gt 10485760 ]; then  # 10MB
            > "$stderr_log"
        fi
    fi
}

notify() {
    local msg="$1"
    local is_critical="${2:-0}"
    local icon="${3:-bell.fill}"
    local title="${4:-MAGI+NORN Watchdog}"
    # 최근 이벤트 파일 저장 (상세 확인용)
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" > /tmp/watchdog-latest-event.txt
    tail -30 "$LOG_FILE" 2>/dev/null >> /tmp/watchdog-latest-event.txt
    # MAGI-Restore-App 토스트 큐에 추가
    local queue_file="/tmp/magi-toast.json"
    local safe_title="${title//\"/\\\"}"
    local safe_msg="${msg//\"/\\\"}"
    local safe_icon="${icon//\"/\\\"}"
    local new_entry="{\"title\":\"${safe_title}\",\"message\":\"${safe_msg}\",\"icon\":\"${safe_icon}\"}"
    if [ -f "$queue_file" ]; then
        # 기존 배열에 append
        local existing
        existing=$(cat "$queue_file" 2>/dev/null)
        if [[ "$existing" == \[*\] ]]; then
            # 마지막 ] 제거 후 새 항목 추가
            local trimmed="${existing%]}"
            if [ "$trimmed" = "[" ]; then
                echo "[${new_entry}]" > "$queue_file"
            else
                echo "${trimmed},${new_entry}]" > "$queue_file"
            fi
        else
            echo "[${new_entry}]" > "$queue_file"
        fi
    else
        echo "[${new_entry}]" > "$queue_file"
    fi
}

# --health-check 플래그: 상태 출력 후 즉시 종료 (무한루프 방지)
if [ "${1:-}" = "--health-check" ]; then
    WPID=$(ps -A -o pid=,args= | grep watchdog.sh | grep -v grep | grep -v health-check | awk '{print $1}' | head -1)
    echo "[health-check] watchdog PID: ${WPID:-없음}"
    echo "[health-check] 보호 PIDs: $(cat "$HOME/.claude/protected-claude-pids" 2>/dev/null | tr '\n' ',')"
    echo "[health-check] window-groups: $(python3 -c "
import json,os
p=os.path.expanduser('~/.claude/window-groups.json')
if os.path.exists(p):
    with open(p) as _f: raw=json.load(_f)
else:
    raw=[]
g=[x for x in raw if not x.get('isWaitingList')]
print([x['sessionName'] for x in g])
" 2>/dev/null)"
    echo "[health-check] 마지막 로그: $(tail -1 "$LOG_FILE" 2>/dev/null)"
    exit 0
fi

# Watchdog 중복실행 방지 (self-lock)
WATCHDOG_LOCK="/tmp/.watchdog.lock"
if [ -f "$WATCHDOG_LOCK" ]; then
    OLD_WD_PID=$(cat "$WATCHDOG_LOCK" 2>/dev/null)
    if [ -n "$OLD_WD_PID" ] && kill -0 "$OLD_WD_PID" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Watchdog 이미 실행 중 (PID: $OLD_WD_PID) — 종료" >> "$LOG_FILE"
        exit 0
    fi
fi
echo $$ > "$WATCHDOG_LOCK"
trap 'rm -f "$WATCHDOG_LOCK"' EXIT

# 환경변수 로드 (.zshrc source 금지: iTerm2 integration/conda init 부작용 방지)
# auto-restore.sh와 동일한 방식 — PATH만 직접 설정
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/opt/homebrew/sbin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
unset CLAUDECODE

log "=== Watchdog 시작 (PID: $$) ==="

# Watchdog 재시작 시 오래된(24h+) crash-count만 정리 (최근 카운터는 보존 → 크래시 루프 방지)
NOW_INIT=$(date +%s)
for cf in "$CRASH_COUNT_DIR"/*; do
    [ ! -f "$cf" ] && continue
    CF_TS=$(cut -d'|' -f2 "$cf" 2>/dev/null || echo 0)
    if [ $(( NOW_INIT - ${CF_TS:-0} )) -gt "$CRASH_COUNT_TTL" ]; then
        rm -f "$cf"
    fi
done
log "Crash-count 정리 완료 (24h+ 만료)"

# iter59: orphan tab_focus_status.py 프로세스 정리 (disabled 스크립트 잔재, tab-focus-monitor.sh로 대체됨)
ORPHAN_TFP=$(pgrep -f "tab_focus_status.py" 2>/dev/null | tr '\n' ' ' | xargs)
if [ -n "$ORPHAN_TFP" ]; then
    echo "$ORPHAN_TFP" | tr ' ' '\n' | xargs -I{} kill -15 {} 2>/dev/null || true
    log "orphan tab_focus_status.py 정리: PIDs $ORPHAN_TFP"
fi

# BUG-003 fix: watchdog 시작 시 고아 linked sessions 초기 정리 (15분 이상 + 클라이언트 없음)
# 부팅/재시작 후 이전 linked sessions 누적 방지
log "linked session 초기 정리 시작 (15분+ 클라이언트 없음)"
tmux list-sessions -F '#{session_name}|#{session_created}' 2>/dev/null | grep -E '.*-v[0-9]+\|' | while IFS='|' read -r lsname lscreated; do
    CLIENT_COUNT_INIT=$(tmux list-clients -t "$lsname" -F "#{client_name}" 2>/dev/null | wc -l | tr -d ' ')
    AGE_INIT=$(( NOW_INIT - ${lscreated:-0} ))
    if [ "${CLIENT_COUNT_INIT:-0}" -eq 0 ] && [ "$AGE_INIT" -gt 900 ]; then
        tmux kill-session -t "$lsname" 2>/dev/null && log "초기 정리: $lsname (${AGE_INIT}초 경과, 클라이언트 없음)"
    fi
done
# 주기 정리 타임스탬프 초기화 (watchdog 재시작 후 즉시 주기 정리 트리거 방지)
echo "$NOW_INIT" > "/tmp/.linked-cleanup-last"

# 메인 루프
while true; do
    # 1. 레지스트리 기반 크래시 감지
    # BUG-010 fix: auto-restore 실행 중에는 crash-detect 스킵 (부팅 시 race condition 방지)
    RESTORE_LOCK="/tmp/.auto-restore.lock"
    RESTORE_ACTIVE=false
    if [ -f "$RESTORE_LOCK" ]; then
        R_PID=$(cat "$RESTORE_LOCK" 2>/dev/null)
        [ -n "$R_PID" ] && kill -0 "$R_PID" 2>/dev/null && RESTORE_ACTIVE=true
    fi
    if [ -f "$REGISTRY" ] && [ "$RESTORE_ACTIVE" = "false" ]; then
        CRASHED=$(bash "$HOME/.claude/scripts/session-registry.sh" crash-detect 2>/dev/null | grep "CRASH DETECTED" || true)

        if [ -n "$CRASHED" ]; then
            log "CRASH DETECTED: $CRASHED"
            notify "Claude Code 크래시 감지! 자동 재시작 중..." 1 "exclamationmark.triangle.fill"

            # Notion에 크래시 기록
            if [ -n "$NOTION_API_KEY" ]; then
                # 크래시된 각 프로젝트에 대해 기록
                echo "$CRASHED" | while IFS= read -r line; do
                    PROJECT=$(echo "$line" | sed -n 's/.*CRASH DETECTED: \(.*\) (PID:.*/\1/p')
                    PROJECT="${PROJECT:-unknown}"
                    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
                        "$PROJECT" "Crash Recovery" "프로세스 비정상 종료 감지 - 자동 재시작" 2>/dev/null || true
                done
            fi

            # 크래시된 세션의 탭에 ⚪🔴 깜빡임 표시
            echo "$CRASHED" | while IFS= read -r line; do
                CRASH_PROJECT=$(echo "$line" | sed -n 's/.*CRASH DETECTED: \(.*\) (PID:.*/\1/p')
                CRASH_PROJECT="${CRASH_PROJECT:-unknown}"
                CRASH_TTY=$(echo "$line" | sed -n 's/.*TTY: \([^ ,]*\).*/\1/p')
                # TAB_TTY 주입으로 LaunchAgent 컨텍스트에서도 정확한 TTY에 색상 씀
                if [ -n "$CRASH_TTY" ]; then
                    TAB_TTY="/dev/${CRASH_TTY}" bash "$HOME/.claude/scripts/tab-status.sh" crashed "$CRASH_PROJECT" &
                else
                    bash "$HOME/.claude/scripts/tab-status.sh" crashed "$CRASH_PROJECT" &
                fi
            done

            # 크래시된 세션 자동 재시작 (P0 수정: watchdog이 직접 복구)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $CRASHED" >> "$RESTART_LOG"
            # iter59: restart-history.log 로테이션 (10000줄 초과 시 5000줄 유지)
            if [ "$(wc -l < "$RESTART_LOG" 2>/dev/null)" -gt 10000 ] 2>/dev/null; then
                tail -5000 "$RESTART_LOG" > "${RESTART_LOG}.tmp" && mv "${RESTART_LOG}.tmp" "$RESTART_LOG" 2>/dev/null || true
            fi

            # BUG-D fix: pipe → heredoc (subshell 변수 손실 방지, SESSION_JUST_CREATED 공유)
            # BUG-C fix: 세션별 REORDER 추적 (루프 내 중복 REORDER → 루프 후 1회 실행)
            SESSIONS_TO_REORDER=""
            while IFS= read -r line; do
                SESSION_JUST_CREATED=false  # 매 이터레이션 초기화 (early-continue 후 carryover 방지)
                INIT_WIN_ID=""              # iter56: 매 이터레이션 초기화 (carryover 방지)
                RESTART_PROJECT=$(echo "$line" | sed -n 's/.*CRASH DETECTED: \(.*\) (PID:.*/\1/p')
                [ -z "$RESTART_PROJECT" ] && continue

                # cooldown 체크 (같은 프로젝트 60초 내 재시작 방지)
                LAST_RESTART=$(grep "$RESTART_PROJECT" "$RESTART_LOG" 2>/dev/null | tail -1 | sed 's/\[//' | sed 's/\].*//')
                if [ -n "$LAST_RESTART" ]; then
                    LAST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LAST_RESTART" +%s 2>/dev/null || echo 0)
                    NOW_EPOCH=$(date +%s)
                    if [ $((NOW_EPOCH - LAST_EPOCH)) -lt $RESTART_COOLDOWN ]; then
                        log "SKIP restart $RESTART_PROJECT (cooldown ${RESTART_COOLDOWN}s)"
                        continue
                    fi
                fi

                # activated-sessions.json에서 프로젝트명으로 경로 조회
                # window 이름 = 디렉토리 basename (= RESTART_PROJECT)
                PROJ_PATH=$(python3 -c "
import json, os, sys, re
name = sys.argv[1]
def normalize(s):
    return re.sub(r'[ _]+', '_', s).lower()
norm = normalize(name)
path = os.path.expanduser('~/.claude/activated-sessions.json')
for candidate in [path, path + '.bak']:
    try:
        with open(candidate) as _cf:
            data = json.load(_cf)
        for p in data.get('activated', []):
            bn = os.path.basename(p)
            # 정확 매칭 우선, 그 다음 공백↔밑줄 정규화 비교
            if bn == name or normalize(bn) == norm:
                print(p)
                sys.exit(0)
    except Exception:
        continue
" "$RESTART_PROJECT" 2>/dev/null)
                WINDOW_NAME="$RESTART_PROJECT"

                if [ -z "$PROJ_PATH" ] || [ ! -d "$PROJ_PATH" ]; then
                    log "SKIP restart: $RESTART_PROJECT not in activated-sessions or path missing"
                    continue
                fi

                # BUG-009 fix: intentional-stops.json 확인 — 사용자가 의도적으로 중지한 세션은 재시작 금지
                # MAGI 앱에서 Stop 시 graceful exit이 실패해 레지스트리에 남아 있어도 watchdog이 재시작하지 않도록
                INTENTIONAL_STOPS_FILE="$HOME/.claude/intentional-stops.json"
                if [ -f "$INTENTIONAL_STOPS_FILE" ]; then
                    IS_INTENTIONAL=$(_WD_ISTOPS="$INTENTIONAL_STOPS_FILE" python3 -c "
import json, sys, os
from datetime import datetime, timezone, timedelta
try:
    with open(os.environ['_WD_ISTOPS']) as _f:
        d = json.load(_f)
    wn = sys.argv[1]
    TTL_HOURS = 48
    now = datetime.now(timezone.utc)
    # BUG-STALE-STOP fix: compact 재개 시 register 미실행으로 intentional-stop 잔류 문제
    # active-sessions에 이미 등록된 세션은 intentional-stop 무효화 (사용자가 다시 열었음)
    active_path = os.path.expanduser('~/.claude/active-sessions.json')
    try:
        with open(active_path) as _af:
            active = json.load(_af)
        if any(s.get('project','') == wn for s in active.get('sessions',[])):
            print('no'); sys.exit(0)
    except Exception:
        pass
    for s in d.get('stops', []):
        if s.get('window_name', s.get('project', '')) == wn:
            # TTL 체크 — 48시간 초과 항목은 만료 처리 (auto-restore와 동일 정책)
            stopped_at = s.get('stopped_at', '')
            if stopped_at:
                try:
                    ts = datetime.fromisoformat(stopped_at.replace('Z', '+00:00'))
                    if (now - ts) > timedelta(hours=TTL_HOURS):
                        continue  # 만료됨
                except Exception:
                    pass
            print('yes'); sys.exit(0)
except: pass
print('no')
" "$WINDOW_NAME" 2>/dev/null)
                    if [ "$IS_INTENTIONAL" = "yes" ]; then
                        log "SKIP restart: $RESTART_PROJECT — intentional-stop 목록에 있음 (사용자 의도 중지)"
                        continue
                    fi
                fi

                # window-groups.json에서 이 윈도우가 속한 세션 + 대기목록 여부 확인
                SESSION_INFO=$(python3 -c "
import json, os, sys
name = sys.argv[1]
path = os.path.expanduser('~/.claude/window-groups.json')
try:
    with open(path) as _gf:
        groups = json.load(_gf)
    for g in groups:
        if name in g.get('profileNames', []):
            waiting = 'yes' if g.get('isWaitingList') or g.get('sessionName','') == '__waiting__' else 'no'
            print(waiting + '|' + g.get('sessionName','claude-work'))
            sys.exit(0)
except Exception:
    pass
print('no|claude-work')
" "$WINDOW_NAME" 2>/dev/null)
                IS_WAITING=$(echo "$SESSION_INFO" | cut -d'|' -f1)
                TARGET_SESSION=$(echo "$SESSION_INFO" | cut -d'|' -f2)
                [ -z "$TARGET_SESSION" ] && TARGET_SESSION="claude-work"

                if [ "$IS_WAITING" = "yes" ]; then
                    log "SKIP restart: $WINDOW_NAME — 대기목록 세션"
                    continue
                fi

                # 해당 tmux 세션이 존재하는지 확인 — 없으면 자동 생성
                if ! tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
                    log "AUTO-CREATE: $TARGET_SESSION tmux 세션 없음 → 신규 생성"
                    tmux new-session -d -s "$TARGET_SESSION" -n _init_ -c "$HOME/claude" 2>/dev/null || true
                    SESSION_JUST_CREATED=true
                    sleep 0.5
                fi

                # 해당 윈도우가 타겟 세션에 없으면 항상 신규 생성
                # BUG-AUTOCREATE-SKIP fix: SESSION_JUST_CREATED 여부 불문하고 창 없으면 생성
                # (이전 이터레이션이 세션 재생성 후 → 창 없는 상태도 포함)
                if ! tmux list-windows -t "$TARGET_SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$WINDOW_NAME"; then
                    PROJ_ROOT=$(python3 -c "
import json, os, sys
p = os.path.expanduser('~/.claude/activated-sessions.json')
if os.path.exists(p):
    with open(p) as _af:
        d = json.load(_af)
else:
    d = {}
for path in d.get('activated', []):
    if os.path.basename(path) == sys.argv[1]:
        print(path); sys.exit(0)
" "$WINDOW_NAME" 2>/dev/null)
                    [ -z "$PROJ_ROOT" ] && PROJ_ROOT="$HOME/claude"
                    log "AUTO-CREATE-WIN: $TARGET_SESSION:$WINDOW_NAME (root: $PROJ_ROOT)"
                    # login shell로 생성해야 PATH에 claude 포함됨
                    # BUG-B fix: -P -F로 window_id 즉시 캡처 → automatic-rename 비활성화 (자동 "bash" 이름변경 방지)
                    INIT_WIN_ID=$(tmux new-window -t "$TARGET_SESSION" -n "$WINDOW_NAME" -c "$PROJ_ROOT" '/bin/bash -l' -P -F '#{window_id}' 2>/dev/null || true)
                    if [ -n "$INIT_WIN_ID" ]; then
                        tmux set-window-option -t "$INIT_WIN_ID" automatic-rename off 2>/dev/null || true
                        tmux rename-window -t "$INIT_WIN_ID" "$WINDOW_NAME" 2>/dev/null || true
                    fi
                    tmux kill-window -t "$TARGET_SESSION:_init_" 2>/dev/null || true
                    sleep 0.5  # 창 안정화 대기
                    SESSION_JUST_CREATED=true  # 창이 방금 생성됨 → kill 단계 스킵
                fi
                # 보호 PID 체크: 창에 살아있는 protected PID가 있으면 kill 금지 (활성 Claude Code 세션 보호)
                # BUG: window name에 '.' 포함 시 tmux가 pane 구분자 오해 → window_id(@N) 기반으로 list-panes
                PROTECTED_PIDS_FILE="$HOME/.claude/protected-claude-pids"
                WIN_ID_PROT=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$WINDOW_NAME" '$2==w{print $1; exit}')
                if [ -n "$WIN_ID_PROT" ]; then
                    PANE_PIDS_RAW=$(tmux list-panes -t "$WIN_ID_PROT" -F '#{pane_pid}' 2>/dev/null || true)
                else
                    PANE_PIDS_RAW=$(tmux list-panes -t "$TARGET_SESSION:$WINDOW_NAME" -F '#{pane_pid}' 2>/dev/null || true)
                fi
                SKIP_KILL=false
                if [ -f "$PROTECTED_PIDS_FILE" ] && [ -n "$PANE_PIDS_RAW" ]; then
                    while IFS= read -r ppid; do
                        [ -z "$ppid" ] && continue
                        kill -0 "$ppid" 2>/dev/null || continue
                        CHILD_PIDS=$(pgrep -P "$ppid" 2>/dev/null | tr '\n' ' ')
                        for cpid in $ppid $CHILD_PIDS; do
                            if grep -qF "$cpid" "$PROTECTED_PIDS_FILE" 2>/dev/null; then
                                log "SKIP kill-window: $WINDOW_NAME — 보호 PID $cpid 활성 중"
                                SKIP_KILL=true
                                break 2
                            fi
                        done
                    done <<< "$PANE_PIDS_RAW"
                fi
                [ "$SKIP_KILL" = "true" ] && continue
                # BUG-AUTOCREATE-KILL fix: 방금 생성된 세션/창은 kill 스킵
                # kill하면 세션 마지막 창 소멸 → 세션 자동 소멸 → 재시작 루프 발생
                if [ "$SESSION_JUST_CREATED" = "false" ]; then
                    # 기존 창 kill 후 재생성
                    # BUG#24 fix: window name에 '.'이 있으면 tmux가 pane 구분자로 오인 → window_id(@N) 기반 kill
                    WIN_ID_KILL=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$WINDOW_NAME" '$2==w{print $1; exit}')
                    if [ -n "$WIN_ID_KILL" ]; then
                        tmux kill-window -t "$WIN_ID_KILL" 2>/dev/null
                    else
                        tmux kill-window -t "$TARGET_SESSION:$WINDOW_NAME" 2>/dev/null
                    fi
                    sleep 1
                fi

                # 연속 크래시 카운터 증가 (COUNT|TIMESTAMP 형식, 24h 만료)
                CRASH_COUNT_FILE="$CRASH_COUNT_DIR/${RESTART_PROJECT//[^a-zA-Z0-9_-]/_}"
                CURRENT_COUNT=0
                CC_NOW=$(date +%s)
                if [ -f "$CRASH_COUNT_FILE" ]; then
                    CC_VAL=$(cat "$CRASH_COUNT_FILE" 2>/dev/null || echo "0|0")
                    CC_CNT=$(echo "$CC_VAL" | cut -d'|' -f1)
                    CC_TS=$(echo "$CC_VAL" | cut -d'|' -f2)
                    # 24시간 이상된 카운터는 리셋
                    if [ $(( CC_NOW - ${CC_TS:-0} )) -gt "$CRASH_COUNT_TTL" ]; then
                        CURRENT_COUNT=0
                    else
                        CURRENT_COUNT=${CC_CNT:-0}
                    fi
                fi
                NEW_COUNT=$((CURRENT_COUNT + 1))
                # iter59: atomic_write 함수 통일 (디스크 체크 포함)
                atomic_write "$CRASH_COUNT_FILE" "${NEW_COUNT}|${CC_NOW}"

                # 연속 크래시 임계값 초과 시 intentional-stop 등록 (무한 루프 방지)
                if [ "$NEW_COUNT" -gt "$CRASH_MAX" ]; then
                    log "CRASH LOOP DETECTED: $RESTART_PROJECT (${NEW_COUNT}회) — intentional-stop 등록"
                    notify "$RESTART_PROJECT 연속 ${NEW_COUNT}회 크래시 — 자동 복원 중단" 1 "xmark.octagon.fill"
                    bash "$HOME/.claude/scripts/stop-session.sh" "$WINDOW_NAME" 2>/dev/null || true
                    continue
                fi

                # BUG-AUTOCREATE-KILL fix: SESSION_JUST_CREATED=true면 창 이미 있음 — new-window 스킵
                RESTART_WIN_ID=""
                if [ "$SESSION_JUST_CREATED" = "false" ]; then
                    # BUG-B fix: window_id 캡처 → automatic-rename 즉시 비활성화
                    RESTART_WIN_ID=$(tmux new-window -t "$TARGET_SESSION" -n "$WINDOW_NAME" -c "$PROJ_PATH" -P -F '#{window_id}' 2>/dev/null || true)
                    if [ -n "$RESTART_WIN_ID" ]; then
                        tmux set-window-option -t "$RESTART_WIN_ID" automatic-rename off 2>/dev/null || true
                        tmux rename-window -t "$RESTART_WIN_ID" "$WINDOW_NAME" 2>/dev/null || true
                    fi
                else
                    # iter56: SESSION_JUST_CREATED=true → AUTO-CREATE에서 얻은 INIT_WIN_ID 재활용
                    RESTART_WIN_ID="$INIT_WIN_ID"
                fi
                # BUG#25+BUG-01 fix: window_id(@N) 기반 조회 → dot 이름 파싱 오류 완전 방지
                # index 조회 실패 시 window_id로 fallback (name 직접 사용 금지)
                # BUG-WINRACE fix: new-window 직후 list-windows에 없을 수 있음 → 최대 1.5s retry
                # iter56: RESTART_WIN_ID 직접 활용 — automatic-rename 타이밍 경쟁 조건 방지
                WIN_ID_NEW=""
                WIN_IDX_NEW=""
                if [ -n "$RESTART_WIN_ID" ]; then
                    # new-window에서 직접 캡처한 window_id 우선 사용 → name 조회 불필요
                    WIN_ID_NEW="$RESTART_WIN_ID"
                    WIN_IDX_NEW=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_index}|#{window_id}' 2>/dev/null | awk -F'|' -v id="$RESTART_WIN_ID" '$2==id{print $1; exit}')
                else
                    for _retry in 1 2 3; do
                        WIN_ID_NEW=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$WINDOW_NAME" '$2==w{print $1; exit}')
                        WIN_IDX_NEW=$(tmux list-windows -t "$TARGET_SESSION" -F '#{window_index}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$WINDOW_NAME" '$2==w{print $1; exit}')
                        [ -n "$WIN_ID_NEW" ] || [ -n "$WIN_IDX_NEW" ] && break
                        sleep 0.5
                    done
                fi
                # printf '%q': WINDOW_NAME 직접 삽입 → shell injection 방지
                _SAFE_WN=$(printf '%q' "$WINDOW_NAME")
                if [ -n "$WIN_IDX_NEW" ]; then
                    tmux set-window-option -t "$TARGET_SESSION:$WIN_IDX_NEW" automatic-rename off 2>/dev/null
                    tmux send-keys -t "$TARGET_SESSION:$WIN_IDX_NEW" "(bash ~/.claude/scripts/tab-status.sh starting ${_SAFE_WN} 2>/dev/null || true) && unset CLAUDECODE && claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions" Enter
                elif [ -n "$WIN_ID_NEW" ]; then
                    # window_id(@N) 기반 fallback — dot 이름 포함 세션 안전 처리
                    tmux set-window-option -t "$WIN_ID_NEW" automatic-rename off 2>/dev/null
                    tmux send-keys -t "$WIN_ID_NEW" "(bash ~/.claude/scripts/tab-status.sh starting ${_SAFE_WN} 2>/dev/null || true) && unset CLAUDECODE && claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions" Enter
                else
                    log "WARN: $WINDOW_NAME 창 index/id 조회 실패 — 재시작 명령 스킵"
                fi

                log "AUTO-RESTART: $RESTART_PROJECT → $TARGET_SESSION:$WINDOW_NAME (연속 ${NEW_COUNT}/${CRASH_MAX}회)"
                notify "세션 자동 복구: $RESTART_PROJECT" 0 "arrow.clockwise.circle.fill"

                # BUG-C fix: REORDER를 루프 밖으로 이동 — 세션별 1회만 실행 (중복 재배열 방지)
                SESSIONS_TO_REORDER="$SESSIONS_TO_REORDER $TARGET_SESSION"

            done <<< "$CRASHED"

            # BUG-REORDER fix: 모든 크래시 처리 후 영향받은 세션별 1회만 순서 복원
            for _rsess in $(echo "$SESSIONS_TO_REORDER" | tr ' ' '\n' | sort -u | grep -v '^$'); do
                DESIRED_ORDER_R=$(python3 -c "
import json, os, sys
path = os.path.expanduser('~/.claude/window-groups.json')
try:
    with open(path) as _gf2:
        groups = json.load(_gf2)
    for g in groups:
        if g.get('sessionName','') == sys.argv[1] and not g.get('isWaitingList', False):
            print('|'.join(g.get('profileNames', [])))
            sys.exit(0)
except: pass
print('')
" "$_rsess" 2>/dev/null)
                if [ -n "$DESIRED_ORDER_R" ]; then
                    IDX=0
                    IFS='|' read -ra PROFILES_ORD <<< "$DESIRED_ORDER_R"
                    for pname in "${PROFILES_ORD[@]}"; do
                        WIN_ID_ORD=$(tmux list-windows -t "$_rsess" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' -v w="$pname" '$2==w{print $1;exit}')
                        [ -z "$WIN_ID_ORD" ] && continue
                        tmux move-window -s "$WIN_ID_ORD" -t "$_rsess:$((500 + IDX))" 2>/dev/null
                        IDX=$((IDX + 1))
                    done
                    IDX=0
                    for pname in "${PROFILES_ORD[@]}"; do
                        tmux move-window -s "$_rsess:$((500 + IDX))" -t "$_rsess:$((IDX + 1))" 2>/dev/null
                        IDX=$((IDX + 1))
                    done
                    log "REORDER: $_rsess 순서 복원 완료"
                    WIN_AT_999=$(tmux list-windows -t "$_rsess" -F '#{window_index}|#{window_name}' 2>/dev/null | awk -F'|' '$1=="999" && $2!="monitor"{print $2;exit}')
                    [ -n "$WIN_AT_999" ] && tmux move-window -s "$_rsess:999" -t "$_rsess:900" 2>/dev/null || true
                    tmux move-window -s "$_rsess:monitor" -t "$_rsess:999" 2>/dev/null || true
                fi
            done
        fi
    fi

    # 2. 시간 경과 표시 (v3 tab-color/states JSON 기반 → set-color.sh 경유)
    #    10분+ → idle_10m  |  1시간+ → idle_1h  |  1일+ → idle_1d  |  3일+ → idle_3d
    NOW=$(date +%s)
    STATE_DIR="$HOME/.claude/tab-color/states"
    LEGACY_STATE_DIR="$HOME/.claude/tab-states"
    if [ -d "$STATE_DIR" ]; then
        # Claude Code 보호: tmux 패인에 실제로 속한 TTY만 처리 (s008 등 자체 터미널 보호)
        TMUX_PANE_TTYS=$(tmux list-panes -a -F "#{pane_tty}" 2>/dev/null | sort -u)
        for STATE_FILE in "$STATE_DIR"/*.json; do
            [ ! -f "$STATE_FILE" ] && continue
            TTY_NAME=$(basename "$STATE_FILE" .json)
            TTY_PATH="/dev/$TTY_NAME"
            if [ ! -c "$TTY_PATH" ]; then
                rm -f "$STATE_FILE"
                log "CLEANUP: orphan tab-color state removed: $TTY_NAME"
                continue
            fi
            [ ! -w "$TTY_PATH" ] && continue
            # tmux 패인에 없는 TTY는 건드리지 않음 (Claude Code 자체 터미널 보호)
            if ! echo "$TMUX_PANE_TTYS" | grep -qF "$TTY_PATH"; then
                rm -f "$STATE_FILE"
                log "CLEANUP: non-tmux TTY state removed (self-protection): $TTY_NAME"
                continue
            fi

            # BUG#5 fix: 4회 파일 읽기 → 1회 통합 (race condition 제거)
            # BUG-PID-NONE fix: pid:null JSON → Python None → "None" 문자열 방지 (int coerce)
            # iter59: with open() 파일핸들 누수 수정 + env var 방식
            _AGING_DATA=$(WD_STATE_F="$STATE_FILE" python3 -c "
import json, os
try:
    with open(os.environ['WD_STATE_F']) as f:
        d=json.load(f)
    print(d.get('project',''))
    print(d.get('timestamp',''))
    print(d.get('type',''))
    _pid=d.get('pid',0)
    print(int(_pid) if _pid is not None else 0)
except:
    print(''); print(''); print(''); print(0)
" 2>/dev/null)
            TAB_PROJECT=$(printf '%s' "$_AGING_DATA" | sed -n '1p')
            LAST_TS_ISO=$(printf '%s' "$_AGING_DATA" | sed -n '2p')
            TAB_TYPE=$(printf '%s' "$_AGING_DATA" | sed -n '3p')
            TAB_PID_READ=$(printf '%s' "$_AGING_DATA" | sed -n '4p' | tr -d '[:space:]')
            [ -z "$LAST_TS_ISO" ] && continue
            # active/working/starting: PID가 살아있을 때만 aging 스킵 (죽은 세션은 aging 진행)
            # BUG#5 fix: starting 상태도 스킵 (새 세션 생성 직후 2초 이내 aging 방지)
            if [ "$TAB_TYPE" = "active" ] || [ "$TAB_TYPE" = "working" ] || [ "$TAB_TYPE" = "starting" ]; then
                TAB_PID="${TAB_PID_READ:-0}"
                # BUG-PID-NONINT fix: 숫자가 아닌 값 방어 (개행/공백/None 포함 가능성)
                [[ ! "$TAB_PID" =~ ^[0-9]+$ ]] && TAB_PID=0
                if [ "$TAB_PID" -gt 0 ] && kill -0 "$TAB_PID" 2>/dev/null; then
                    continue  # PID 살아있음 → aging 스킵
                fi
                # PID 없거나 죽었음 → aging 진행
            fi

            LAST_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS_ISO" +%s 2>/dev/null || echo 0)
            [ "$LAST_TS" = "0" ] && continue

            AGE=$(( NOW - LAST_TS ))

            # 이미 해당 idle 상태면 재호출 스킵 (불필요한 ESC 반복 방지)
            if [ $AGE -ge 259200 ]; then
                AGING_STATE="idle_3d"
            elif [ $AGE -ge 86400 ]; then
                AGING_STATE="idle_1d"
            elif [ $AGE -ge 3600 ]; then
                AGING_STATE="idle_1h"
            elif [ $AGE -ge 600 ]; then
                AGING_STATE="idle_10m"
            else
                continue
            fi
            # 이미 같은 idle 상태면 스킵 (30초마다 재호출 불필요)
            [ "$TAB_TYPE" = "$AGING_STATE" ] && continue
            # set-color.sh 경유: state 파일 갱신 + config 색상 사용
            TAB_TTY="$TTY_PATH" bash "$HOME/.claude/tab-color/engine/set-color.sh" "$AGING_STATE" "$TAB_PROJECT" 2>/dev/null &
        done
    fi
    # 레거시 tab-states orphan 정리 (compat 파일은 유지 — set-color.sh가 활성 TTY 기록)
    # 전체 삭제 금지: active-sessions.json에 없는 TTY만 정리
    if [ -d "$LEGACY_STATE_DIR" ]; then
        ACTIVE_TTYS=$(python3 -c "
import json, os
_asp = os.path.expanduser('~/.claude/active-sessions.json')
if os.path.exists(_asp):
    with open(_asp) as _asf:
        d = json.load(_asf)
else:
    d = {}
print(' '.join(s.get('tty','') for s in d.get('sessions',[]) if s.get('tty','')))
" 2>/dev/null || echo "")
        LEGACY_CLEANED=0
        for lf in "$LEGACY_STATE_DIR"/ttys*; do
            [ ! -f "$lf" ] && continue
            TTY_BASE=$(basename "$lf")
            # TTY 장치가 없으면 즉시 삭제
            if [ ! -c "/dev/$TTY_BASE" ]; then
                rm -f "$lf" 2>/dev/null
                LEGACY_CLEANED=$((LEGACY_CLEANED + 1))
                continue
            fi
            # active-sessions에 있으면 보존
            echo " $ACTIVE_TTYS " | grep -qF " $TTY_BASE " && continue
            # active-sessions에 없어도 해당 TTY에 살아있는 claude 프로세스가 있으면 보존
            # (M+N 에이전트 등 등록 안 된 claude 세션 보호)
            if ps -o command= -t "$TTY_BASE" 2>/dev/null | grep -q '[c]laude'; then
                continue
            fi
            rm -f "$lf" 2>/dev/null
            LEGACY_CLEANED=$((LEGACY_CLEANED + 1))
        done
        [ "$LEGACY_CLEANED" -gt 0 ] && log "CLEANUP: orphan legacy tab-states ${LEGACY_CLEANED}개 정리"
    fi

    # 3. 좀비 프로세스 감지 (72시간 이상 + tty 없음)
    ZOMBIES=$(ps -eo pid,tty,etime,command 2>/dev/null | grep "[c]laude" | grep -v "Claude.app\|Helper\|watchdog\|auto-restore\|tmux\|bash.*claude-work\|bash.*claude-takedown" | awk '{
        # etime 형식: DD-HH:MM:SS 또는 HH:MM:SS 또는 MM:SS
        split($3, parts, "-");
        days = 0;
        if (length(parts) == 2) { days = parts[1]+0; }
        if (days >= 3 && $2 == "??") print $1, $4
    }' 2>/dev/null || true)

    if [ -n "$ZOMBIES" ]; then
        log "ZOMBIE DETECTED: $ZOMBIES"
    fi

    # 4. iTerm2 생존 확인 (ps -A 사용 — tmux sandbox에서 pgrep -x 오탐 방지)
    if ! ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
        log "WARNING: iTerm2 not running"
    fi

    # monitor 창 소실 감지 및 자동 복구 (모든 active 세션)
    ACTIVE_SESSIONS_MON=$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.claude/window-groups.json')) as _wgf:
        groups = json.load(_wgf)
    for g in groups:
        sn = g.get('sessionName','')
        if not g.get('isWaitingList', False) and sn and sn != '__waiting__':
            print(sn)
except: pass
" 2>/dev/null)
    [ -z "$ACTIVE_SESSIONS_MON" ] && ACTIVE_SESSIONS_MON="claude-work"

    for MON_SESSION in $ACTIVE_SESSIONS_MON; do
        if tmux has-session -t "$MON_SESSION" 2>/dev/null; then
            if ! tmux list-windows -t "$MON_SESSION" -F "#{window_name}" 2>/dev/null | grep -q "^monitor$"; then
                log "MONITOR 창 없음 ($MON_SESSION) — 자동 복구"
                # BUG-MONITOR-CMD fix: 명령 인수 포함 시 -P -F #{window_id} 출력 안됨
                # → 창 먼저 생성(-c start-dir) 후 send-keys로 명령 전송
                _MON_WID=$(tmux new-window -d -t "$MON_SESSION" -n monitor -c "$HOME/claude" -P -F '#{window_id}' 2>/dev/null || true)
                if [ -n "$_MON_WID" ]; then
                    tmux send-keys -t "$_MON_WID" "while true; do sleep 86400; done" Enter 2>/dev/null || true
                    tmux set-window-option -t "$_MON_WID" automatic-rename off 2>/dev/null || true
                    tmux rename-window -t "$_MON_WID" monitor 2>/dev/null || true
                    tmux move-window -s "$_MON_WID" -t "$MON_SESSION:999" 2>/dev/null || true
                    log "MONITOR 창 복구 완료 ($MON_SESSION)"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [tmux-window] MONITOR_RECOVER session=$MON_SESSION wid=$_MON_WID" >> "$HOME/.claude/logs/window-events.log"
                else
                    log "ERROR: MONITOR 창 복구 실패 ($MON_SESSION)"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [tmux-window] MONITOR_FAIL session=$MON_SESSION" >> "$HOME/.claude/logs/window-events.log"
                fi
            else
                # monitor 창이 999번이 아니면 이동
                MON_IDX=$(tmux list-windows -t "$MON_SESSION" -F "#{window_index} #{window_name}" 2>/dev/null | awk '/^[0-9]+ monitor$/{print $1}')
                if [ -n "$MON_IDX" ] && [ "$MON_IDX" != "999" ]; then
                    # BUG-001 fix: 999에 다른 창이 있으면 900으로 먼저 이동
                    WIN999=$(tmux list-windows -t "$MON_SESSION" -F '#{window_index}|#{window_name}' 2>/dev/null | awk -F'|' '$1=="999" && $2!="monitor"{print $2;exit}')
                    [ -n "$WIN999" ] && tmux move-window -s "$MON_SESSION:999" -t "$MON_SESSION:900" 2>/dev/null || true
                    tmux move-window -s "$MON_SESSION:monitor" -t "$MON_SESSION:999" 2>/dev/null || true
                fi
            fi
        fi
    done

    # 4.5. Hot-add: window-groups.json에 있지만 tmux에 없는 창 자동 생성 (2분 간격)
    HOTADD_LOCK="/tmp/.hotadd-last"
    LAST_HOTADD=0
    [ -f "$HOTADD_LOCK" ] && LAST_HOTADD=$(cat "$HOTADD_LOCK" 2>/dev/null || echo 0)
    NOW_HOTADD=$(date +%s)
    if [ $((NOW_HOTADD - LAST_HOTADD)) -gt 120 ] && [ ! -f "/tmp/.auto-restore.lock" ] && [ ! -f "/tmp/.auto-attach.lock" ]; then
        echo "$NOW_HOTADD" > "$HOTADD_LOCK"
        HOTADD_RESULT=$(python3 << 'HOTADD_PYEOF'
import json, os, subprocess, sys

wg_path = os.path.expanduser('~/.claude/window-groups.json')
as_path = os.path.expanduser('~/.claude/activated-sessions.json')

try:
    with open(wg_path) as f:
        groups = json.load(f)
    with open(as_path) as f:
        activated = json.load(f)
except Exception as e:
    sys.exit(0)

# name → path 맵 (공백↔밑줄 정규화)
name_to_path = {}
for p in activated.get('activated', []):
    bn = os.path.basename(p)
    name_to_path[bn] = p
    name_to_path[bn.replace(' ', '_')] = p
    name_to_path[bn.replace('_', ' ')] = p

added = []
for g in groups:
    sn = g.get('sessionName', '')
    if g.get('isWaitingList', False) or not sn or sn == '__waiting__':
        continue
    # 현재 tmux 창 목록
    r = subprocess.run(['tmux', 'list-windows', '-t', sn, '-F', '#{window_name}'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        continue
    existing = set(r.stdout.strip().split('\n'))
    for pname in g.get('profileNames', []):
        if pname in existing:
            continue
        proj_path = name_to_path.get(pname) or name_to_path.get(pname.replace(' ', '_')) or name_to_path.get(pname.replace('_', ' '))
        if not proj_path or not os.path.isdir(proj_path):
            continue
        # tmux 창 생성
        r2 = subprocess.run(
            ['tmux', 'new-window', '-t', sn, '-n', pname, '-c', proj_path, '-P', '-F', '#{window_id}'],
            capture_output=True, text=True)
        if r2.returncode == 0:
            wid = r2.stdout.strip()
            subprocess.run(['tmux', 'set-window-option', '-t', wid, 'automatic-rename', 'off'],
                           capture_output=True)
            subprocess.run(['tmux', 'rename-window', '-t', wid, pname], capture_output=True)
            import shlex
            claude_cmd = "unset CLAUDECODE && claude --dangerously-skip-permissions --continue"
            subprocess.run(['tmux', 'send-keys', '-t', wid,
                            f"(bash ~/.claude/scripts/tab-status.sh starting {shlex.quote(pname)} 2>/dev/null || true) && {claude_cmd}",
                            'Enter'], capture_output=True)
            added.append(f"{sn}/{pname}")

if added:
    print('HOT-ADD: ' + ', '.join(added))
HOTADD_PYEOF
        2>/dev/null || true)
        [ -n "$HOTADD_RESULT" ] && log "$HOTADD_RESULT" && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $HOTADD_RESULT" >> "$HOME/.claude/logs/window-events.log"
    fi

    # 5. tmux CC 클라이언트 연결 상태 모니터링 (모든 active 세션)
    # auto-restore / auto-attach 실행 중이면 cc-fix 전체 스킵 (BUG-001 fix: 중복 창 방지)
    RESTORE_RUNNING=false
    RESTORE_LOCK="/tmp/.auto-restore.lock"
    if [ -f "$RESTORE_LOCK" ]; then
        RESTORE_PID=$(cat "$RESTORE_LOCK" 2>/dev/null)
        [ -n "$RESTORE_PID" ] && kill -0 "$RESTORE_PID" 2>/dev/null && RESTORE_RUNNING=true
    fi
    if [ "$RESTORE_RUNNING" = "false" ] && [ -f "/tmp/.auto-attach.lock" ]; then
        ATTACH_PID=$(cat "/tmp/.auto-attach.lock" 2>/dev/null)
        [ -n "$ATTACH_PID" ] && kill -0 "$ATTACH_PID" 2>/dev/null && RESTORE_RUNNING=true
    fi
    for CC_SESSION in $ACTIVE_SESSIONS_MON; do
        if tmux has-session -t "$CC_SESSION" 2>/dev/null; then
            # BUG-CCFIX-LINKEDCHECK fix: main session + linked sessions(-vN) 모두 확인
            # linked session이 attached되면 main session 클라이언트는 0으로 보이므로
            # claude-work-v* 등 linked sessions에도 클라이언트가 있으면 cc-fix 스킵
            CLIENT_COUNT=$(tmux list-clients -t "$CC_SESSION" -F "#{client_name}" 2>/dev/null | wc -l | tr -d ' ')
            if [ "${CLIENT_COUNT:-0}" -eq 0 ]; then
                # BUG#6 fix: 2개 tmux 호출 → 1개로 통합 (race 제거)
                LINKED_CLIENT_COUNT=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CC_SESSION}-v" | while read -r ls; do tmux list-clients -t "$ls" -F "#{client_name}" 2>/dev/null; done | wc -l | tr -d ' ')
                if [ "${LINKED_CLIENT_COUNT:-0}" -gt 0 ]; then
                    continue  # linked session에 클라이언트 있음 — cc-fix 불필요
                fi
                [ "$RESTORE_RUNNING" = "true" ] && continue
                CC_FIX_LOCK="/tmp/.cc-fix-last-${CC_SESSION//[^a-zA-Z0-9]/_}"
                LAST_FIX=0
                [ -f "$CC_FIX_LOCK" ] && LAST_FIX=$(cat "$CC_FIX_LOCK" 2>/dev/null || echo 0)
                NOW_FIX=$(date +%s)
                if [ $((NOW_FIX - LAST_FIX)) -gt 120 ]; then
                    log "WARNING: $CC_SESSION 클라이언트 없음 (linked 포함) — 자동 CC 재연결 시도"
                    # BUG#3 fix: cc-fix 성공 시에만 cooldown 갱신 (실패해도 10분 대기 방지)
                    _CC_FIX_LOCK_COPY="$CC_FIX_LOCK"
                    _CC_NOW_COPY="$NOW_FIX"
                    (TMUX_SESSION="$CC_SESSION" bash "$HOME/.claude/scripts/cc-fix.sh" 2>/dev/null && echo "$_CC_NOW_COPY" > "$_CC_FIX_LOCK_COPY") &
                fi
            fi
        fi
    done

    # 5.5. active-sessions orphan-sync (1시간 주기)
    # window-groups.json의 프로파일 중 active-sessions에 없는 것을 tmux 기반으로 보완 등록
    ORPHAN_SYNC_LOCK="/tmp/.orphan-sync-last"
    LAST_OS=0
    [ -f "$ORPHAN_SYNC_LOCK" ] && LAST_OS=$(cat "$ORPHAN_SYNC_LOCK" 2>/dev/null || echo 0)
    NOW_OS=$(date +%s)
    if [ $((NOW_OS - LAST_OS)) -gt 3600 ]; then
        echo "$NOW_OS" > "$ORPHAN_SYNC_LOCK"
        SYNC_RESULT=$(python3 "$HOME/.claude/scripts/active-sessions-sync.py" 2>/dev/null || true)
        [ -n "$SYNC_RESULT" ] && log "[orphan-sync] $SYNC_RESULT"

        # activated-sessions.json 자동 스캔 — ~/claude의 새 디렉토리 추가
        DIRSCAN_RESULT=$(python3 << 'DIRSCAN_PYEOF'
import json, os, tempfile, sys

CLAUDE_DIR = os.path.expanduser('~/claude')
AS_PATH = os.path.expanduser('~/.claude/activated-sessions.json')

# 무시 패턴 (TP_skills index.md 기준)
IGNORE_PREFIXES = ('Claude_code_', '_archived', 'archive', 'claude-squad', 'claude_squad',
                   'teamplean-github-pages', 'teamplayer-github-pages', '.', 'claude_')
IGNORE_CONTAINS = ('아카이빙', '쓰레기', '_archived_', '-archived-')
IGNORE_EXACT = {'CLAUDE.md', 'SESSION_STATE.md', 'test', 'claude_gpt'}
IGNORE_SUFFIXES = ('.md', '.html', '.js', '.json', '.txt', '.py')

try:
    with open(AS_PATH) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

existing = set(data.get('activated', []))
new_entries = []

for name in sorted(os.listdir(CLAUDE_DIR)):
    if name in IGNORE_EXACT:
        continue
    if any(name.startswith(p) for p in IGNORE_PREFIXES):
        continue
    if any(name.endswith(s) for s in IGNORE_SUFFIXES):
        continue
    if any(kw in name for kw in IGNORE_CONTAINS):
        continue
    full = os.path.join(CLAUDE_DIR, name)
    if not os.path.isdir(full):
        continue
    if full not in existing:
        new_entries.append(full)
        existing.add(full)

if not new_entries:
    sys.exit(0)

# 원자적 업데이트
data['activated'] = sorted(existing)
import time
data['last_updated'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
dir_ = os.path.dirname(AS_PATH)
fd, tmp = tempfile.mkstemp(dir=dir_, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.replace(tmp, AS_PATH)
print('DIR-SCAN added: ' + ', '.join(os.path.basename(p) for p in new_entries))
DIRSCAN_PYEOF
        2>/dev/null || true)
        [ -n "$DIRSCAN_RESULT" ] && log "[dir-scan] $DIRSCAN_RESULT"
    fi

    # 6. orphan linked session 정리 (BUG-005 fix)
    # 24시간 이상 클라이언트 없는 linked sessions(-vN) 제거
    LINKED_CLEANUP_LOCK="/tmp/.linked-cleanup-last"
    LAST_CLEANUP=0
    [ -f "$LINKED_CLEANUP_LOCK" ] && LAST_CLEANUP=$(cat "$LINKED_CLEANUP_LOCK" 2>/dev/null || echo 0)
    NOW_CLEANUP=$(date +%s)
    if [ $((NOW_CLEANUP - LAST_CLEANUP)) -gt 21600 ]; then  # 6시간마다 정리 (BUG-003 fix: 24h → 6h)
        echo "$NOW_CLEANUP" > "$LINKED_CLEANUP_LOCK"
        tmux list-sessions -F '#{session_name}|#{session_created}' 2>/dev/null | grep -E '.*-v[0-9]+\|' | while IFS='|' read -r lsname lscreated; do
            # iter57: 세션 존재 재확인 (list-sessions 이후 kill 가능성 방어)
            tmux has-session -t "$lsname" 2>/dev/null || continue
            CLIENT_COUNT_LS=$(tmux list-clients -t "$lsname" -F "#{client_name}" 2>/dev/null | wc -l | tr -d ' ')
            AGE_LS=$(( NOW_CLEANUP - ${lscreated:-0} ))
            if [ "${CLIENT_COUNT_LS:-0}" -eq 0 ] && [ "$AGE_LS" -gt 3600 ]; then  # 1시간 이상 클라이언트 없음
                tmux kill-session -t "$lsname" 2>/dev/null && log "orphan linked session 정리: $lsname (${AGE_LS}초 전 생성)"
            fi
        done
    fi

    # stderr.log 로테이션 (매 루프마다 체크)
    rotate_stderr_log

    # 30초 대기
    sleep 30
done
