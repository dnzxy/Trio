import Foundation

enum AppLogTextExporter {}

extension LogLevel {
    var linePrefix: String {
        switch self {
        case .debug: return "DEV: "
        case .info: return "INFO: "
        case .notice: return "NOTICE: "
        case .warning: return "WARN: "
        case .error: return "ERR: "
        case .fault: return "FAULT: "
        }
    }
}
