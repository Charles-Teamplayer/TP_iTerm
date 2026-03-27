# Session State (Auto-saved at compact)
> Generated: 2026-03-27 15:50:48
> Project: TP_iTerm

## 현재 완성도: ~97%

## 이번 세션 처리 이력 (iter33-34)

### iter33 수정
- **BUG-SENDKEYS-NOTARGET**: launchProfile/createSession에서 `\;` tmux 체인에 send-keys `-t` 없음
  → 외부 실행 시 pane 못 찾아 Claude Code 미시작 (ims_Auto_Contact APP 미생성 근본원인)
  → `new-window -P -F '#{window_index}'`로 index 캡처 후 `-t session:$_WIDX` 명시
- **BUG-INIT-RENAME**: auto-restore.sh `_init_` 창 automatic-rename off 추가 + window_id 기반 kill

### iter34 수정
- **BUG-ITERM-GROUPTABS**: openITermTabs에서 각 탭마다 별도 `tell newWin` 블록 사용
  → newWin 레퍼런스 불안정 시 각 탭이 새 iTerm 창으로 열리는 버그
  → 단일 `tell newWin` 블록 + `delay 1` 추가
- **스테일 zsh 창**: claude-work:0, claude-takedown:0 스테일 창 수동 제거

## 현재 tmux 상태
### claude-work
- 1: teamplean-website
- 2: universalMAC_Converter_gensys_calude
- 3: ims_Auto_Contact APP
- 4: AppleTV_ScreenSaver.app
- 999: monitor

### claude-takedown
- 1: terminal-mirror
- 2: TP_skills
- 3: TP_MDM
- 4: TP_MindMap_AutoCC
- 999: monitor

## 잔여 갭 (검증 필요)
- G1: 부팅 cycle 실제 테스트 (reboot 없이 불가)
- G2: CC 모드 연결 상태에서 Start Group 중복 창 방지 검증
- G3: auto-restore.sh 완전 복원 경로 재검증

## Recovery
압축 후 맥락이 부족하면:
1. 이 파일을 Read
2. ~/claude/TP_skills/projects/50_session_manager.md Read
