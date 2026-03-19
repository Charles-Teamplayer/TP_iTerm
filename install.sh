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
mkdir -p "$SCRIPTS_DIR" "$CLAUDE_DIR/logs" "$CLAUDE_DIR/tab-states" "$LAUNCH_DIR"

# 2. 스크립트 복사 + 실행 권한
for f in "$SCRIPT_DIR"/scripts/*.sh; do
    cp "$f" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/$(basename "$f")"
    echo "  ✓ $(basename "$f")"
done

# 3. LaunchAgent plist 복사 (경로를 현재 사용자로 치환)
CURRENT_USER=$(whoami)
CURRENT_HOME="$HOME"

for f in "$SCRIPT_DIR"/configs/com.claude.*.plist; do
    BASENAME=$(basename "$f")
    sed "s|/Users/teample.casper|${CURRENT_HOME}|g" "$f" > "$LAUNCH_DIR/$BASENAME"
    echo "  ✓ $BASENAME"
done

# 4. auto-restore.sh 내 프로젝트 경로 안내
echo ""
echo "⚠️  auto-restore.sh의 PROJECTS 배열을 이 Mac의 프로젝트 경로로 수정하세요:"
echo "    $SCRIPTS_DIR/auto-restore.sh"
echo ""

# 5. iTerm2 tmux integration 설정 (탭으로 열기 + 대시보드 방지)
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 1
defaults write com.googlecode.iterm2 TmuxDashboardLimit -int 20
defaults write com.googlecode.iterm2 OpenTmuxDashboardIfHiddenWindows -bool false
echo "  ✓ iTerm2 tmux 탭 모드 설정 (TmuxDashboardLimit=20, 대시보드 비활성화)"

# 6. LaunchAgent 등록
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
echo "  ✓ iTerm2 tmux 탭 모드 자동 설정됨 (OpenTmuxWindowsIn=1)"
echo ""
echo "테스트: launchctl list | grep com.claude"
