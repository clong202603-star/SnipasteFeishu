import AppKit

enum Clipboard {
    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func copyPNG(_ image: CGImage) {
        guard let data = pngData(image) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
    }
}

struct IngestOutcome {
    var ok: Bool
    var created: Int
    var skipped: Int
    var tags: [String]
    var error: String
}

final class IngestJob {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func start(data: Data, completion: @escaping (IngestOutcome) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-ingest-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
        } catch {
            completion(IngestOutcome(ok: false, created: 0, skipped: 0, tags: [], error: "没能暂存截图"))
            return
        }
        let repo = ShotIngest.repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repo.appendingPathComponent("scripts/read_and_ingest_screenshot.py").path,
            url.path,
        ]
        process.currentDirectoryURL = repo
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.terminationHandler = { [weak self] proc in
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: url)
            let outcome = ShotIngest.parse(stdout: stdout, stderr: stderr, status: proc.terminationStatus)
            DispatchQueue.main.async {
                guard let self, !self.isCancelled else { return }
                completion(outcome)
            }
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: url)
            completion(IngestOutcome(ok: false, created: 0, skipped: 0, tags: [], error: "没能启动入库脚本"))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum ShotIngest {
    static func parse(stdout: String, stderr: String, status: Int32) -> IngestOutcome {
        let line = stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        if let payload = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            let tags = json["tags"] as? [String] ?? []
            let ok = (json["ok"] as? Bool) ?? (status == 0)
            let error = (json["error"] as? String) ?? ""
            return IngestOutcome(
                ok: ok,
                created: intValue(json["created"]),
                skipped: intValue(json["skipped"]),
                tags: tags,
                error: error
            )
        }
        let detail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return IngestOutcome(ok: false, created: 0, skipped: 0, tags: [], error: detail.isEmpty ? "入库没有返回结果" : detail)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    static func repoRoot() -> URL {
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let marker = url.appendingPathComponent("scripts/read_and_ingest_screenshot.py")
            if FileManager.default.fileExists(atPath: marker.path) {
                return url
            }
        }
        return URL(fileURLWithPath: "/Users/chenglong/Desktop/cursor")
    }
}

enum Toast {
    static func show(_ text: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let box = NSTextField(labelWithString: text)
        box.font = .systemFont(ofSize: 13, weight: .medium)
        box.textColor = .white
        box.alignment = .center
        box.lineBreakMode = .byTruncatingTail
        box.frame = NSRect(x: 16, y: 10, width: 388, height: 24)
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 44))
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        wrap.layer?.cornerRadius = 10
        wrap.addSubview(box)
        panel.contentView = wrap
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.maxY - 72))
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            panel.orderOut(nil)
        }
    }
}
