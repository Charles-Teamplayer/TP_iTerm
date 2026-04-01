#!/bin/bash
# stop-session.sh — intentional-stop 관리 CLI
# 사용법:
#   ./stop-session.sh imsms          프로젝트를 정지 목록에 추가 (다음 복원 시 제외)
#   ./stop-session.sh --list         현재 정지 목록 확인
#   ./stop-session.sh --remove imsms 특정 프로젝트를 정지 목록에서 제거
#   ./stop-session.sh --clear        전체 정지 목록 초기화

STOPS_FILE="$HOME/.claude/intentional-stops.json"

# 정지 목록 초기화 함수
init_stops() {
    if [ ! -f "$STOPS_FILE" ]; then
        echo '{"stops":[],"last_updated":""}' > "$STOPS_FILE"
    fi
}

# BUG#22 fix: VALID_WINDOWS 하드코딩 제거 → window-groups.json + activated-sessions.json 동적 읽기
# iter90: BUG-JSON-PARSING-SILENT fix — 파일 없음/파싱 오류 시 명시적 에러 메시지
get_valid_windows() {
    python3 -c "
import json, os, sys
result = set()

# window-groups.json에서 profileNames 수집
wg_path = os.path.expanduser('~/.claude/window-groups.json')
if os.path.exists(wg_path):
    try:
        with open(wg_path) as _wg:
            groups = json.load(_wg)
        for g in groups:
            for p in g.get('profileNames', []):
                result.add(p)
    except json.JSONDecodeError as e:
        print(f'ERROR: {wg_path} JSON 파싱 오류: {str(e)[:80]}', file=sys.stderr)
else:
    print(f'ERROR: {wg_path} 없음', file=sys.stderr)

# activated-sessions.json에서 basename 수집
as_path = os.path.expanduser('~/.claude/activated-sessions.json')
if os.path.exists(as_path):
    try:
        with open(as_path) as _as:
            d = json.load(_as)
        for p in d.get('activated', []):
            result.add(os.path.basename(p))
    except json.JSONDecodeError as e:
        print(f'WARNING: {as_path} JSON 파싱 오류: {str(e)[:80]}', file=sys.stderr)

for r in sorted(result):
    print(r)
" 2>&1
}

is_valid_window() {
    get_valid_windows 2>/dev/null | grep -qxF "$1"
}

case "${1:-}" in
    --list)
        init_stops
        echo "=== 의도적 정지 목록 ==="
        _SS_STOPS="$STOPS_FILE" python3 -c "
import json, os
with open(os.environ['_SS_STOPS']) as _f:
    d = json.load(_f)
stops = d.get('stops', [])
if not stops:
    print('  (없음) — 모든 프로젝트가 다음 복원 시 시작됩니다')
else:
    for s in stops:
        print(f\"  - {s.get('window_name','?')} ({s.get('stopped_at','?')[:10]})\")
    print(f'\n총 {len(stops)}개 프로젝트가 다음 복원에서 제외됩니다')
" 2>/dev/null
        ;;

    --clear)
        init_stops
        TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        echo "{\"stops\":[],\"last_updated\":\"${TS}\"}" > "$STOPS_FILE"
        echo "✅ 정지 목록 초기화 완료 — 다음 복원 시 모든 프로젝트 시작"
        ;;

    --remove)
        WINDOW="${2:-}"
        if [ -z "$WINDOW" ]; then
            echo "사용법: $0 --remove <window-name>"
            exit 1
        fi
        init_stops
        # iter59: BUG-INJECT-01 fix — 환경변수로 전달 (window name에 ' 또는 \ 포함 시 injection 방지)
        _REMOVE_WINDOW="$WINDOW" _STOPS_FILE="$STOPS_FILE" python3 -c "
import json, os, tempfile
stops_path = os.environ['_STOPS_FILE']
window = os.environ['_REMOVE_WINDOW']
with open(stops_path) as f:
    d = json.load(f)
before = len(d.get('stops', []))
d['stops'] = [s for s in d.get('stops', []) if s.get('window_name') != window]
after = len(d['stops'])
import datetime; d['last_updated'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(stops_path))
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.rename(tmp_path, stops_path)
if before > after:
    print(f'✅ {window} 제거됨 — 다음 복원 시 포함')
else:
    print(f'⚠️  {window} 목록에 없음')
" 2>/dev/null
        ;;

    "")
        echo "사용법:"
        echo "  $(basename "$0") <window-name>    정지 목록에 추가"
        echo "  $(basename "$0") --list           목록 확인"
        echo "  $(basename "$0") --remove <name>  목록에서 제거"
        echo "  $(basename "$0") --clear          전체 초기화"
        echo ""
        echo "유효한 window 이름 (window-groups.json 기준):"
        get_valid_windows | while read -r w; do echo "  $w"; done
        exit 0
        ;;

    *)
        WINDOW="$1"
        if ! is_valid_window "$WINDOW"; then
            echo "⚠️  알 수 없는 window: $WINDOW"
            echo "유효한 이름: $(get_valid_windows | tr '\n' ' ')"
            exit 1
        fi
        init_stops
        # iter59: BUG-INJECT-02 fix — 환경변수 방식으로 injection 방지
        _STOP_WINDOW="$WINDOW" _STOPS_FILE="$STOPS_FILE" python3 -c "
import json, os, tempfile, datetime
stops_path = os.environ['_STOPS_FILE']
window = os.environ['_STOP_WINDOW']
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
with open(stops_path) as f:
    d = json.load(f)
d['stops'] = [s for s in d.get('stops', []) if s.get('window_name') != window]
d['stops'].append({'project': window, 'window_name': window, 'stopped_at': ts})
d['last_updated'] = ts
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(stops_path))
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.rename(tmp_path, stops_path)
print(f'✅ {window} → 정지 목록 추가됨 (다음 복원 시 제외)')
" 2>/dev/null
        ;;
esac
