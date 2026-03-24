import SwiftUI
import AppKit

// MARK: - Debug Logger

func badgeLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    let path = "/tmp/badge_debug.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
