import Foundation

/// Decision models offered for the Cua controller. Must match MODELS in cua_agent.py (a test checks).
/// `task` is the measured OpenRouter cost of a short two-decision Calculator task on 2026-09-21,
/// with each model's routing; list prices understate some providers.
enum ControllerModels {
    static let options: [(id: String, name: String, task: Double, note: String)] = [
        ("openai/gpt-5-mini","GPT-5 mini",0.0019,""),
        ("google/gemini-2.5-flash-lite","Gemini 2.5 Flash-Lite",0.0006,"fastest"),
        ("openai/gpt-5-nano","GPT-5 nano",0.0004,"slower"),
        ("deepseek/deepseek-v4-flash","DeepSeek V4 Flash",0.0009,"")]
    static let defaultID = "openai/gpt-5-mini"
    static func valid(_ id: String) -> String { options.contains { $0.id == id } ? id : defaultID }
    static func label(_ id: String) -> String {
        guard let option=options.first(where:{ $0.id == id }) else { return id }
        let parts=[option.name,String(format:"about $%.4f a task",option.task),id == defaultID ? "default" : option.note]
        return parts.filter { !$0.isEmpty }.joined(separator:" · ")
    }
}

/// Host-side stage timings for one request, written with the worker's rows under the same run id.
/// Local timings only: no request text, screen contents, or keys.
struct RequestTiming {
    let run = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
    let started = Date()
    private(set) var rows: [[String:Any]] = []
    mutating func mark(_ metric: String, since: Date? = nil) {
        rows.append(["run":run,"metric":metric,"seconds":(Date().timeIntervalSince(since ?? started)*10000).rounded()/10000])
    }
}

/// A worker process started before it is needed. With --warm it starts the Cua driver and then
/// waits for a request, so a task does not pay for process and driver startup.
struct SpareWorker {
    let process: Process
    let input: Pipe
    let output: Pipe
    let arguments: [String]
    let environment: [String:String]
}

extension AppDelegate {
    func workerLaunch() -> (arguments: [String], environment: [String:String])? {
        guard let runtime else { return nil }
        var arguments=["-B","-u",runtime.worker,"--root",runtime.root,"--engine",state.engine,"--provider",state.provider,
                       "--model",ControllerModels.valid(state.controllerModel)]
        if state.preview { arguments.append("--preview") }
        if state.writerEnabled { arguments.append("--allow-writer") }
        var environment=ProcessInfo.processInfo.environment
        for account in ["TYPESAFE_API_KEY","OPENROUTER_API_KEY"] {
            if let key=Credentials.read(account) { environment["NOTCHPILOT_"+account]=key }
        }
        return (arguments,environment)
    }

    func startWorker(_ launch: (arguments: [String], environment: [String:String]), warm: Bool) throws -> SpareWorker {
        guard let runtime else { throw VoiceEditor.problem("Runtime unavailable. Rebuild with build.py.") }
        let process=Process();let output=Pipe();let input=Pipe()
        process.executableURL=URL(fileURLWithPath:runtime.python)
        process.arguments=launch.arguments+(warm ? ["--warm"] : [])
        process.environment=launch.environment
        process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        process.currentDirectoryURL=URL(fileURLWithPath:runtime.root)
        try process.run()
        return SpareWorker(process:process,input:input,output:output,arguments:launch.arguments,environment:launch.environment)
    }

    /// Keeps one warm Cua worker ready between tasks. Settings or key changes are detected when it
    /// is adopted; a mismatched spare is discarded.
    func prepareSpareWorker() {
        guard spare == nil,task == nil,state.engine == "cua",desktopReady,let launch=workerLaunch() else { return }
        spare=try? startWorker(launch,warm:true)
    }
    func adoptSpareWorker(for launch: (arguments: [String], environment: [String:String])) -> SpareWorker? {
        guard let ready=spare else { return nil }
        spare=nil
        guard ready.process.isRunning,ready.arguments == launch.arguments,ready.environment == launch.environment else {
            try? ready.input.fileHandleForWriting.close();ready.process.terminate();return nil
        }
        return ready
    }
    func discardSpareWorker() {
        try? spare?.input.fileHandleForWriting.close();spare?.process.terminate();spare=nil
    }

    func writeTimings(_ timing: RequestTiming) {
        guard let runtime,!timing.rows.isEmpty else { return }
        let path=URL(fileURLWithPath:runtime.root).appendingPathComponent(".cache/notchpilot-performance.jsonl")
        let lines=timing.rows.compactMap { try? JSONSerialization.data(withJSONObject:$0) }.map { $0+Data([10]) }.reduce(Data(),+)
        if let handle=try? FileHandle(forWritingTo:path) { handle.seekToEndOfFile();handle.write(lines);try? handle.close() }
        else { try? lines.write(to:path) }
    }
}
