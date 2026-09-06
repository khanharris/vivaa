import AppKit
import Foundation

// One-click setup for everything the AI feedback needs, so recipients never
// touch Homebrew or Terminal: the speech model, a self-contained Python for
// facial analysis, and the Claude / Codex CLIs via their official installers.
@MainActor
final class SetupManager: NSObject, ObservableObject {
    enum ComponentState: Equatable {
        case checking
        case missing
        case working(String, Double?)
        case ready
        case failed(String)
    }

    @Published var model: ComponentState = .checking
    @Published var facial: ComponentState = .checking
    @Published var claude: ComponentState = .checking
    @Published var codex: ComponentState = .checking

    private let modelURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
    )!
    private let pythonURL = URL(
        string: "https://github.com/astral-sh/python-build-standalone/releases/download/20260728/cpython-3.12.13+20260728-aarch64-apple-darwin-install_only.tar.gz"
    )!
    private let codexURL = URL(
        string: "https://github.com/openai/codex/releases/latest/download/codex-aarch64-apple-darwin.tar.gz"
    )!

    static var standalonePython: String {
        Paths.appSupport.appendingPathComponent("python/bin/python3").path
    }
    static var installedCodex: String {
        Paths.appSupport.appendingPathComponent("bin/codex").path
    }

    func refresh(settings: Settings) {
        let fm = FileManager.default
        let hasModel = ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-medium.en.bin",
                        "ggml-small.en.bin", "ggml-base.en.bin"]
            .contains { fm.fileExists(atPath: Paths.modelsDir.appendingPathComponent($0).path) }
        if case .working = model {} else { model = hasModel ? .ready : .missing }

        let pythonReady = firstExisting([
            settings.analysis?.pythonPath,
            Paths.appSupport.appendingPathComponent("pyvenv/bin/python").path,
            Self.standalonePython
        ]) != nil
        let featReady = fm.fileExists(
            atPath: Paths.appSupport.appendingPathComponent("python/lib/python3.12/site-packages/feat").path
        ) || settings.analysis?.pythonPath != nil
            || fm.fileExists(atPath: Paths.appSupport.appendingPathComponent("pyvenv/bin/python").path)
        if case .working = facial {} else { facial = (pythonReady && featReady) ? .ready : .missing }

        let home = fm.homeDirectoryForCurrentUser.path
        let hasClaude = firstExisting([
            settings.analysis?.claudePath, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home + "/.local/bin/claude", home + "/.claude/local/claude"
        ]) != nil
        if case .working = claude {} else { claude = hasClaude ? .ready : .missing }

        let hasCodex = firstExisting([
            settings.analysis?.codexPath, "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home + "/.local/bin/codex", Self.installedCodex
        ]) != nil
        if case .working = codex {} else { codex = hasCodex ? .ready : .missing }
    }

    // MARK: - Speech model

    func installModel() {
        guard model != .checking, !isWorking(model) else { return }
        model = .working("Downloading model…", 0)
        download(modelURL, label: "Downloading model") { [weak self] progress in
            self?.model = .working("Downloading model…", progress)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let message):
                self.model = .failed(message)
            case .success(let tmp):
                do {
                    try FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
                    let dest = Paths.modelsDir.appendingPathComponent("ggml-large-v3.bin")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    self.model = .ready
                } catch {
                    self.model = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Facial analysis (standalone Python + Py-Feat)

    func installFacial() {
        guard !isWorking(facial) else { return }
        facial = .working("Downloading Python…", 0)
        download(pythonURL, label: "Downloading Python") { [weak self] progress in
            self?.facial = .working("Downloading Python…", progress)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let message):
                self.facial = .failed(message)
            case .success(let tmp):
                self.facial = .working("Unpacking Python…", nil)
                Task {
                    do {
                        try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
                        let untar = try await runProcess(
                            "/usr/bin/tar",
                            ["-xzf", tmp.path, "-C", Paths.appSupport.path],
                            timeout: 600
                        )
                        try? FileManager.default.removeItem(at: tmp)
                        guard untar.code == 0 else {
                            self.facial = .failed("Unpack failed: \(String(untar.stderr.suffix(150)))")
                            return
                        }
                        self.facial = .working("Installing analysis packages… (a few minutes)", nil)
                        let pip = try await runProcess(
                            Self.standalonePython,
                            ["-m", "pip", "install", "--quiet", "py-feat", "opencv-python-headless"],
                            timeout: 3600
                        )
                        guard pip.code == 0 else {
                            self.facial = .failed("Package install failed: \(String(pip.stderr.suffix(200)))")
                            return
                        }
                        self.facial = .ready
                    } catch {
                        self.facial = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Coach CLIs

    func installClaude() {
        guard !isWorking(claude) else { return }
        claude = .working("Running the official installer…", nil)
        Task {
            do {
                let res = try await runProcess(
                    "/bin/bash",
                    ["-c", "curl -fsSL https://claude.ai/install.sh | bash"],
                    timeout: 600
                )
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                if FileManager.default.fileExists(atPath: home + "/.local/bin/claude") {
                    claude = .ready
                } else {
                    claude = .failed("Installer finished but claude was not found: \(String((res.stdout + res.stderr).suffix(150)))")
                }
            } catch {
                claude = .failed(error.localizedDescription)
            }
        }
    }

    func installCodex() {
        guard !isWorking(codex) else { return }
        codex = .working("Downloading Codex…", 0)
        download(codexURL, label: "Downloading Codex") { [weak self] progress in
            self?.codex = .working("Downloading Codex…", progress)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let message):
                self.codex = .failed(message)
            case .success(let tmp):
                Task {
                    do {
                        let unpackDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("viva-codex-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
                        defer {
                            try? FileManager.default.removeItem(at: unpackDir)
                            try? FileManager.default.removeItem(at: tmp)
                        }
                        let untar = try await runProcess(
                            "/usr/bin/tar", ["-xzf", tmp.path, "-C", unpackDir.path], timeout: 300
                        )
                        guard untar.code == 0 else {
                            self.codex = .failed("Unpack failed.")
                            return
                        }
                        let contents = try FileManager.default.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil)
                        guard let binary = contents.first(where: { $0.lastPathComponent.hasPrefix("codex") }) else {
                            self.codex = .failed("Codex binary not found in the archive.")
                            return
                        }
                        let binDir = Paths.appSupport.appendingPathComponent("bin")
                        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
                        let dest = binDir.appendingPathComponent("codex")
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: binary, to: dest)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                        self.codex = .ready
                    } catch {
                        self.codex = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    // Opens Terminal running the provider's login flow (needs a browser anyway).
    func openLogin(provider: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let command = provider == "codex"
            ? (firstExisting(["/opt/homebrew/bin/codex", home + "/.local/bin/codex", Self.installedCodex]) ?? "codex") + " login"
            : (firstExisting(["/opt/homebrew/bin/claude", home + "/.local/bin/claude"]) ?? "claude")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        Task {
            _ = try? await runProcess("/usr/bin/osascript", ["-e", script], timeout: 30)
        }
    }

    // MARK: - Download plumbing

    private func isWorking(_ state: ComponentState) -> Bool {
        if case .working = state { return true }
        return false
    }

    private func download(
        _ url: URL,
        label: String,
        progress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, String>) -> Void
    ) {
        let delegate = DownloadDelegate(
            onProgress: { fraction in Task { @MainActor in progress(fraction) } },
            onFinish: { result in Task { @MainActor in completion(result) } }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: url).resume()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onFinish: (Result<URL, String>) -> Void

    init(onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, String>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent("viva-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                onFinish(.failure("Download failed (HTTP \(http.statusCode))."))
            } else {
                onFinish(.success(keep))
            }
        } catch {
            onFinish(.failure(error.localizedDescription))
        }
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish(.failure(error.localizedDescription))
            session.invalidateAndCancel()
        }
    }
}

extension String: Error {}
