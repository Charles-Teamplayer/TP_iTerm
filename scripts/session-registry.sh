#!/bin/bash
# Session Registry Manager (URD-4 관할)
# 사용법: session-registry.sh register|unregister|list|crash-detect

REGISTRY="$HOME/.claude/active-sessions.json"
ACTION="${1:-list}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# 앱에서 두 번째 인자로 PROJECT_DIR을 전달하는 경우 우선 사용
[ -n "$2" ] && PROJECT_DIR="$2"
PROJECT_NAME=$(basename "$PROJECT_DIR")

# 레지스트리 초기화
if [ ! -f "$REGISTRY" ]; then
    echo '{"sessions":[],"last_updated":"","version":"1.0"}' > "$REGISTRY"
fi

case "$ACTION" in
    register)
        # 세션 등록 (SessionStart hook에서 호출)
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        # 부모 PID 체인으로 현재 세션의 claude PID 찾기
        PID=""
        SESSION_TTY=""
        SEARCH_PID=$$
        for _i in 1 2 3 4 5 6 7 8; do
            SEARCH_PID=$(ps -o ppid= -p "$SEARCH_PID" 2>/dev/null | tr -d ' ')
            [ -z "$SEARCH_PID" ] && break
            CMD=$(ps -o comm= -p "$SEARCH_PID" 2>/dev/null)
            if echo "$CMD" | grep -q "claude" 2>/dev/null; then
                PID="$SEARCH_PID"
                break
            fi
        done
        # PID 못 찾으면 fallback — TTY가 있는 claude 프로세스만 선택
        if [ -z "$PID" ]; then
            PID=$(ps -ax -o pid=,tty=,command= | grep "[c]laude" | grep -v "??" | grep -v "Claude.app\|Helper\|watchdog\|auto-restore" | awk '{print $1}' | tail -1)
        fi
        if [ -n "$PID" ]; then
            SESSION_TTY=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
            [ "$SESSION_TTY" = "??" ] && SESSION_TTY=""
        fi

        REG_REGISTRY="$REGISTRY" \
        REG_PROJECT_DIR="$PROJECT_DIR" \
        REG_PROJECT_NAME="$PROJECT_NAME" \
        REG_PID="${PID:-unknown}" \
        REG_TTY="${SESSION_TTY:-}" \
        REG_TIMESTAMP="$TIMESTAMP" \
        python3 << 'PYEOF'
import json, os, tempfile

registry_path = os.environ['REG_REGISTRY']
project_dir = os.environ['REG_PROJECT_DIR']
project_name = os.environ['REG_PROJECT_NAME']
pid = os.environ['REG_PID']
tty = os.environ['REG_TTY']
timestamp = os.environ['REG_TIMESTAMP']

with open(registry_path, 'r') as f:
    data = json.load(f)

data['sessions'] = [s for s in data['sessions'] if s.get('dir') != project_dir]

data['sessions'].append({
    "project": project_name,
    "dir": project_dir,
    "pid": pid,
    "tty": tty,
    "started": timestamp,
    "last_heartbeat": timestamp
})
data['last_updated'] = timestamp

dir_name = os.path.dirname(registry_path)
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, registry_path)
except:
    os.unlink(tmp_path)
    raise

print(f"[URD] Session registered: {project_name} (PID: {pid})")
PYEOF
        # 보호 PID 파일 업데이트: 활성 세션 PID를 ~/.claude/protected-claude-pids 에 기록
        # flock 기반 원자적 업데이트 — 다중 세션 동시 register 시 race condition 방지
        if [ -n "$PID" ] && [ "$PID" != "unknown" ]; then
            PROTECTED_FILE="$HOME/.claude/protected-claude-pids"
            PROTECTED_LOCK="/tmp/.protected-pids.lock"
            (
                flock -x 9
                {
                    [ -f "$PROTECTED_FILE" ] && grep -v '^$' "$PROTECTED_FILE"
                    echo "$PID"
                } | sort -u | while read -r pp; do
                    kill -0 "$pp" 2>/dev/null && echo "$pp"
                done > "${PROTECTED_FILE}.tmp" 2>/dev/null && mv "${PROTECTED_FILE}.tmp" "$PROTECTED_FILE" 2>/dev/null || true
            ) 9>"$PROTECTED_LOCK" 2>/dev/null || true
        fi
        # BUG-INTENTIONAL-STOP-CLEAR fix: 세션 등록 시 intentional-stops.json에서 해당 프로젝트 제거
        # 사용자가 의도적으로 세션을 다시 열었으면, 이전 intentional-stop 기록은 무효화해야 함
        STOPS_FILE_REG="$HOME/.claude/intentional-stops.json"
        if [ -f "$STOPS_FILE_REG" ]; then
            WINDOW_NAME_REG=$(basename "$PROJECT_DIR")
            python3 -c "
import json, os, tempfile, sys
path = os.path.expanduser('~/.claude/intentional-stops.json')
window_name = sys.argv[1]
try:
    with open(path, 'r') as f:
        data = json.load(f)
    before = len(data.get('stops', []))
    data['stops'] = [s for s in data.get('stops', []) if s.get('window_name', '') != window_name]
    after = len(data.get('stops', []))
    if before != after:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, path)
        print(f'[URD] intentional-stop cleared: {window_name}')
except Exception as e:
    pass
" "$WINDOW_NAME_REG" 2>/dev/null || true
        fi
        # 크래시 카운터: 등록 후 5분 이상 경과해야 리셋 (빠른 크래시 루프 방지)
        CRASH_COUNT_FILE="$HOME/.claude/crash-counts/${PROJECT_NAME//[^a-zA-Z0-9_-]/_}"
        if [ -f "$CRASH_COUNT_FILE" ]; then
            CC_LAST_TS=$(cut -d'|' -f2 "$CRASH_COUNT_FILE" 2>/dev/null || echo 0)
            CC_REG_NOW=$(date +%s)
            if [ $(( CC_REG_NOW - ${CC_LAST_TS:-0} )) -gt 300 ]; then
                rm -f "$CRASH_COUNT_FILE"
            fi
        fi
        ;;

    unregister)
        # 세션 해제 (내부용 — intentional-stop에서 호출)
        UNREG_REGISTRY="$REGISTRY" \
        UNREG_PROJECT_DIR="$PROJECT_DIR" \
        UNREG_PROJECT_NAME="$PROJECT_NAME" \
        UNREG_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        python3 << 'PYEOF'
import json, os, tempfile

registry_path = os.environ['UNREG_REGISTRY']
project_dir = os.environ['UNREG_PROJECT_DIR']
project_name = os.environ['UNREG_PROJECT_NAME']
timestamp = os.environ['UNREG_TIMESTAMP']

with open(registry_path, 'r') as f:
    data = json.load(f)

before = len(data['sessions'])
data['sessions'] = [s for s in data['sessions'] if s.get('dir') != project_dir]
after = len(data['sessions'])
data['last_updated'] = timestamp

dir_name = os.path.dirname(registry_path)
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, registry_path)
except:
    os.unlink(tmp_path)
    raise

if before > after:
    print(f"[URD] Session unregistered: {project_name}")
else:
    print(f"[URD] Session not found: {project_name}")
PYEOF
        ;;

    intentional-stop)
        # 의도적 종료 (Stop hook에서 호출) — unregister + 제외 목록 기록
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        STOPS_FILE="$HOME/.claude/intentional-stops.json"

        # 현재 claude PID 찾기 (Race condition fix: Stop hook이 뒤늦게 실행될 때 새 세션 등록 보호)
        IS_CURRENT_PID=""
        _SRCH_PID=$$
        for _i in 1 2 3 4 5 6; do
            _SRCH_PID=$(ps -o ppid= -p "$_SRCH_PID" 2>/dev/null | tr -d ' ')
            [ -z "$_SRCH_PID" ] && break
            _SRCH_CMD=$(ps -o comm= -p "$_SRCH_PID" 2>/dev/null)
            if echo "$_SRCH_CMD" | grep -q "claude" 2>/dev/null; then
                IS_CURRENT_PID="$_SRCH_PID"
                break
            fi
        done

        # 먼저 unregister 실행
        IS_REGISTRY="$REGISTRY" \
        IS_PROJECT_DIR="$PROJECT_DIR" \
        IS_PROJECT_NAME="$PROJECT_NAME" \
        IS_TIMESTAMP="$TIMESTAMP" \
        IS_STOPS_FILE="$STOPS_FILE" \
        IS_CURRENT_PID="$IS_CURRENT_PID" \
        python3 << 'PYEOF'
import json, os, sys, tempfile

registry_path = os.environ['IS_REGISTRY']
project_dir = os.environ['IS_PROJECT_DIR']
project_name = os.environ['IS_PROJECT_NAME']
timestamp = os.environ['IS_TIMESTAMP']
stops_path = os.environ['IS_STOPS_FILE']
current_pid = os.environ.get('IS_CURRENT_PID', '').strip()

# unregister — Race condition fix: Ralph Loop 재시작 시 새 세션이 이미 등록된 경우 스킵
with open(registry_path, 'r') as f:
    data = json.load(f)

matched = next((s for s in data['sessions'] if s.get('dir') == project_dir), None)
skip_unregister = False
if matched and current_pid:
    reg_pid = str(matched.get('pid', '')).strip()
    if reg_pid and reg_pid != current_pid:
        # 새 세션이 이미 다른 PID로 등록됨 → unregister 스킵
        print(f"[URD] SKIP unregister: {project_name} (reg_pid={reg_pid}, current={current_pid})")
        skip_unregister = True

if not skip_unregister:
    before = len(data['sessions'])
    data['sessions'] = [s for s in data['sessions'] if s.get('dir') != project_dir]
    after = len(data['sessions'])
    data['last_updated'] = timestamp

    dir_name = os.path.dirname(registry_path)
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, registry_path)
    except:
        os.unlink(tmp_path)
        raise

    if before > after:
        print(f"[URD] Session unregistered: {project_name}")

# dir → window_name 매핑 (profile name = window-groups.json profileNames 기준)
# BUG-REGMAP fix: basename과 다른 profile name만 명시 (나머지는 fallback basename 사용)
DIR_TO_WINDOW = {
    os.path.expanduser("~/claude/TP_A.iMessage_standalone_01067051080"): "a.imessage",
    os.path.expanduser("~/claude/AppleTV_ScreenSaver.app"): "AppleTV_ScreenSaver.app",
}

# BUG#27 fix: 하드코딩 맵에 없는 dir은 basename을 window_name으로 사용 (새 프로젝트 지원)
window_name = DIR_TO_WINDOW.get(project_dir) or os.path.basename(project_dir)
if not window_name:
    print(f"[URD] SKIP intentional-stop: unknown dir {project_dir}", file=sys.stderr)
    sys.exit(0)

# intentional-stops.json 기록
if os.path.exists(stops_path):
    with open(stops_path, 'r') as f:
        data = json.load(f)
else:
    data = {"stops": [], "last_updated": ""}

data['stops'] = [s for s in data['stops'] if s.get('window_name') != window_name]

data['stops'].append({
    "project": os.path.basename(project_dir),
    "dir": project_dir,
    "window_name": window_name,
    "stopped_at": timestamp
})
data['last_updated'] = timestamp

tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(stops_path))
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.rename(tmp_path, stops_path)

print(f"[URD] Intentional stop recorded: {window_name} ({os.path.basename(project_dir)})")
PYEOF
        ;;

    crash-detect)
        # 크래시 감지 (watchdog에서 호출)
        CD_REGISTRY="$REGISTRY" \
        CD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        python3 << 'PYEOF'
import json, subprocess, os, tempfile

registry_path = os.environ['CD_REGISTRY']
cd_timestamp = os.environ['CD_TIMESTAMP']
with open(registry_path, 'r') as f:
    data = json.load(f)

crashed = []
alive = []

# dir → tmux window_name 매핑 (2중 확인용, profile name = window-groups.json 기준)
# BUG-REGMAP fix: basename과 다른 profile name만 명시 (나머지는 fallback basename 사용)
DIR_TO_WINDOW = {
    os.path.expanduser("~/claude/TP_A.iMessage_standalone_01067051080"): "a.imessage",
    os.path.expanduser("~/claude/AppleTV_ScreenSaver.app"): "AppleTV_ScreenSaver.app",
}

# tmux 윈도우 목록 1회 캐시 (반복 호출 방지) — 모든 세션 포함
_tmux_windows = None
def get_tmux_windows():
    global _tmux_windows
    if _tmux_windows is None:
        windows = []
        import json as _json, os as _os
        _groups_path = _os.path.expanduser('~/.claude/window-groups.json')
        _active_sessions = []
        try:
            with open(_groups_path) as _f:
                _groups = _json.load(_f)
            for _g in _groups:
                _sn = _g.get('sessionName','')
                if not _g.get('isWaitingList', False) and _sn and _sn != '__waiting__':
                    _active_sessions.append(_sn)
        except Exception:
            pass
        if not _active_sessions:
            _active_sessions = ['claude-work']
        for session in _active_sessions:
            r = subprocess.run(
                ['tmux', 'list-windows', '-t', session, '-F', '#{window_name}'],
                capture_output=True, text=True
            )
            if r.returncode == 0:
                windows.extend(r.stdout.strip().splitlines())
        _tmux_windows = windows
    return _tmux_windows

def strip_prefix(name):
    """이모지/공백 접두사 제거 (tmux rename-window 이모지 포함 대응)"""
    import re
    return re.sub(r'^[\s\U00010000-\U0010FFFF\u2600-\u27FF\u2B00-\u2BFF]+', '', name).strip()

def tmux_window_exists(session_dir, project_name):
    """dir 또는 project_name으로 tmux 윈도우 존재 확인"""
    windows = get_tmux_windows()
    if not windows:
        return False
    # 이모지 제거한 클린 윈도우명 목록
    clean_windows = [strip_prefix(w) for w in windows if w]
    # 정확한 매핑으로 확인
    window_name = DIR_TO_WINDOW.get(session_dir)
    if window_name and window_name in clean_windows:
        return True
    # fallback: 프로젝트명 정확 매칭 (BUG-03 fix: 부분 문자열 fuzzy 매칭 → 오탐 방지)
    # "imsms" in "minimal-imsms-agent" 같은 false positive 제거
    proj_base = os.path.basename(project_name) if project_name else ''
    if proj_base and proj_base.lower() in [w.lower() for w in clean_windows if w]:
        return True
    return False

def is_claude_process(pid):
    """PID가 실제 claude CLI 프로세스인지 확인 (PID 재사용 오탐 방지)
    iter59: 느슨한 'claude' in cmd → 정확한 경로/바이너리명 매칭으로 개선"""
    try:
        r = subprocess.run(['ps', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True)
        cmd = r.stdout.strip()
        if not cmd:
            return False
        # claude CLI 바이너리 정확 매칭: /path/to/claude 또는 claude로 시작하는 명령
        import re
        # watchdog/auto-restore/tab-status 등 claude 관련 스크립트 제외
        exclude = ['watchdog', 'auto-restore', 'tab-focus', 'session-registry', 'health-check', 'cc-fix', 'MAGI']
        if any(x in cmd for x in exclude):
            return False
        return bool(re.search(r'(?:^|/)claude(?:\s|$|--)', cmd))
    except Exception:
        return False

for session in data['sessions']:
    pid = session.get('pid', '')
    session_dir = session.get('dir', '')
    project_name = session.get('project', '')

    if pid and pid != 'unknown':
        pid_alive = False
        try:
            pid_int = int(pid)
            # iter59: BUG-SR-01/02 fix — PID=0 또는 음수는 os.kill시 프로세스 그룹에 신호 전송 위험
            if pid_int <= 0:
                pid_alive = False
            else:
                os.kill(pid_int, 0)
                pid_alive = True
        except PermissionError:
            pid_alive = True
        except (ProcessLookupError, ValueError):
            pid_alive = False

        if pid_alive:
            # PID 재사용 검증: 살아있어도 claude 프로세스인지 확인
            if is_claude_process(int(pid)):
                alive.append(session)
            else:
                # PID 재사용됨 — tmux 윈도우로 2중 확인
                if tmux_window_exists(session_dir, project_name):
                    alive.append(session)
                else:
                    crashed.append(session)
        else:
            # PID 사망 — tmux 윈도우로 2중 확인 (CC 재시작 중일 수 있음)
            if tmux_window_exists(session_dir, project_name):
                alive.append(session)
            else:
                crashed.append(session)
    else:
        # PID 모를 때는 프로젝트 디렉토리 경로로 확인 (TTY 있는 프로세스만)
        generic_names = {'claude', 'node', 'python', 'bash', 'zsh', 'sh', 'npm'}
        if not session_dir or len(session_dir) < 10 or os.path.basename(session_dir) in generic_names:
            alive.append(session)
            continue
        if project_name and (len(project_name) <= 3 or project_name.lower() in generic_names):
            alive.append(session)
            continue
        result = subprocess.run(
            ['ps', '-ax', '-o', 'pid,tty,command'],
            capture_output=True, text=True
        )
        found = False
        for line in result.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) >= 3 and 'claude' in parts[2] and session_dir in parts[2] and parts[1] != '??':
                found = True
                break
        if found:
            alive.append(session)
        else:
            # PID unknown이고 ps에서 못 찾았을 때: tmux 윈도우 존재 확인 (오탐 방지)
            if tmux_window_exists(session_dir, project_name):
                alive.append(session)
            else:
                crashed.append(session)

if crashed:
    for s in crashed:
        print(f"[URD] CRASH DETECTED: {s['project']} (PID: {s.get('pid', '?')}, TTY: {s.get('tty', '?')}, started: {s.get('started', '?')})")

    # 크래시된 세션 제거
    data['sessions'] = alive
    data['last_updated'] = cd_timestamp
    dir_name = os.path.dirname(registry_path)
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, registry_path)
    except:
        os.unlink(tmp_path)
        raise

if not crashed:
    print("[URD] All sessions alive")
PYEOF
        ;;

    heartbeat)
        # heartbeat 갱신 (UserPromptSubmit hook에서 호출)
        HB_REGISTRY="$REGISTRY" \
        HB_PROJECT_DIR="$PROJECT_DIR" \
        HB_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        python3 << 'PYEOF'
import json, os, tempfile

registry_path = os.environ['HB_REGISTRY']
project_dir = os.environ['HB_PROJECT_DIR']
timestamp = os.environ['HB_TIMESTAMP']

with open(registry_path, 'r') as f:
    data = json.load(f)

for s in data['sessions']:
    if s.get('dir') == project_dir:
        s['last_heartbeat'] = timestamp
        break

dir_name = os.path.dirname(registry_path)
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, registry_path)
except:
    os.unlink(tmp_path)
    raise
PYEOF
        ;;

    age-check)
        # 세션 경과 시간 확인 (watchdog에서 호출)
        AC_REGISTRY="$REGISTRY" \
        python3 << 'PYEOF'
import json, os
from datetime import datetime, timezone

registry_path = os.environ['AC_REGISTRY']
with open(registry_path, 'r') as f:
    data = json.load(f)

now = datetime.now(timezone.utc)
for s in data['sessions']:
    hb = s.get('last_heartbeat', s.get('started', ''))
    if not hb:
        continue
    try:
        last = datetime.fromisoformat(hb.replace('Z', '+00:00'))
        age_hours = (now - last).total_seconds() / 3600
        project = s.get('project', '?')
        tty = s.get('tty', '')
        if age_hours >= 168:
            print(f"STALE:{project}:{tty}")
        elif age_hours >= 24:
            print(f"IDLE:{project}:{tty}")
    except Exception:
        pass
PYEOF
        ;;

    list)
        # 세션 목록 출력
        LIST_REGISTRY="$REGISTRY" \
        python3 << 'PYEOF'
import json, os

registry_path = os.environ['LIST_REGISTRY']
with open(registry_path, 'r') as f:
    data = json.load(f)

if not data['sessions']:
    print("[URD] No active sessions")
else:
    print(f"[URD] Active sessions ({len(data['sessions'])}): ")
    for s in data['sessions']:
        print(f"  - {s['project']} (PID: {s.get('pid', '?')}, dir: {s['dir']})")
PYEOF
        ;;
esac
