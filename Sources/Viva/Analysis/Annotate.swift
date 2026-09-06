import Foundation

// Aligns whisper transcript segments with the facial-analysis timeline so every
// spoken line carries the facial cues measured during that exact window.

struct TranscriptSegment {
    let fromMs: Int
    let toMs: Int
    let text: String
}

struct FaceFrame: Codable {
    let t: Double
    let dominant: String
    let emotions: [String: Double]
    let aus: [String: Double]
    let pose: [String: Double]
    let gaze_angle: Double?
    let valence: Double?
    let arousal: Double?
}

let auLabels: [(String, String)] = [
    ("AU01", "inner brow raise"), ("AU02", "outer brow raise"), ("AU04", "brow furrow"),
    ("AU05", "upper lid raise"), ("AU06", "cheek raise"), ("AU07", "lid tighten"),
    ("AU09", "nose wrinkle"), ("AU10", "upper lip raise"), ("AU12", "smile"),
    ("AU14", "dimpler"), ("AU15", "lip corner depress"), ("AU17", "chin raise"),
    ("AU20", "lip stretch"), ("AU23", "lip tighten"), ("AU24", "lip press"),
    ("AU25", "lips part"), ("AU26", "jaw drop"), ("AU28", "lip suck"), ("AU43", "eyes closed")
]

private func mmss(_ ms: Int) -> String {
    let s = max(0, Int((Double(ms) / 1000).rounded()))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

private func annotation(for seg: TranscriptSegment, frames: [FaceFrame]) -> String? {
    let lo = Double(seg.fromMs) / 1000 - 0.3
    let hi = Double(seg.toMs) / 1000 + 0.3
    let win = frames.filter { $0.t >= lo && $0.t <= hi }
    guard !win.isEmpty else { return nil }
    var parts: [String] = []

    var counts: [String: Int] = [:]
    for f in win { counts[f.dominant, default: 0] += 1 }
    let ranked = counts.sorted { $0.value > $1.value }
    let emotionPart = ranked.prefix(2).enumerated()
        .filter { idx, kv in idx == 0 || Double(kv.value) / Double(win.count) >= 0.25 }
        .map { _, kv in "\(kv.key) \(Int((Double(kv.value) / Double(win.count) * 100).rounded()))%" }
        .joined(separator: ", ")
    parts.append(emotionPart)

    var auMeans: [(String, String, Double)] = []
    for (au, label) in auLabels {
        let vals = win.compactMap { $0.aus[au] }
        if !vals.isEmpty {
            auMeans.append((au, label, vals.reduce(0, +) / Double(vals.count)))
        }
    }
    for (au, label, mean) in auMeans.filter({ $0.2 >= 0.35 }).sorted(by: { $0.2 > $1.2 }).prefix(3) {
        parts.append("\(label) (\(au)) " + String(format: "%.2f", mean))
    }

    let gazes = win.compactMap { $0.gaze_angle }
    if !gazes.isEmpty {
        let on = Double(gazes.filter { abs($0) <= 12 }.count) / Double(gazes.count)
        parts.append(on >= 0.7 ? "gaze on camera" : on >= 0.4 ? "gaze wandering" : "gaze away")
    }

    let valences = win.compactMap { $0.valence }
    if !valences.isEmpty {
        parts.append("valence " + String(format: "%.2f", valences.reduce(0, +) / Double(valences.count)))
    }

    return parts.filter { !$0.isEmpty }.joined(separator: "; ")
}

func annotatedTranscriptLines(_ segments: [TranscriptSegment], frames: [FaceFrame]?) -> [String] {
    segments.map { seg in
        let label = "[\(mmss(seg.fromMs))-\(mmss(seg.toMs))]"
        if let frames, !frames.isEmpty, let ann = annotation(for: seg, frames: frames) {
            return "\(label) \"\(seg.text)\" (\(ann))"
        }
        return "\(label) \"\(seg.text)\""
    }
}
