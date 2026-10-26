import AppKit

enum ShotPhase: Equatable {
    case waiting
    case running
    case uploaded(String)
    case skipped
    case failed(String)
}

struct ShotTicket {
    let id: UUID
    let day: Int
    let number: Int
    var libraryID: String?
    var phase: ShotPhase
    var png: Data

    var label: String { "\(day)日第\(number)张" }
}

final class IngestQueue {
    var onChange: (([ShotTicket]) -> Void)?
    var onLibraryChange: (() -> Void)?
    private var tickets: [ShotTicket] = []
    private var running = false
    private var activeJob: IngestJob?

    func enqueue(_ png: Data) {
        let stamp = Self.nextStamp()
        enqueue(png, day: stamp.day, number: stamp.number, libraryID: nil)
    }

    func enqueue(_ png: Data, day: Int, number: Int, libraryID: String?) {
        if let libraryID, tickets.contains(where: { $0.libraryID == libraryID && ($0.phase == .waiting || $0.phase == .running) }) {
            return
        }
        tickets.append(ShotTicket(id: UUID(), day: day, number: number, libraryID: libraryID, phase: .waiting, png: png))
        publish()
        pump()
    }

    private static func nextStamp() -> (day: Int, number: Int) {
        let now = Date()
        let day = Calendar.current.component(.day, from: now)
        let key = DateFormatter.stampKey.string(from: now)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/截图入库", isDirectory: true)
        let file = folder.appendingPathComponent("daily-count.txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stored = (try? String(contentsOf: file, encoding: .utf8))?
            .split(separator: " ")
            .map(String.init) ?? []
        let number = (stored.count == 2 && stored[0] == key ? Int(stored[1]) ?? 0 : 0) + 1
        try? "\(key) \(number)".write(to: file, atomically: true, encoding: .utf8)
        return (day, number)
    }

    private func pump() {
        guard !running, let index = tickets.firstIndex(where: { $0.phase == .waiting }) else { return }
        running = true
        let png = tickets[index].png
        tickets[index].phase = .running
        tickets[index].png = Data()
        publish()
        let ticketID = tickets[index].id
        let job = IngestJob()
        activeJob = job
        job.start(data: png) { [weak self] outcome in
            self?.activeJob = nil
            self?.finish(id: ticketID, outcome: outcome, png: png)
        }
    }

    private func finish(id: UUID, outcome: IngestOutcome, png: Data) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else {
            running = false
            pump()
            return
        }
        let label = tickets[index].label
        if outcome.ok, outcome.created > 0 {
            let tags = outcome.tags.joined(separator: "、")
            tickets[index].phase = .uploaded(tags)
            if let libraryID = tickets[index].libraryID { FailedLibrary.remove(id: libraryID) }
            onLibraryChange?()
            Notice.show(title: "\(label) 已上传成功", body: tags.isEmpty ? "已写入截图库" : tags)
        } else if outcome.ok, outcome.skipped > 0 {
            tickets[index].phase = .skipped
            if let libraryID = tickets[index].libraryID { FailedLibrary.remove(id: libraryID) }
            onLibraryChange?()
            Notice.show(title: "\(label) 未重复上传", body: "这段已经在截图库里")
        } else {
            let reason = outcome.error.isEmpty ? "没有写入" : outcome.error
            let saved = FailedLibrary.save(id: tickets[index].libraryID, day: tickets[index].day, number: tickets[index].number, error: reason, png: png)
            tickets[index].libraryID = saved ?? tickets[index].libraryID
            tickets[index].phase = .failed(reason)
            onLibraryChange?()
            Notice.show(title: "\(label) 上传失败", body: saved == nil ? reason : "已存入失败库。\(reason)")
        }
        running = false
        publish()
        pump()
    }

    private func publish() {
        onChange?(tickets)
    }
}

private extension DateFormatter {
    static let stampKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum Notice {
    static func show(title: String, body: String) {
        let script = """
        display notification "\(escape(body))" with title "\(escape(title))" sound name "Glass"
        """
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

final class QueuePanel {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 12
        label.lineBreakMode = .byTruncatingTail
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        wrap.layer?.cornerRadius = 12
        wrap.autoresizingMask = [.width, .height]
        wrap.addSubview(label)
        panel.contentView = wrap
    }

    func render(_ tickets: [ShotTicket]) {
        hideWork?.cancel()
        let active = tickets.contains { $0.phase == .waiting || $0.phase == .running }
        if tickets.isEmpty {
            panel.orderOut(nil)
            return
        }
        let waiting = tickets.filter { $0.phase == .waiting }.count
        let current = tickets.first { $0.phase == .running }
        let header: String
        if let current {
            header = waiting > 0 ? "正在处理\(current.label) · 还有 \(waiting) 张" : "正在处理\(current.label)"
        } else {
            header = "入库队列  已完成 \(tickets.count) 张"
        }
        let lines = tickets.suffix(8).map { ticket -> String in
            "\(ticket.label)   \(Self.detail(ticket.phase))"
        }
        label.stringValue = ([header] + lines).joined(separator: "\n")
        let width: CGFloat = 340
        let textHeight = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 28, height: 800)).height ?? 40
        let height = max(52, textHeight + 22)
        label.frame = NSRect(x: 14, y: 10, width: width - 28, height: height - 20)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: frame.maxX - width - 16, y: frame.maxY - height - 8, width: width, height: height),
            display: true
        )
        panel.orderFrontRegardless()
        if !active {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private static func detail(_ phase: ShotPhase) -> String {
        switch phase {
        case .waiting:
            return "等待"
        case .running:
            return "理解并上传中"
        case .uploaded(let tags):
            return tags.isEmpty ? "已上传" : "已上传  \(tags)"
        case .skipped:
            return "已在库中"
        case .failed:
            return "失败，已存入失败库"
        }
    }
}
