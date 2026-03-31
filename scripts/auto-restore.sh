#!/bin/bash
# Claude Code Auto-Restore Script
# window-groups.json 기반 — 각 그룹의 tmux 세션 생성

LOG_FILE="$HOME/.claude/logs/auto-restore.log"
STOPS_FILE="$HOME/.claude/intentional-stops.json"
WINDOW_GROUPS="$HOME/.claude/window-groups.json"
ACTIVATED_FILE="$HOME/.claude/activated-sessions.json"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# iter59: auto-restore.log 로테이션 (10000줄 초과 시 5000줄 유지)
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 10000 ] 2>/dev/null; then
    tail -5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
fi

log "=== Auto-Restore 시작 ==="
# 윈도우 이벤트 로그 (초기화 보장)
WELOG="$HOME/.claude/logs/window-events.log"
mkdir -p "$(dirname "$WELOG")"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-restore] START caller=$(ps -o comm= -p $PPID 2>/dev/null || echo unknown)" >> "$WELOG"

# BUG-FLAG-STALE fix: 시작 즉시 이전 부팅 플래그 삭제 (auto-attach의 오래된 플래그 재사용 방지)
FLAG_FILE_STALE="$HOME/.claude/logs/.auto-restore-done"
[ -f "$FLAG_FILE_STALE" ] && rm -f "$FLAG_FILE_STALE" && log "기존 auto-restore-done 플래그 삭제"

# 중복 실행 방지 (PID 파일 기반 — LaunchAgent 동시 트리거 방어, macOS flock 없음)
LOCK_FILE="/tmp/.auto-restore.lock"
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "이미 auto-restore 실행 중 (PID: $OLD_PID) — 스킵"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# 환경변수 로드 (LaunchAgent 비-TTY 환경 — .zshrc source 금지: iTerm2 integration 오류 발생)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/opt/homebrew/sbin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
unset CLAUDECODE

# 이미 claude CLI 프로세스가 다수 실행 중이면 스킵 (--force 옵션으로 우회)
# 단, 부팅 직후(uptime 300초 이내)는 Login Items로 인해 claude 프로세스가 이미 떠있을 수 있으므로
# EXISTING 체크를 건너뜀 — pkill -x claude 로 어차피 정리됨
FORCE_MODE="${1:-}"
BOOT_TS=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
NOW_TS=$(date +%s)
UPTIME_SEC=$(( NOW_TS - ${BOOT_TS:-0} ))

# 30분 쿨다운: 부팅 직후(300s 이내)나 --force가 아니면 마지막 실행 후 1800초 내 재실행 방지
# 이중 LaunchAgent(com.claude.auto-restore + com.claude.magi-restore) 동시 트리거 방어
LASTRUN_FILE="$HOME/.claude/logs/.auto-restore-lastrun"
if [ "$UPTIME_SEC" -ge 300 ] && [ "$FORCE_MODE" != "--force" ]; then
    if [ -f "$LASTRUN_FILE" ]; then
        LAST_RUN_TS=$(cat "$LASTRUN_FILE" 2>/dev/null)
        SINCE_LAST=$(( NOW_TS - ${LAST_RUN_TS:-0} ))
        if [ "$SINCE_LAST" -lt 1800 ]; then
            log "마지막 실행 후 ${SINCE_LAST}초 경과 — 쿨다운 중 (30분 미만), 스킵 (강제: --force)"
            WELOG="$HOME/.claude/logs/window-events.log"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-restore] COOLDOWN 스킵 (uptime=${UPTIME_SEC}s, last=${SINCE_LAST}s전)" >> "$WELOG"
            exit 0
        fi
    fi
fi
echo "$NOW_TS" > "$LASTRUN_FILE"

EXISTING=$(ps -A -o comm= 2>/dev/null | grep -c "^claude$" | tr -d ' ')
if [ "$UPTIME_SEC" -lt 300 ]; then
    log "부팅 직후 감지 (uptime=${UPTIME_SEC}s) — EXISTING 체크 스킵 (현재 claude ${EXISTING}개)"
elif [ "${EXISTING:-0}" -gt 0 ] && [ "$FORCE_MODE" != "--force" ]; then
    log "활성 claude CLI 프로세스 ${EXISTING}개 실행 중 — auto-restore 스킵 (강제: bash auto-restore.sh --force)"
    exit 0
fi

# 기존 claude 프로세스 모두 종료 (새 세션 생성 전, 신규 tmux 창 생성 방지)
# 기존 claude 프로세스 종료 (새 세션 생성 전 — 단, 보호 PID는 절대 kill 금지)
# 보호 PID: ~/.claude/protected-claude-pids 에 등록된 PID (현재 활성 Claude Code 세션 PID)
PROTECTED_PIDS_FILE="$HOME/.claude/protected-claude-pids"
PROTECTED_PIDS=""
if [ -f "$PROTECTED_PIDS_FILE" ]; then
    # 살아있는 PID만 유효 (stale 항목 무시)
    while IFS= read -r ppid; do
        [ -z "$ppid" ] && continue
        if kill -0 "$ppid" 2>/dev/null; then
            PROTECTED_PIDS="$PROTECTED_PIDS $ppid"
        fi
    done < "$PROTECTED_PIDS_FILE"
    [ -n "$PROTECTED_PIDS" ] && log "보호 PID 목록:$PROTECTED_PIDS"
fi

log "기존 claude 프로세스 종료 중 (보호 PID 제외)..."
ps -A -o pid=,comm= 2>/dev/null | awk '/[[:space:]]claude$/{print $1}' | while read -r cpid; do
    if echo " $PROTECTED_PIDS " | grep -qF " $cpid "; then
        log "보호 PID 스킵: $cpid (활성 Claude Code 세션)"
        continue
    fi
    kill "$cpid" 2>/dev/null || true
done
sleep 2

# 스테일 tmux 소켓 파일 정리 (부팅 후 재실행 시 서버가 없는데 소켓 파일이 남아있는 경우 대비)
for sock in /tmp/tmux-*/default; do
    [ -e "$sock" ] || continue
    if ! tmux -S "$sock" list-sessions &>/dev/null 2>&1; then
        rm -f "$sock"
        log "스테일 tmux 소켓 삭제: $sock"
    fi
done

# window-groups.json 존재 확인
if [ ! -f "$WINDOW_GROUPS" ]; then
    log "window-groups.json 없음 — 종료"
    exit 1
fi

# activated-sessions.json에서 name→path 맵 생성 (공백↔밑줄 정규화 비교)
get_path_for_name() {
    local name="$1"
    python3 -c "
import json, os, sys, re
name = sys.argv[1]
# 공백/밑줄을 동일하게 취급: 공백→_ 정규화 후 비교
def normalize(s):
    return re.sub(r'[ _]+', '_', s).lower()
norm_name = normalize(name)
path = os.path.expanduser('~/.claude/activated-sessions.json')
for candidate in [path, path + '.bak']:
    try:
        with open(candidate) as f:
            data = json.load(f)
        for p in data.get('activated', []):
            bname = os.path.basename(p)
            # 정확 매칭 우선, 그 다음 정규화 비교
            if bname == name or normalize(bname) == norm_name:
                print(p)
                sys.exit(0)
    except Exception:
        continue
" "$name" 2>/dev/null
}

# window-groups.json에서 활성 그룹(isWaitingList=false) 목록 읽기
GROUPS_JSON=$(WG_PATH="$WINDOW_GROUPS" python3 -c "
import json, sys, os
path = os.environ['WG_PATH']
try:
    with open(path) as f:
        groups = json.load(f)
    active = [g for g in groups if not g.get('isWaitingList', False)]
    for g in active:
        profiles = '|'.join(g.get('profileNames', []))
        print(g['sessionName'] + '\t' + profiles)
except Exception as e:
    sys.exit(1)
" 2>/dev/null)

if [ -z "$GROUPS_JSON" ]; then
    log "활성 그룹 없음 — 종료"
    exit 1
fi

TOTAL_CREATED=0

while IFS=$'\t' read -r SESSION_NAME PROFILES_STR; do
    [ -z "$SESSION_NAME" ] && continue
    # BUG#20 fix: 그룹별 DELAY 리셋 (이전 그룹 delay가 다음 그룹으로 누적되는 문제 방지)
    DELAY=0
    log "--- 그룹 처리: $SESSION_NAME ---"

    # 기존 tmux 세션 종료 (claude 프로세스가 새 창 만드는 것 방지: kill-server 전 약간 대기)
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "기존 $SESSION_NAME tmux 세션 종료"
        # 세션의 모든 pane에서 실행 중인 claude 프로세스 먼저 종료
        tmux list-panes -t "$SESSION_NAME" -a -F '#{pane_pid}' 2>/dev/null | while read -r ppid; do
            pkill -P "$ppid" -x "claude" 2>/dev/null || true
        done
        sleep 1
        tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
        sleep 1
    fi

    # _init_ 임시 창으로 세션 생성 (profile 창들을 먼저 만들고 monitor를 맨 뒤에 배치)
    tmux new-session -d -s "$SESSION_NAME" -n _init_ -c "$HOME/claude" 2>/dev/null
    # BUG-INIT-RENAME fix: auto-rename 방지 → kill 시 이름 불일치 예방
    tmux set-window-option -t "$SESSION_NAME:_init_" automatic-rename off 2>/dev/null || true
    log "$SESSION_NAME 세션 생성"

    # 각 profileName으로 창 생성
    IFS='|' read -ra PROFILES <<< "$PROFILES_STR"
    for PROFILE_NAME in "${PROFILES[@]}"; do
        [ -z "$PROFILE_NAME" ] && continue

        PROJ_PATH=$(get_path_for_name "$PROFILE_NAME")
        if [ -z "$PROJ_PATH" ] || [ ! -d "$PROJ_PATH" ]; then
            log "SKIP $PROFILE_NAME — activated-sessions에 경로 없음"
            continue
        fi

        # BUG-NOSTOPCHECK fix: intentional-stops.json 체크 — 의도적으로 중지된 프로파일 skip (48h TTL 적용)
        if [ -f "$STOPS_FILE" ]; then
            # iter59: BUG-INJECT/FILE-LEAK fix — env var 방식 + with open() 파일핸들 정리
            IS_STOPPED=$(AR_STOPS="$STOPS_FILE" AR_PROFILE="$PROFILE_NAME" python3 -c "
import json, sys, os
from datetime import datetime, timezone, timedelta
try:
    stops_f = os.environ['AR_STOPS']
    profile = os.environ['AR_PROFILE']
    with open(stops_f) as f:
        d = json.load(f)
    cutoff = datetime.now(timezone.utc) - timedelta(hours=48)
    for s in d.get('stops', []):
        # BUG-AUTORESTORE-MATCH fix: window_name + project 이중 매칭 (DIR_TO_WINDOW 매핑 대응)
        if profile not in (s.get('window_name',''), s.get('project','')):
            continue
        ts_str = s.get('stopped_at','1970-01-01T00:00:00Z').replace('Z','+00:00')
        ts = datetime.fromisoformat(ts_str)
        if ts > cutoff:
            print('yes')
            sys.exit(0)
    print('no')
except:
    print('no')
" 2>/dev/null)
            if [ "$IS_STOPPED" = "yes" ]; then
                log "SKIP $PROFILE_NAME — intentional-stop 목록에 있음 (stop-session.sh --remove 로 재활성화 가능)"
                continue
            fi
        fi

        # claude project 파일 있으면 --continue
        if [ -d "$PROJ_PATH/.claude/projects" ] && ls "$PROJ_PATH/.claude/projects"/*.jsonl 2>/dev/null | head -1 | grep -q .; then
            CLAUDE_CMD="claude --dangerously-skip-permissions --continue"
        else
            CLAUDE_CMD="claude --dangerously-skip-permissions"
        fi

        # 이미 같은 이름의 창이 있으면 생성 skip (중복 방지)
        if tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qxF "$PROFILE_NAME"; then
            log "SKIP $PROFILE_NAME — 이미 창 있음"
            continue
        fi
        # BUG-B fix (auto-restore): -P -F '#{window_id}' 로 즉시 ID 캡처 → auto-rename race 제거
        WIN_ID_AR=$(tmux new-window -t "$SESSION_NAME" -n "$PROFILE_NAME" -c "$PROJ_PATH" -P -F '#{window_id}' 2>/dev/null || true)
        if [ -n "$WIN_ID_AR" ]; then
            tmux set-window-option -t "$WIN_ID_AR" automatic-rename off 2>/dev/null || true
            tmux rename-window -t "$WIN_ID_AR" "$PROFILE_NAME" 2>/dev/null || true
            _SAFE_PN=$(printf '%q' "$PROFILE_NAME")
            tmux send-keys -t "$WIN_ID_AR" \
                "sleep $DELAY && (bash ~/.claude/scripts/tab-status.sh starting ${_SAFE_PN} 2>/dev/null || true) && unset CLAUDECODE && $CLAUDE_CMD" Enter
        else
            log "WARN: $PROFILE_NAME 창 생성 실패 (tmux new-window)"
        fi

        TOTAL_CREATED=$((TOTAL_CREATED + 1))
        DELAY=$((DELAY + 3))
        log "창 생성: $SESSION_NAME/$PROFILE_NAME (delay ${DELAY}s)"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [tmux-window] CREATE session=$SESSION_NAME window=$PROFILE_NAME" >> "$WELOG"
    done

    # monitor 창을 맨 마지막에 추가 + _init_ 임시 창 제거
    # BUG-B fix: -P -F '#{window_id}' 즉시 캡처 → auto-rename race 제거
    # BUG-MONITOR-DUP fix: 이미 monitor 창이 있으면 재생성 안 함 (--force 중복 방지)
    EXISTING_MON_ID=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' '$2=="monitor"{print $1; exit}')
    if [ -n "$EXISTING_MON_ID" ]; then
        MON_WIN_ID="$EXISTING_MON_ID"
        log "$SESSION_NAME monitor 창 이미 존재 ($MON_WIN_ID) — 재사용"
    else
        # BUG-MONITOR-CMD fix: 명령 인수 포함 시 -P -F #{window_id} 출력 안됨 → 창 생성 후 send-keys
        MON_WIN_ID=$(tmux new-window -d -t "$SESSION_NAME" -n monitor -c "$HOME/claude" -P -F '#{window_id}' 2>/dev/null || true)
        [ -n "$MON_WIN_ID" ] && tmux send-keys -t "$MON_WIN_ID" "while true; do sleep 86400; done" Enter 2>/dev/null || true
    fi
    if [ -n "$MON_WIN_ID" ]; then
        tmux set-window-option -t "$MON_WIN_ID" automatic-rename off 2>/dev/null || true
        tmux rename-window -t "$MON_WIN_ID" "monitor" 2>/dev/null || true
        tmux move-window -s "$MON_WIN_ID" -t "$SESSION_NAME:999" 2>/dev/null || true
    else
        tmux set-window-option -t "$SESSION_NAME:monitor" automatic-rename off 2>/dev/null || true
        tmux move-window -s "$SESSION_NAME:monitor" -t "$SESSION_NAME:999" 2>/dev/null || true
    fi
    # BUG-INIT-RENAME fix: 이름 기반 kill 실패 대비 → window_id 기반 fallback
    INIT_WIN_ID=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}|#{window_name}' 2>/dev/null | awk -F'|' '$2=="_init_"{print $1; exit}')
    if [ -n "$INIT_WIN_ID" ]; then
        tmux kill-window -t "$INIT_WIN_ID" 2>/dev/null || true
    else
        # 이름 기반 fallback (renamed to zsh 등)
        tmux kill-window -t "$SESSION_NAME:_init_" 2>/dev/null || true
        # index 0 창이 "zsh"면 profile/monitor 창만 남기고 제거
        STALE_ID=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}|#{window_name}|#{window_index}' 2>/dev/null | awk -F'|' '$3=="0" && $2!="monitor" && $2!="_init_"{print $1; exit}')
        [ -n "$STALE_ID" ] && tmux kill-window -t "$STALE_ID" 2>/dev/null || true
    fi
    log "$SESSION_NAME monitor 창 index 999에 배치 완료"

done <<< "$GROUPS_JSON"

# active-sessions.json 초기화 (이전 PID로 인한 watchdog 오탐 방지)
python3 -c "
import json, os, tempfile
from datetime import datetime, timezone
path = os.path.expanduser('~/.claude/active-sessions.json')
data = {'sessions': [], 'last_updated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'version': '1.0'}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
" 2>/dev/null || true

# intentional-stops.json — 48시간 이상 된 항목만 제거 (최근 의도적 중지는 보존)
if [ -f "$STOPS_FILE" ]; then
    _AR_SF="$STOPS_FILE" python3 -c "
import json, os, tempfile
from datetime import datetime, timezone, timedelta
path = os.environ['_AR_SF']
try:
    with open(path) as _f:
        data = json.load(_f)
    cutoff = datetime.now(timezone.utc) - timedelta(hours=48)
    stops = data.get('stops', [])
    kept = [s for s in stops if datetime.fromisoformat(s.get('stopped_at','1970-01-01T00:00:00Z').replace('Z','+00:00')) > cutoff]
    data['stops'] = kept
    data['last_updated'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
except:
    pass
" 2>/dev/null || true
    log "intentional-stops.json 48시간 TTL 정리 완료"
fi

# 세션 상태 확인 + 중복 창 제거 (window ID 기반 — 인덱스 재배열 문제 방지)
# linked view sessions(-vN)은 스킵 (dedup/monitor 불필요)
sleep 3
for SNAME in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Ev '.*-v[0-9]+$'); do
    log "DEDUP 전 $SNAME 창 목록: $(tmux list-windows -t "$SNAME" -F '#{window_id}:#{window_name}' 2>/dev/null | tr '\n' ' ')"

    # monitor 창 복구: 없으면 index 999에 재생성
    # BUG-B fix: -P -F '#{window_id}' 즉시 캡처 → auto-rename race 제거
    if ! tmux list-windows -t "$SNAME" -F '#{window_name}' 2>/dev/null | grep -qxF "monitor"; then
        # BUG-MONITOR-CMD fix: 창 생성 후 send-keys로 명령 전송
        _MON_WID_AR=$(tmux new-window -d -t "$SNAME" -n monitor -c "$HOME/claude" -P -F '#{window_id}' 2>/dev/null || true)
        [ -n "$_MON_WID_AR" ] && tmux send-keys -t "$_MON_WID_AR" "while true; do sleep 86400; done" Enter 2>/dev/null || true
        if [ -n "$_MON_WID_AR" ]; then
            tmux set-window-option -t "$_MON_WID_AR" automatic-rename off 2>/dev/null || true
            tmux rename-window -t "$_MON_WID_AR" monitor 2>/dev/null || true
            tmux move-window -s "$_MON_WID_AR" -t "$SNAME:999" 2>/dev/null || true
        fi
        log "$SNAME monitor 창 복구 (index 999)"
    else
        # monitor가 999번이 아니면 이동
        # BUG-DEDUP-REGEX fix: /monitor/ 정규식 → 정확 매칭 (terminal-mirror 등 오탐 방지)
        MON_IDX=$(tmux list-windows -t "$SNAME" -F '#{window_index}|#{window_name}' 2>/dev/null | awk -F'|' '$2=="monitor"{print $1}')
        if [ -n "$MON_IDX" ] && [ "$MON_IDX" != "999" ]; then
            tmux move-window -s "$SNAME:monitor" -t "$SNAME:999" 2>/dev/null || true
            log "$SNAME monitor $MON_IDX → 999 이동"
        fi
    fi
    SEEN_NAMES=""
    while IFS='|' read -r win_id name; do
        [ -z "$name" ] && continue
        # monitor 창은 절대 삭제하지 않음
        if [ "$name" = "monitor" ]; then
            SEEN_NAMES="${SEEN_NAMES}${name}
"
            continue
        fi
        if echo "$SEEN_NAMES" | grep -qxF "$name"; then
            # window ID 기반 삭제 (인덱스 재배열 무관)
            tmux kill-window -t "$win_id" 2>/dev/null
            log "DEDUP: $SNAME/$name (ID $win_id) 제거"
        else
            SEEN_NAMES="${SEEN_NAMES}${name}
"
        fi
    done < <(tmux list-windows -t "$SNAME" -F '#{window_id}|#{window_name}' 2>/dev/null)
    WIN_COUNT=$(tmux list-windows -t "$SNAME" 2>/dev/null | wc -l | tr -d ' ')
    log "$SNAME: ${WIN_COUNT}개 창 활성"
done

# Notion 기록
if [ -n "$NOTION_API_KEY" ] && [ -f "$HOME/claude/TP_skills/session-manager/notion-advanced.py" ]; then
    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
        "TP_iTerm" "Reboot Recovery (tmux)" "window-groups 기반 ${TOTAL_CREATED}개 세션 복원" 2>/dev/null || true
fi

# auto-attach.sh에 신호: 플래그 파일 생성 (30분 유효)
echo "$(date +%s)" > "$HOME/.claude/logs/.auto-restore-done"
log "auto-attach 트리거 플래그 생성 완료"

log "=== Auto-Restore 완료: ${TOTAL_CREATED}개 창 복원 ==="
# 윈도우 이벤트 로그
WELOG="$HOME/.claude/logs/window-events.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-restore] COMPLETE uptime=${UPTIME_SEC}s created=${TOTAL_CREATED} trigger=$([ "$UPTIME_SEC" -lt 300 ] && echo boot || echo manual)" >> "$WELOG"
