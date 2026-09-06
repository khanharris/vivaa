import Foundation

struct RunResult {
    let code: Int32
    let stdout: String
    let stderr: String
}

enum SubprocessError: Error {
    case timeout(String)
}

// Async subprocess runner with stdin support and a hard timeout.
func runProcess(
    _ executable: String,
    _ args: [String],
    stdin input: String? = nil,
    cwd: URL? = nil,
    timeout: TimeInterval
) async throws -> RunResult {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var completed = false

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty {
                lock.lock()
                outData.append(d)
                lock.unlock()
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty {
                lock.lock()
                errData.append(d)
                lock.unlock()
            }
        }

        let timeoutWork = DispatchWorkItem {
            lock.lock()
            let done = completed
            lock.unlock()
            if !done { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        process.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            completed = true
            if let rest = try? outPipe.fileHandleForReading.readToEnd() { outData.append(rest) }
            if let rest = try? errPipe.fileHandleForReading.readToEnd() { errData.append(rest) }
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            lock.unlock()
            timeoutWork.cancel()
            continuation.resume(returning: RunResult(code: p.terminationStatus, stdout: out, stderr: err))
        }

        do {
            try process.run()
            if let input, let data = input.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            inPipe.fileHandleForWriting.closeFile()
        } catch {
            timeoutWork.cancel()
            continuation.resume(throwing: error)
        }
    }
}

func firstExisting(_ paths: [String?]) -> String? {
    for p in paths {
        if let p, FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}
