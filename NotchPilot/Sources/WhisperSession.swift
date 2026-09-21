import Foundation

/// One model process for the app lifetime. Cancelled request IDs never deliver text.
final class WhisperSession {
    private var process: Process?
    private var input: Pipe?
    private var callbacks: [String:(Result<String,Error>) -> Void] = [:]
    private var lifetime = UUID()
    private let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 90) { self.requestTimeout = requestTimeout }

    func prepare(_ runtime: Runtime) throws { if process?.isRunning != true { try start(runtime) } }

    func transcribe(runtime: Runtime, url: URL, dictation: Bool, prompt: String = "", completion: @escaping (Result<String,Error>) -> Void) {
        let id=UUID().uuidString
        do {
            if process?.isRunning != true { try start(runtime) }
            callbacks[id]=completion
            var request:[String:Any]=["id":id,"path":url.path,"dictation":dictation]
            if !prompt.isEmpty { request["prompt"]=prompt }
            let data=try JSONSerialization.data(withJSONObject:request)
            guard let input else { throw VoiceEditor.problem("The speech engine is unavailable. Try again.") }
            try input.fileHandleForWriting.write(contentsOf:data+Data([10]))
            let token=lifetime
            DispatchQueue.main.asyncAfter(deadline:.now()+requestTimeout) { [weak self] in
                guard let self,self.lifetime==token,self.callbacks[id] != nil else { return }
                let pending=Array(self.callbacks.values)
                self.shutdown()
                for callback in pending { callback(.failure(VoiceEditor.problem("Speech recognition took too long. Try again to restart it."))) }
            }
        } catch { callbacks.removeValue(forKey:id);completion(.failure(error)) }
    }
    private func start(_ runtime: Runtime) throws {
        let token=UUID(); lifetime=token
        let child=Process();let output=Pipe();let stdin=Pipe()
        child.executableURL=URL(fileURLWithPath:runtime.whisper)
        child.arguments=[runtime.model];child.standardInput=stdin
        child.standardOutput=output;child.standardError=FileHandle.nullDevice
        try child.run();process=child;input=stdin
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var buffer=Data()
            while true {
                let chunk=output.fileHandleForReading.availableData
                if chunk.isEmpty { break };buffer.append(chunk)
                while let range=buffer.range(of:Data([10])) {
                    let line=buffer.subdata(in:0..<range.lowerBound);buffer.removeSubrange(0..<range.upperBound)
                    guard let message=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any],
                          let id=message["id"] as? String else { continue }
                    DispatchQueue.main.async {
                        guard let self,self.lifetime==token,let callback=self.callbacks.removeValue(forKey:id) else { return }
                        if message["event"] as? String == "transcript",let text=message["text"] as? String {
                            callback(.success(text.trimmingCharacters(in:.whitespacesAndNewlines)))
                        } else { callback(.failure(NSError(domain:"Whisper",code:1,userInfo:[NSLocalizedDescriptionKey:"Local speech recognition failed."]))) }
                    }
                }
            }
            child.waitUntilExit()
            DispatchQueue.main.async {
                guard let self,self.lifetime==token else { return }
                self.process=nil;self.input=nil
                let pending=self.callbacks.values;self.callbacks.removeAll()
                for callback in pending { callback(.failure(NSError(domain:"Whisper",code:2,userInfo:[NSLocalizedDescriptionKey:"Speech engine stopped. Try again to restart it."]))) }
            }
        }
    }
    func cancelPending() { callbacks.removeAll() }
    func shutdown() {
        lifetime=UUID();callbacks.removeAll();try? input?.fileHandleForWriting.close()
        process?.terminate();process=nil;input=nil
    }
    deinit { process?.terminate() }
}
