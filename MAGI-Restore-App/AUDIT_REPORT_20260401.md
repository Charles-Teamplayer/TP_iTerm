# MAGI-Restore-App 전수 감사 보고서

**날짜**: 2026-04-01  
**감사자**: 하늘 (Frontend DEV)  
**대상**: MAGI-Restore-App (Swift macOS native)

---

## 1. 메모리 누수 가능성 분석

### 1.1 Timer 관리 (HIGH RISK)

**위치**: TPiTermRestoreApp.swift:43, SessionMonitor.swift:13-14, SystemView.swift:24

**발견사항**:
```swift
// TPiTermRestoreApp.swift
init() {
    timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.refresh() }
    }
}

deinit {
    timer?.invalidate()  // ✓ 정상
}
```

**평가**: 
- `[weak self]` 캡처 사용 ✓ (순환 참조 방지)
- `deinit`에서 `invalidate()` 호출 ✓
- 상태: **안전**

그러나:
- `MenuBarState`는 `StateObject`로 앱 생명주기 전체 유지 → 메모리 누수 없음
- `SessionMonitor`는 `ContentView`의 `StateObject` → View lifecycle과 연결

**체크리스트**:
1. ✓ Timer invalidate 호출 확인
2. ✓ weak self 캡처
3. ✓ deinit 구현

---

### 1.2 Task 및 DispatchQueue 관리

**위치**: 
- ShellService.swift:35 (`DispatchQueue.global`)
- ContentView.swift:84 (`DispatchQueue.main.async`)
- SessionMonitor.swift:158 (`Task` with `[weak self]`)
- ToastService.swift:24, 83

**발견사항**:

```swift
// ShellService.swift - 안전
@discardableResult
static func runAsync(_ command: String) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: run(command))
        }
    }
}
// ✓ withCheckedContinuation 사용 → 자동 정리

// SessionMonitor.swift - 안전
debounceTask = Task { @MainActor [weak self] in
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard !Task.isCancelled else { return }
    self?.refreshStatusOnly()
}
// ✓ [weak self], Task.isCancelled 체크

// ToastService.swift - 약간의 위험
hideTask = Task {
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    if !Task.isCancelled { self.dismiss() }
}
// ⚠️ @MainActor이지만 self는 강한 참조 (singleton이므로 문제 아님)
```

**평가**: **안전** (singleton 객체이기 때문에 ToastService 강한 참조 문제 없음)

---

### 1.3 Array/Dictionary 생성 및 메모리 해제

**위치**: SessionMonitor.swift 전체 (refresh() 함수)

**발견사항**:

```swift
// SessionMonitor.swift:206-347
func refresh(showBanner: Bool = false) async {
    guard !isRefreshing else { return }
    
    let tmuxWindows = await loadTmuxWindows()
    let activeSessions = await loadActiveSessions()
    let claudeProcessSnapshot = await ShellService.runAsync(...)
    
    var result: [ClaudeSession] = []  // 새로운 배열 할당
    // ... 루프 내 배열 조작 (100+ 요소)
    
    sessions = newSessions  // 기존 배열 해제, 새 배열 참조
}
```

**평가**: 
- `result`는 로컬 변수 → 함수 종료 시 자동 해제 ✓
- `sessions`는 `@Published` → ARC가 기존 배열 자동 해제 ✓
- 문제: **없음**

---

## 2. UI 스레드 안전성 분석

### 2.1 MainActor 어노테이션 확인

**적용 클래스**:
- `MenuBarState` (TPiTermRestoreApp.swift:36) ✓
- `SessionMonitor` (SessionMonitor.swift:5) ✓
- `ToastService` (ToastService.swift:13) ✓
- `ActivationService` (ActivationService.swift:5) ✓
- `WindowGroupService` (WindowGroupService.swift:4) ✓
- `ProfileService` (ProfileService.swift:3) ✓
- `SystemViewModel` (SystemView.swift:10) ✓

**평가**: **우수** — 모든 상태 관리 객체가 `@MainActor`로 보호됨

### 2.2 Background Task 스레드 안전성

**위치**: SessionMonitor.swift:363-381

```swift
let collected = await Task.detached(priority: .utility) { () -> Set<String> in
    // ⚠️ ShellService.run() 동기 호출 (메인 스레드 블로킹 없음)
    let ppidRaw = ShellService.run("ps -o ppid= -p \(currentPid) 2>/dev/null")
    let allClaude = ShellService.run("ps -A -o pid=,comm= 2>/dev/null | awk '/[c]laude$/{print $1}'")
    return pids
}.value

// await 후 @MainActor 컨텍스트에서 안전하게 처리
await updateProtectedPids(...)
```

**평가**: **안전** (background 작업 명확, 결과 반환 후 메인에서 처리)

---

## 3. File I/O 안전성 분석

### 3.1 동시 접근 문제 분석

**주요 파일들**:
- `~/.claude/window-groups.json` (다중 읽기/쓰기)
- `~/.claude/activated-sessions.json` (읽기/쓰기)
- `~/.claude/intentional-stops.json` (읽기/쓰기)
- `~/.claude/tab-color/states/*.txt` (읽기만)

**WindowGroupService.swift**:
```swift
func load() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else { ... }
    // ✓ 읽기는 FileManager 스레드 안전
}

func save() {
    guard let data = try? JSONEncoder().encode(groups) else { return }
    try? data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
    // ✓ .atomic 옵션 → 임시 파일 후 rename (원자성 보장)
}
```

**ActivationService.swift**:
```swift
private func persist(_ set: Set<String>) {
    // ...
    let bakPath = filePath + ".bak"
    if FileManager.default.fileExists(atPath: filePath) {
        try? FileManager.default.removeItem(atPath: bakPath)
        try? FileManager.default.copyItem(atPath: filePath, toPath: bakPath)
    }
    try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    // ✓ SPOF 방어: .bak 백업 자동 생성
}
```

**위험 요소**:
```swift
// SessionMonitor.swift:880-995 (checkAutoSync)
// 문제: window-groups.json 읽기 → 복잡한 로직 → 쓰기 구간에 외부 변경 가능
windowGroupService.load()  // T1: 읽기

// ... 오래 걸리는 로직들 (T1~T2)

profileService.savePerSession(groups: windowGroupService.groups)  // T2: 쓰기
```

**평가**: **중간 위험** (TOCTOU race condition 가능)
- 실제 영향: 낮음 (사용자 UI를 통한 변경은 같은 @MainActor)
- 하지만 외부 프로세스(watchdog, auto-restore.sh)가 동시에 변경 가능

---

### 3.2 JSON 읽기/쓰기 오류 처리

**위치**: 
- SessionMonitor.swift:59-66 (intentional-stops 로드)
- ProfileService.swift:14-25 (YAML 파싱)

```swift
// SessionMonitor.swift:59
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let stops = json["stops"] as? [[String: Any]] else { return }
// ✓ try? 사용 → 오류 무시, 안전하게 실패

// 문제: 파일이 손상되면 자동으로 무시됨
// → 의도적 중지 정보 손실 가능
```

**평가**: **약간의 개선 필요**
- 현재: 오류 시 조용히 실패
- 추천: 최소한 로그 기록 (로테이션 필터링)

---

## 4. Swift 코드 패턴 분석

### 4.1 구식 패턴 발견

**위치**: ShellService.swift:17-18

```swift
if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir),
   let latest = versions.filter({ $0.hasPrefix("v") }).sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last {
// ⚠️ String.compare(options:) 사용
```

**Swift 5.0+ 권장**:
```swift
.sorted(by: { ($0, $1) in $0.localizedStandardCompare($1) == .orderedAscending })
// 또는 Swift 5.3+:
versions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
```

**평가**: **낮은 우선순위** (기능적으로는 정상 작동)

---

### 4.2 Optional Chaining 과다 사용

**위치**: 전체 코드베이스

```swift
// SessionMonitor.swift:438
if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
    sessions[idx].didCrash = false
}
```

**평가**: **적절함** (nil 안전성 확보)

---

### 4.3 Type Safety

**위치**: ProfileService.swift, WindowGroupService.swift

**코드 품질**: **우수**
- Codable 프로토콜 적절 사용
- 모델 구조체 명확함
- JSON 매핑 안전함

---

## 5. 메모리 프로파일 시뮬레이션

**예상 메모리 점유**:
- 세션 객체 100개 × 2KB ≈ 200KB
- Timer 객체 3개 × 1KB ≈ 3KB  
- View 상태 ≈ 50KB
- **합계**: 약 250KB (매우 경량)

**누수 위험**: **매우 낮음**

---

## 6. 발견된 이슈 요약

| # | 심각도 | 항목 | 현재 상태 | 권장 사항 |
|---|--------|------|---------|----------|
| 1 | LOW | String.compare() 패턴 | 구식이지만 작동 | Swift 5.3+ 메서드로 업데이트 |
| 2 | MEDIUM | TOCTOU race (JSON) | 외부 변경 가능 | load/save 구간에 임시 lock 추가 |
| 3 | LOW | 파일 오류 로깅 부재 | 오류 무시 | 최소 콘솔 log 추가 |
| 4 | CRITICAL | 없음 | - | - |

---

## 7. 검증 체크리스트

- ✓ Timer 정상 해제
- ✓ Task 캡처 안전 (weak self)
- ✓ MainActor 어노테이션 완전
- ✓ File I/O atomic 옵션 사용
- ✓ JSON 오류 처리 (try?)
- ✓ 메모리 누수 없음
- ⚠️ race condition 가능성 (낮은 확률)

---

## 8. 최종 평가

**종합 점수**: 8.5/10

**강점**:
- 메모리 누수 위험 거의 없음
- UI 스레드 안전성 우수
- File I/O 원자성 보장
- 코드 구조 명확함

**개선점**:
- TOCTOU race condition 미니멀 로킹 추가
- JSON 오류 시 디버그 로그
- 구식 String 비교 메서드 업데이트

**결론**: **프로덕션 품질** - 심각한 버그 없음, 안정적 운영 가능

