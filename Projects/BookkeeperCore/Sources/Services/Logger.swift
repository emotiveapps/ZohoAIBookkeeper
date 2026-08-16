import Foundation

public final class Logger: Sendable {
    public static let shared = Logger()

    private init() {}

    public func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .debug, message: message, file: file, function: function, line: line)
    }

    public func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .info, message: message, file: file, function: function, line: line)
    }

    public func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .warning, message: message, file: file, function: function, line: line)
    }

    public func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .error, message: message, file: file, function: function, line: line)
    }

    private func log(level: LogLevel, message: String, file: String, function: String, line: Int) {
        let fileName = (file as NSString).lastPathComponent
        let line = "\(level.emoji) [\(level.rawValue)] \(fileName):\(line) \(function) - \(message)\n"
        // stderr, not stdout: the CLI's TUI owns stdout while raw mode is active,
        // and stderr can be redirected (2>/dev/null) without losing the UI.
        FileHandle.standardError.write(Data(line.utf8))
    }
}

private enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

public let logger = Logger.shared
