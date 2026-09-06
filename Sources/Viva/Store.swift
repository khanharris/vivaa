import AppKit
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var settings = Settings()
    @Published var questionSets: [QuestionSet] = []

    init() {
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        loadSettings()
        loadQuestionSets()
    }

    func loadSettings() {
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        }
    }

    func saveSettings() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(settings) {
            try? data.write(to: Paths.settingsFile)
        }
    }

    func loadQuestionSets() {
        var sets: [QuestionSet] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: Paths.questionSetsDir, includingPropertiesForKeys: nil) {
            for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let data = try? Data(contentsOf: f),
                   let set = try? JSONDecoder().decode(QuestionSet.self, from: data),
                   !set.questions.isEmpty {
                    sets.append(set)
                }
            }
        }
        questionSets = sets
    }

    func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose where interview recordings are saved"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDir = url.path
            saveSettings()
        }
    }

    // Returns a status message for the UI.
    func importQuestionSet() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Import a question set (JSON)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let set = try? JSONDecoder().decode(QuestionSet.self, from: data),
              !set.name.isEmpty, !set.questions.isEmpty,
              set.questions.allSatisfy({ !$0.text.isEmpty })
        else {
            return "Invalid format. Expected { \"name\": \"...\", \"questions\": [{ \"text\": \"...\", \"theme\": \"optional\" }] }"
        }
        try? FileManager.default.createDirectory(at: Paths.questionSetsDir, withIntermediateDirectories: true)
        let slug = set.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let out = try? enc.encode(set) {
            try? out.write(to: Paths.questionSetsDir.appendingPathComponent("\(slug.isEmpty ? "question-set" : slug).json"))
        }
        loadQuestionSets()
        return "Imported \"\(set.name)\" (\(set.questions.count) questions)."
    }

    var timings: Timings { settings.quickTest == true ? .quick : .full }
}
