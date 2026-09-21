import Foundation

// Private stdio connection: no HTTP listener, cloud fallback, or persisted conversation.
final class PlannerClient {
    var process: Process?
    var input: Pipe?
    var callback: (([String:Any]) -> Void)?
    var requestID: String?
    var deadline: DispatchWorkItem?

    func interpret(runtime: Runtime, goal: String, context: [String], dialogue: [[String:String]],
                   completion: @escaping ([String:Any]) -> Void) {
        guard callback == nil else { completion(["event":"error","text":"Another interpretation is still active."]); return }
        let id=UUID().uuidString; requestID=id; callback=completion
        if process == nil {
            let child=Process(); let stdin=Pipe(); let stdout=Pipe()
            child.executableURL=URL(fileURLWithPath:runtime.python)
            child.arguments=["-B","-u",runtime.planner,"--model",runtime.qwen]
            child.environment=["PATH":"/usr/bin:/bin","HOME":NSHomeDirectory(),"TMPDIR":NSTemporaryDirectory(),
                               "HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","TOKENIZERS_PARALLELISM":"false"]
            child.standardInput=stdin; child.standardOutput=stdout; child.standardError=FileHandle.nullDevice
            process=child; input=stdin
            do { try child.run() }
            catch { finish(["event":"error","text":"Could not start local Qwen. Run setup.py."]); process=nil; input=nil; return }
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                var buffer=Data()
                while true {
                    let chunk=stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }; buffer.append(chunk)
                    while let range=buffer.range(of:Data([10])) {
                        let line=buffer.subdata(in:0..<range.lowerBound); buffer.removeSubrange(0..<range.upperBound)
                        if let event=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] {
                            DispatchQueue.main.async {
                                guard let self, self.process === child, event["id"] as? String == self.requestID else { return }
                                self.finish(event)
                            }
                        }
                    }
                }
                child.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self, self.process === child else { return }
                    self.process=nil; self.input=nil
                    if self.callback != nil { self.finish(["event":"error","text":"Local Qwen exited before interpreting the request."]) }
                }
            }
        }
        do {
            let data=try JSONSerialization.data(withJSONObject:["id":id,"goal":goal,"context":context,"dialogue":dialogue])
            try input?.fileHandleForWriting.write(contentsOf:data+Data([10]))
        } catch { finish(["event":"error","text":"Could not send the instruction to local Qwen."]); return }
        let timeout=DispatchWorkItem { [weak self] in
            guard let self, self.requestID==id else { return }
            let completion=self.callback; self.cancel()
            completion?(["event":"error","text":"Local interpretation timed out. Please try a shorter instruction."])
        }
        deadline=timeout; DispatchQueue.main.asyncAfter(deadline:.now()+30,execute:timeout)
    }
    func finish(_ event: [String:Any]) {
        deadline?.cancel(); deadline=nil
        let completion=callback; callback=nil; requestID=nil; completion?(event)
    }
    func cancel() {
        deadline?.cancel(); deadline=nil; callback=nil; requestID=nil
        process?.terminate(); process=nil; input=nil
    }
}
