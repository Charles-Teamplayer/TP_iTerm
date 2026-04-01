#!/bin/bash
# Auto Commit Script
# 1시간마다 cron으로 실행됩니다.
#
# Cron 설정 방법:
#   crontab -e
#   0 * * * * bash ~/.claude/hooks/auto-commit.sh >> ~/claude/TP_history/_global/commits.log 2>&1

# set -e 제거 — git lock 등 개별 프로젝트 실패가 전체 중단시키지 않도록

# 설정
LOG_FILE="$HOME/claude/TP_history/_global/commits.log"
CLAUDE_PROJECTS_DIR="$HOME/claude"  # Claude 작업 디렉토리

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 로그 로테이션 (20000줄 초과 시 10000줄 유지)
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 20000 ] 2>/dev/null; then
    tail -10000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
fi

auto_commit_project() {
    local project_dir="$1"

    cd "$project_dir" || return 1

    # Git repo인지 확인
    if [ ! -d ".git" ]; then
        return 0
    fi

    # 변경사항 확인
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        return 0
    fi

    log "Changes detected in: $project_dir"

    # 변경된 파일 수 계산
    CHANGED_FILES=$(git status --porcelain | wc -l | tr -d ' ')

    # 커밋 메시지 생성
    COMMIT_MSG="Auto-commit: $CHANGED_FILES file(s) changed at $(date '+%Y-%m-%d %H:%M:%S')

🤖 Generated with Claude Code Auto-Commit

Co-Authored-By: Claude <noreply@anthropic.com>"

    # 커밋 및 푸시
    git add -A
    git commit -m "$COMMIT_MSG" 2>/dev/null || return 1

    # Remote가 있으면 push
    if git remote get-url origin &> /dev/null; then
        git push 2>/dev/null || log "Push failed for $project_dir"
    fi

    log "SUCCESS: Committed $CHANGED_FILES files in $project_dir"

    # Notion에 기록 (프로젝트별 페이지)
    if [ -n "$NOTION_API_KEY" ]; then
        PROJECT_NAME=$(basename "$project_dir")
        if [ -f "$HOME/claude/TP_skills/session-manager/notion-advanced.py" ]; then
            python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
                "$PROJECT_NAME" \
                "Auto Commit" \
                "$CHANGED_FILES files committed" \
                2>/dev/null || true
        elif [ -f "$HOME/.claude/hooks/notion-logger.py" ]; then
            python3 "$HOME/.claude/hooks/notion-logger.py" \
                "Auto Commit" \
                "$CHANGED_FILES files committed in $PROJECT_NAME" \
                2>/dev/null || true
        fi
    fi
}

# 메인 실행
log "=== Auto-commit started ==="

# CLAUDE_PROJECT_DIR가 설정되어 있으면 해당 프로젝트만 처리
if [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    auto_commit_project "$CLAUDE_PROJECT_DIR"
elif [ -d "$CLAUDE_PROJECTS_DIR" ]; then
    # Claude 작업 디렉토리의 모든 프로젝트 처리
    for dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        if [ -d "${dir}.git" ]; then
            auto_commit_project "$dir"
        fi
    done
fi

log "=== Auto-commit finished ==="
