import Foundation
import Observation

@MainActor @Observable
final class AppLog {
    static let shared = AppLog()

    struct Line: Identifiable {
        let id = UUID()
        let date: Date
        let level: String
        let text: String
    }

    private(set) var lines: [Line] = []
    @ObservationIgnored var echoToStdout = false

    func info(_ text: String) { add("INFO", text) }
    func warn(_ text: String) { add("WARN", text) }
    func error(_ text: String) { add("ERR ", text) }

    private func add(_ level: String, _ text: String) {
        let line = Line(date: Date(), level: level, text: text)
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if echoToStdout {
            print("[\(level)] \(text)")
            fflush(stdout)
        }
    }

    var exportText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.map { "\(f.string(from: $0.date)) [\($0.level)] \($0.text)" }.joined(separator: "\n")
    }
}

@MainActor func log(_ text: String) { AppLog.shared.info(text) }
@MainActor func logWarn(_ text: String) { AppLog.shared.warn(text) }
@MainActor func logError(_ text: String) { AppLog.shared.error(text) }
