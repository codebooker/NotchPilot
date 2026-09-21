import Foundation

/// A resident Silero VAD process. Audio stays on this Mac and is transported
/// through private stdin/stdout pipes as fixed 32 ms PCM frames.
final class VADSession: SpeechFrameClassifier {
    static let frameSamples = 512
    private var process: Process?
    private var input: Pipe?
    private struct Callback { let queue: DispatchQueue; let action: (Result<Float, Error>) -> Void }
    private var callbacks: [Callback] = []
    private var outputBuffer = Data()
    private var sawReady = false
    private var lifetime = UUID()
    private let lock = NSLock()
    private var runtime: Runtime?

    func prepare(_ runtime: Runtime) throws {
        try lock.withLock {
            self.runtime = runtime
            if process?.isRunning != true { try start(runtime) }
        }
    }

    func classify(_ frame: [Float], deliverOn queue: DispatchQueue, completion: @escaping (Result<Float, Error>) -> Void) {
        guard frame.count == Self.frameSamples else {
            completion(.failure(NSError(domain: "VAD", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech detector received an invalid audio frame."])))
            return
        }
        var queued = false
        do {
            // Process state is shared with the reader thread and main; the write stays outside the
            // lock so a full pipe cannot block the reader that drains it.
            let input: Pipe = try lock.withLock {
                guard let runtime else { throw NSError(domain:"VAD",code:2,userInfo:[NSLocalizedDescriptionKey:"Speech detector is not prepared."]) }
                if process?.isRunning != true { try start(runtime) }
                guard let input else { throw NSError(domain: "VAD", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech detector is unavailable."]) }
                callbacks.append(Callback(queue:queue,action:completion)); queued = true
                return input
            }
            var data = Data([70]) // F
            frame.withUnsafeBytes { data.append(contentsOf: $0) }
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            if queued { lock.withLock { _ = callbacks.popLast() } }
            completion(.failure(error))
        }
    }

    /// Ordered after already-written frames, so the next utterance starts with a clean LSTM state.
    func reset() {
        let running: Pipe? = lock.withLock { process?.isRunning == true ? input : nil }
        try? running?.fileHandleForWriting.write(contentsOf: Data([82])) // R
    }

    /// Call with `lock` held.
    private func start(_ runtime: Runtime) throws {
        let token = UUID(); lifetime = token; sawReady = false; outputBuffer.removeAll()
        let child = Process(); let stdout = Pipe(); let stdin = Pipe()
        child.executableURL = URL(fileURLWithPath: runtime.vad)
        child.arguments = [runtime.vadModel]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run(); process = child; input = stdin
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                self?.receive(chunk, token: token)
            }
            child.waitUntilExit()
            self?.ended(token: token)
        }
    }

    private func receive(_ chunk: Data, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard lifetime == token else { return }
        outputBuffer.append(chunk)
        if !sawReady {
            guard let newline = outputBuffer.firstIndex(of: 10) else { return }
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] != nil else {
                failAll("Speech detector failed to start."); return
            }
            sawReady = true
        }
        while outputBuffer.count >= MemoryLayout<Float>.size, !callbacks.isEmpty {
            let value = outputBuffer.prefix(MemoryLayout<Float>.size).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            outputBuffer.removeFirst(MemoryLayout<Float>.size)
            let callback = callbacks.removeFirst()
            guard value.isFinite && value >= 0 && value <= 1 else {
                callback.queue.async { callback.action(.failure(NSError(domain: "VAD", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech detector could not classify audio."]))) }
                continue
            }
            callback.queue.async { callback.action(.success(value)) }
        }
    }

    private func ended(token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard lifetime == token else { return }
        process = nil; input = nil; sawReady = false
        failAll("Speech detector stopped. Try again to restart it.")
    }

    private func failAll(_ message: String) {
        let pending = callbacks; callbacks.removeAll()
        for callback in pending {
            callback.queue.async { callback.action(.failure(NSError(domain: "VAD", code: 4, userInfo: [NSLocalizedDescriptionKey: message]))) }
        }
    }

    func shutdown() {
        lock.lock(); lifetime = UUID(); callbacks.removeAll(); try? input?.fileHandleForWriting.close()
        process?.terminate(); process = nil; input = nil
        lock.unlock()
    }

    deinit { process?.terminate() }
}
