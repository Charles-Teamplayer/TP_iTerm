---
name: MAGI-Restore-App 코드 품질 현황
description: MAGI-Restore-App SwiftUI 앱의 버그/크래시 위험/로직 오류 전수 검토 결과 (최신: 2026-03-28)
type: project
---

2026-03-28 심층 QA 검증 수행. 7개 카테고리 전수 점검.

**Why:** CEO 요청으로 세션별 윈도우 생성, monitor 배치, PID 보호, 중복방지, closeExistingITermWindows, ProfileService YAML, edge case 전수 점검.

**How to apply:** 향후 리뷰 시 아래 미수정 이슈 해결 여부 확인.

## 수정 확인된 이슈 (이전 리뷰 대비)
- ProfileService.parseYml() force unwrap → 제거됨 (currentRoot 옵셔널 처리)
- ShellService 하드코딩 nvm 경로 → 동적 탐색으로 개선 (fallback만 하드코딩)
- generateYml() 특수문자 처리 → : / " / ' 처리 추가됨
- BUG#30 shellEscape 일관 적용됨
- BUG#31 startGroup 중복 실행 방지 (startingGroups 집합) 구현됨

## 현재 잔존 이슈

### CRITICAL
- (없음)

### HIGH
- **launchProfile race condition**: L840 `grep -qxF` 체크와 `new-window` 사이 time-of-check-time-of-use gap 존재. 단일 shell 명령으로 atomic 처리하고 있으나, 동일 profileName이 두 그룹에 배정된 경우 두 그룹이 동시에 launchProfile을 호출하면 중복 창 생성 가능.
- **applyNow()에서 ensureMonitorWindow 미호출**: L1003-1010, applyNow()가 reorderTabs만 호출하고 ensureMonitorWindow를 호출하지 않음. reorderTabs 자체도 ensureMonitorWindow를 호출하지 않으므로 monitor=999 보장이 누락됨.
- **restoreSelected()에서 ensureMonitorWindow 미호출**: L497-577, 복원 완료 후 monitor 위치 보장 코드 없음.

### MEDIUM
- **updateProtectedPids()의 동기 실행**: L361-374, @MainActor 함수 내에서 ShellService.run() (동기) 두 번 호출 → UI 블로킹 위험. ps -A 전체 프로세스 목록은 최대 200ms+ 소요 가능.
- **killWaitingListWindows에서 protected PID 미체크**: L619-642, stopGroup/stopAllRunning은 loadProtectedPidSet() 호출하지만 killWaitingListWindows는 해당 체크 없이 `kill -TERM`으로 PID 종료.
- **purgeIdleZshWindows에서 protected TTY 범위 불충분**: L700-703, myPid의 TTY만 보호. parent chain의 TTY는 미보호.
- **closeExistingITermWindows allMissingTTY 탭 수 기준**: L1162, `tabCnt >= max(expectedTabs/2, 2)` — expectedTabs=1이면 max(0, 2)=2 이상이어야 하므로 단일 창 보호됨. 그러나 expectedTabs=3이면 기준=1 → 탭 2개짜리 창이 오판될 수 있음 (의도가 50%이므로 min 2 보장이 적절한지 재검토 필요).
- **checkAutoSync에서 추가 시 launchProfile 호출 → 내부에서 ensureMonitorWindow 호출됨** — 이 경로는 정상. 단, 제거(kill) 후 ensureMonitorWindow가 anyChange 블록에서 호출되는 것도 확인됨 (L972).

### LOW
- **SystemView.toggle() @MainActor 내 Task{}**: L95, @MainActor 컨텍스트에서 unstructured Task로 탈출 → daemon.isRunning 상태와 toggle 완료 타이밍 미스매치 가능.
- **ProfileService.save()가 항상 claude-work.yml에만 저장**: L61, 다중 세션 환경에서 save()가 claude-work.yml 단일 파일에만 씀. savePerSession()은 별도 호출 필요 — 프로필 추가/삭제 시 세션별 YAML 자동 갱신 안 됨.
- **generateYml() YAML 인젝션 미완**: L173-175, `:`와 `"`는 처리하지만 `\n`(개행), `#`(주석 시작) 등은 미처리.

## 정상 동작 확인 항목
- startGroup() 중복 실행 방지: startingGroups 집합으로 방어
- monitor 창 재생성: startGroup에서 기존 monitor kill 후 재생성 + 999 이동
- protected PID: stopGroup, stopAllRunning에서 loadProtectedPidSet() 적용
- launchProfile에서 ensureMonitorWindow 호출
- checkAutoSync에서 anyChange 시 ensureMonitorWindow 호출
- window-groups.json 없을 때 defaultGroups() 생성 및 즉시 파일 저장
- tmux 세션 없는 상태: launchProfile에서 세션 자동 생성
- 빈 그룹 처리: profileNames 빈 배열 → launchProfile 루프 0회 → 정상 종료
- 파일 손상: try? + guard 조합으로 graceful degradation
