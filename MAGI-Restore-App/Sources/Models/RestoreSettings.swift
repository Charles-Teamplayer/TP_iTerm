import Foundation

struct RestoreSettings {
    var autoRestore: Bool = false
    var delaySeconds: Int = 60    // 크래시 후 자동 재시작까지 대기 시간
    var maxAttempts: Int = 3      // 최대 재시작 시도 횟수
    var autoSync: Bool = false
    var syncIntervalSeconds: Int = 300  // 기본 5분

    static let delayPresets: [(label: String, seconds: Int)] = [
        ("30초", 30), ("1분", 60), ("3분", 180), ("5분", 300)
    ]
    static let attemptPresets: [(label: String, count: Int)] = [
        ("1회", 1), ("3회", 3), ("5회", 5), ("10회", 10)
    ]
    static let syncIntervalPresets: [(label: String, seconds: Int)] = [
        ("30초", 30), ("1분", 60), ("5분", 300), ("10분", 600), ("30분", 1800)
    ]

    private enum Keys {
        static let autoRestore       = "restore.autoRestore"
        static let delaySeconds      = "restore.delaySeconds"
        static let maxAttempts       = "restore.maxAttempts"
        static let autoSync          = "restore.autoSync"
        static let syncIntervalSeconds = "restore.syncIntervalSeconds"
    }

    static func load() -> RestoreSettings {
        var s = RestoreSettings()
        let ud = UserDefaults.standard
        if ud.object(forKey: Keys.autoRestore)          != nil { s.autoRestore          = ud.bool(forKey: Keys.autoRestore) }
        if ud.object(forKey: Keys.delaySeconds)         != nil { s.delaySeconds         = ud.integer(forKey: Keys.delaySeconds) }
        if ud.object(forKey: Keys.maxAttempts)          != nil { s.maxAttempts          = ud.integer(forKey: Keys.maxAttempts) }
        if ud.object(forKey: Keys.autoSync)             != nil { s.autoSync             = ud.bool(forKey: Keys.autoSync) }
        if ud.object(forKey: Keys.syncIntervalSeconds)  != nil { s.syncIntervalSeconds  = ud.integer(forKey: Keys.syncIntervalSeconds) }
        return s
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(autoRestore,         forKey: Keys.autoRestore)
        ud.set(delaySeconds,        forKey: Keys.delaySeconds)
        ud.set(maxAttempts,         forKey: Keys.maxAttempts)
        ud.set(autoSync,            forKey: Keys.autoSync)
        ud.set(syncIntervalSeconds, forKey: Keys.syncIntervalSeconds)
    }
}
