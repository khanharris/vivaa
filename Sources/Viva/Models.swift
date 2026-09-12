import Foundation

// Stable on-disk schema: sessions, settings and analysis artifacts written by
// earlier versions keep loading unchanged.

struct Question: Codable, Hashable {
    var text: String
    var theme: String?
}

struct QuestionSet: Codable, Hashable, Identifiable {
    var name: String
    var questions: [Question]
    var id: String { name }
}

struct Timings: Codable, Hashable {
    var readingSec: Int
    var answerSec: Int
    var breakSec: Int

    // Recorded MMI defaults: the question is read out, recording starts the moment the
    // reading ends, and the 5 minutes include thinking time. No break between stations.
    static let full = Timings(readingSec: 0, answerSec: 300, breakSec: 0)
    static let quick = Timings(readingSec: 0, answerSec: 15, breakSec: 0)
}

struct QuestionResult: Codable {
    var index: Int
    var theme: String?
    var text: String
    var file: String?
    var answeredMs: Int
}

struct SessionMeta: Codable {
    var id: String
    var questionSet: String
    var startedAt: String
    var finishedAt: String
    var aborted: Bool
    var timings: Timings
    var questions: [QuestionResult]
}

struct AnalysisSettings: Codable {
    var enabled: Bool?
    var facial: Bool?
    var provider: String?
    var model: String?
    var effort: String?
    var claudePath: String?
    var codexPath: String?
    var whisperPath: String?
    var pythonPath: String?
}

struct Settings: Codable {
    var saveDir: String?
    var analysis: AnalysisSettings?
    var theme: String?
    var quickTest: Bool?
    var micID: String?  // AVCaptureDevice uniqueID; nil = automatic (built-in mic)
    var readAloud: Bool?  // nil = true: speak each question, then record
}

enum Paths {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("interviewapp")
    }
    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    static var questionSetsDir: URL { appSupport.appendingPathComponent("question-sets") }
    static var modelsDir: URL { appSupport.appendingPathComponent("models") }
    static var rubricFile: URL { appSupport.appendingPathComponent("rubric.md") }
}

func sessionIdNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
