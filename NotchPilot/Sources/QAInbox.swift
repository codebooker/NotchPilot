import Foundation

/// Developer-only automation for live desktop tests. Launch with `--qa-inbox DIR` to submit
/// instructions from DIR/*.cmd files (name order, deleted after reading) and to mirror status
/// into DIR/status.json. Instructions take the same path as the typed command field. There is
/// no network listener; only whoever launches the app can enable it.
final class QAInbox {
    let directory: URL
    private var timer: Timer?
    private var lastStatus = Data()

    init?(arguments: [String]) {
        guard let index=arguments.firstIndex(of:"--qa-inbox"),arguments.count>index+1 else { return nil }
        directory=URL(fileURLWithPath:arguments[index+1],isDirectory:true)
    }

    static func pending(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.pathExtension=="cmd" }.sorted { $0.lastPathComponent<$1.lastPathComponent }
    }

    func start(submit: @escaping (String) -> Void, status: @escaping () -> [String:Any]) {
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
            guard let self else { return }
            for url in Self.pending(in:self.directory) {
                let text=(try? String(contentsOf:url,encoding:.utf8)) ?? ""
                try? FileManager.default.removeItem(at:url)
                let request=text.trimmingCharacters(in:.whitespacesAndNewlines)
                if !request.isEmpty { submit(request) }
            }
            if let data=try? JSONSerialization.data(withJSONObject:status(),options:[.sortedKeys]),data != self.lastStatus {
                self.lastStatus=data
                try? data.write(to:self.directory.appendingPathComponent("status.json"),options:.atomic)
            }
        }
    }
}
