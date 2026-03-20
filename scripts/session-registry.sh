#!/bin/bash
# Session Registry Manager (URD-4 관할)
# 사용법: session-registry.sh register|unregister|list|crash-detect

REGISTRY="$HOME/.claude/active-sessions.json"
ACTION="${1:-list}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
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

        python3 << PYEOF
import json, os
registry_path = "$REGISTRY"
with open(registry_path, 'r') as f:
    data = json.load(f)

# 같은 프로젝트의 기존 세션 제거
data['sessions'] = [s for s in data['sessions'] if s.get('dir') != "$PROJECT_DIR"]

# 새 세션 등록
data['sessions'].append({
    "project": "$PROJECT_NAME",
    "dir": "$PROJECT_DIR",
    "pid": "${PID:-unknown}",
    "tty": "${SESSION_TTY:-}",
    "started": "$TIMESTAMP",
    "last_heartbeat": "$TIMESTAMP"
})
data['last_updated'] = "$TIMESTAMP"

with open(registry_path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f"[URD] Session registered: $PROJECT_NAME (PID: ${PID:-unknown})")
PYEOF
        ;;

    unregister)
        # 세션 해제 (내부용 — intentional-stop에서 호출)
        python3 << PYEOF
import json
registry_path = "$REGISTRY"
with open(registry_path, 'r') as f:
    data = json.load(f)

before = len(data['sessions'])
data['sessions'] = [s for s in data['sessions'] if s.get('dir') != "$PROJECT_DIR"]
after = len(data['sessions'])
data['last_updated'] = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

with open(registry_path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

if before > after:
    print(f"[URD] Session unregistered: $PROJECT_NAME")
else:
    print(f"[URD] Session not found: $PROJECT_NAME")
PYEOF
        ;;

    intentional-stop)
        # 의도적 종료 (Stop hook에서 호출) — unregister + 제외 목록 기록
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        STOPS_FILE="$HOME/.claude/intentional-stops.json"

        # 먼저 unregister 실행
        python3 << PYEOF
import json
registry_path = "$REGISTRY"
with open(registry_path, 'r') as f:
    data = json.load(f)

before = len(data['sessions'])
data['sessions'] = [s for s in data['sessions'] if s.get('dir') != "$PROJECT_DIR"]
after = len(data['sessions'])
data['last_updated'] = "$TIMESTAMP"

with open(registry_path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

if before > after:
    print(f"[URD] Session unregistered: $PROJECT_NAME")
PYEOF

        # intentional-stops.json에 기록
        python3 << PYEOF
import json, os, tempfile

stops_path = "$STOPS_FILE"
project_dir = "$PROJECT_DIR"
timestamp = "$TIMESTAMP"

# dir → window_name 매핑
DIR_TO_WINDOW = {
    os.path.expanduser("~/claude/TP_newIMSMS"): "imsms",
    os.path.expanduser("~/claude/TP_newIMSMS_Agent"): "imsms-agent",
    os.path.expanduser("~/claude/TP_MDM"): "mdm",
    os.path.expanduser("~/claude/TP_TESLA_LVDS"): "tesla-lvds",
    os.path.expanduser("~/ralph-claude-code/TESLA_Status_Dashboard"): "tesla-dashboard",
    os.path.expanduser("~/claude/TP_MindMap_AutoCC"): "mindmap",
    os.path.expanduser("~/SJ_MindMap"): "sj-mindmap",
    os.path.expanduser("~/claude/TP_A.iMessage_standalone_01067051080"): "imessage",
    os.path.expanduser("~/claude/TP_BTT"): "btt",
    os.path.expanduser("~/claude/TP_Infra_reduce_Project"): "infra",
    os.path.expanduser("~/claude/TP_skills"): "skills",
    os.path.expanduser("~/claude/AppleTV_ScreenSaver.app"): "appletv",
    os.path.expanduser("~/claude/imsms.im-website"): "imsms-web",
    os.path.expanduser("~/claude/TP_iTerm"): "auto-restart",
}

window_name = DIR_TO_WINDOW.get(project_dir)

# 알 수 없는 프로젝트 경로는 intentional-stop 등록 건너뜀 (노이즈 방지)
if not window_name:
    import sys
    print(f"[URD] SKIP intentional-stop: unknown dir {project_dir}", file=sys.stderr)
    sys.exit(0)

# 기존 파일 로드 또는 초기화
if os.path.exists(stops_path):
    with open(stops_path, 'r') as f:
        data = json.load(f)
else:
    data = {"stops": [], "last_updated": ""}

# 같은 window_name 중복 제거
data['stops'] = [s for s in data['stops'] if s.get('window_name') != window_name]

# 새 항목 추가
data['stops'].append({
    "project": os.path.basename(project_dir),
    "dir": project_dir,
    "window_name": window_name,
    "stopped_at": timestamp
})
data['last_updated'] = timestamp

# atomic write
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(stops_path))
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.rename(tmp_path, stops_path)

print(f"[URD] Intentional stop recorded: {window_name} ({os.path.basename(project_dir)})")
PYEOF
        ;;

    crash-detect)
        # 크래시 감지 (watchdog에서 호출)
        python3 << PYEOF
import json, subprocess, os

registry_path = "$REGISTRY"
with open(registry_path, 'r') as f:
    data = json.load(f)

crashed = []
alive = []

for session in data['sessions']:
    pid = session.get('pid', '')
    if pid and pid != 'unknown':
        try:
            os.kill(int(pid), 0)
            alive.append(session)
        except PermissionError:
            alive.append(session)  # 다른 유저 프로세스지만 살아있음
        except (ProcessLookupError, ValueError):
            crashed.append(session)
    else:
        # PID 모를 때는 프로젝트 디렉토리 경로로 확인 (TTY 있는 프로세스만)
        session_dir = session.get('dir', '')
        project_name = session.get('project', '')
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
            crashed.append(session)

if crashed:
    for s in crashed:
        print(f"[URD] CRASH DETECTED: {s['project']} (PID: {s.get('pid', '?')}, TTY: {s.get('tty', '?')}, started: {s.get('started', '?')})")

    # 크래시된 세션 제거
    data['sessions'] = alive
    data['last_updated'] = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    with open(registry_path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

if not crashed:
    print("[URD] All sessions alive")
PYEOF
        ;;

    heartbeat)
        # heartbeat 갱신 (UserPromptSubmit hook에서 호출)
        python3 << PYEOF
import json
registry_path = "$REGISTRY"
with open(registry_path, 'r') as f:
    data = json.load(f)

for s in data['sessions']:
    if s.get('dir') == "$PROJECT_DIR":
        s['last_heartbeat'] = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        break

with open(registry_path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
        ;;

    age-check)
        # 세션 경과 시간 확인 (watchdog에서 호출)
        python3 << PYEOF
import json
from datetime import datetime, timezone

registry_path = "$REGISTRY"
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
        if age_hours >= 168:  # 7일
            print(f"STALE:{project}:{tty}")
        elif age_hours >= 24:  # 1일
            print(f"IDLE:{project}:{tty}")
    except Exception:
        pass
PYEOF
        ;;

    list)
        # 세션 목록 출력
        python3 << PYEOF
import json
registry_path = "$REGISTRY"
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
