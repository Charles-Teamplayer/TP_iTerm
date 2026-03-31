#!/bin/bash
# MAGI+NORN AutoRestart 설치 스크립트
# 사용법: git clone → bash install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

echo "=== MAGI+NORN AutoRestart 설치 ==="

# 1. 디렉토리 생성
mkdir -p "$SCRIPTS_DIR" "$CLAUDE_DIR/logs" "$CLAUDE_DIR/tab-states" \
         "$CLAUDE_DIR/tab-color/states" "$CLAUDE_DIR/tab-color/logs" "$LAUNCH_DIR"

# 2. 스크립트 복사 + 실행 권한 (.sh)
for f in "$SCRIPT_DIR"/scripts/*.sh; do
    cp "$f" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/$(basename "$f")"
    echo "  ✓ $(basename "$f")"
done

# 2a. Python 스크립트 복사 (.py)
for f in "$SCRIPT_DIR"/scripts/*.py; do
    [ -f "$f" ] || continue
    cp "$f" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/$(basename "$f")"
    echo "  ✓ $(basename "$f")"
done

# 2b. tab-color/ 서브디렉토리 복사 (엔진 + 설정)
if [ -d "$SCRIPT_DIR/scripts/tab-color" ]; then
    cp -R "$SCRIPT_DIR/scripts/tab-color" "$SCRIPTS_DIR/"
    echo "  ✓ tab-color/ (탭 색상 엔진)"
fi

# 3. LaunchAgent plist 복사 (경로를 현재 사용자로 치환)
CURRENT_USER=$(whoami)
CURRENT_HOME="$HOME"

for f in "$SCRIPT_DIR"/configs/com.claude.*.plist; do
    BASENAME=$(basename "$f")
    sed "s|/Users/teample.casper|${CURRENT_HOME}|g" "$f" > "$LAUNCH_DIR/$BASENAME"
    echo "  ✓ $BASENAME"
done

# 4. tab_focus_status.py 설치 스킵 — tab-focus-monitor.sh (bash LaunchAgent)으로 대체됨
# iter59: tab_focus_status.py는 .disabled 상태이며 좀비 프로세스 누적 원인 → 설치 불필요
# ITERM_AUTOLAUNCH 디렉토리만 확보 (다른 용도)
ITERM_AUTOLAUNCH="$HOME/.config/iterm2/AppSupport/Scripts/AutoLaunch"
mkdir -p "$ITERM_AUTOLAUNCH"
echo "  ✓ iTerm2 AutoLaunch 디렉토리 준비 (tab_focus_status.py는 tab-focus-monitor.sh로 대체)"

# 4b. settings.json 적용 안내 (자동 덮어쓰기 위험하므로 안내만)
if [ -f "$SCRIPT_DIR/configs/settings.json" ]; then
    echo ""
    echo "⚠️  ~/.claude/settings.json 설정이 필요합니다:"
    echo "    cp '$SCRIPT_DIR/configs/settings.json' ~/.claude/settings.json"
    echo "    (기존 설정이 있다면 수동으로 병합하세요)"
fi

# 5. TP_iTerm_Restore.app → /Applications 배포
REPO_APP="$SCRIPT_DIR/TP_iTerm_Restore.app"
APP_DEST="/Applications/TP_iTerm_Restore.app"
if [ -d "$REPO_APP" ]; then
    rm -rf "$APP_DEST" 2>/dev/null || true
    cp -R "$REPO_APP" "$APP_DEST"
    codesign --force --sign - --deep "$APP_DEST" 2>/dev/null || true
    echo "  ✓ TP_iTerm_Restore.app → /Applications"
else
    echo "  ⚠️  TP_iTerm_Restore.app 없음 — build-and-deploy.sh 먼저 실행하세요"
fi
echo ""

# 6. iTerm2 tmux integration 설정 (탭으로 열기 + 대시보드 방지)
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 1
defaults write com.googlecode.iterm2 TmuxDashboardLimit -int 20
defaults write com.googlecode.iterm2 OpenTmuxDashboardIfHiddenWindows -bool false
echo "  ✓ iTerm2 tmux 탭 모드 설정 (TmuxDashboardLimit=20, 대시보드 비활성화)"

# 7. tmux automatic-rename 비활성화 (창이름 보존)
if ! grep -q "automatic-rename" ~/.tmux.conf 2>/dev/null; then
    echo "set -g automatic-rename off" >> ~/.tmux.conf
    echo "  ✓ tmux automatic-rename off 설정 추가"
else
    echo "  ✓ tmux automatic-rename off 이미 설정됨"
fi
# 현재 실행 중인 claude-work 세션에도 적용
tmux set-option -t claude-work automatic-rename off 2>/dev/null || true

# 8. LaunchAgent 등록
UID_NUM=$(id -u)
for f in "$LAUNCH_DIR"/com.claude.*.plist; do
    LABEL=$(basename "$f" .plist)
    launchctl bootout "gui/$UID_NUM" "$f" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_NUM" "$f" 2>/dev/null || true
    echo "  ✓ $LABEL 등록"
done

echo ""
echo "=== 설치 완료 ==="
echo ""
echo "필수 확인사항:"
echo "  1. iTerm2 설치 필요 (Terminal.app 미지원)"
echo "  2. claude CLI 설치: npm install -g @anthropic-ai/claude-code"
echo "  3. Notion 연동 시: ~/.zshrc에 NOTION_API_KEY 설정"
echo "  4. ~/.claude/activated-sessions.json에 복원할 프로젝트 경로 추가"
echo "     (TP_iTerm_Restore.app → 세션탭 → 우클릭 활성화 또는 직접 편집)"
echo "  ✓ iTerm2 tmux 탭 모드 자동 설정됨 (TmuxDashboardLimit=20)"
echo ""
echo "첫 실행 순서:"
echo "  1. iTerm2 실행"
echo "  2. bash $SCRIPTS_DIR/auto-restore.sh  (tmux claude-work 세션 생성)"
echo "  3. TP_iTerm_Restore.app 메뉴바 → '지금 복원' 또는 설정창 → 세션복원"
echo ""
echo "헬스체크: bash $SCRIPTS_DIR/health-check.sh"
echo "LaunchAgent 확인: launchctl list | grep com.claude"
