import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey = HotkeyManager()
    private var overlay: ShotOverlay?
    private var capturing = false
    private let queue = IngestQueue()
    private let queuePanel = QueuePanel()
    private let retryItem = NSMenuItem(title: "重传失败库", action: #selector(retryFailed), keyEquivalent: "")
    private let openFailedItem = NSMenuItem(title: "打开失败库", action: #selector(openFailedLibrary), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "截图入库") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        let menu = NSMenu()
        let shot = NSMenuItem(title: "截图", action: #selector(capture), keyEquivalent: "")
        shot.keyEquivalent = String(UnicodeScalar(NSF2FunctionKey)!)
        shot.keyEquivalentModifierMask = []
        shot.target = self
        menu.addItem(shot)
        retryItem.target = self
        openFailedItem.target = self
        menu.addItem(retryItem)
        menu.addItem(openFailedItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        hotkey.onPress = { [weak self] in self?.capture() }
        hotkey.register()
        FailedLibrary.prepare()
        refreshLibraryMenu()
        queue.onLibraryChange = { [weak self] in self?.refreshLibraryMenu() }
        queue.onChange = { [weak self] tickets in
            self?.queuePanel.render(tickets)
            self?.showQueueCount(tickets)
        }
    }

    @objc private func capture() {
        guard overlay == nil, !capturing else { return }
        capturing = true
        Task {
            do {
                let shots = try await ScreenGrabber.capture()
                await MainActor.run {
                    self.capturing = false
                    self.present(shots)
                }
            } catch {
                await MainActor.run {
                    self.capturing = false
                    self.explain(error)
                }
            }
        }
    }

    private func present(_ shots: [ScreenGrabber.Shot]) {
        let overlay = ShotOverlay(shots: shots)
        overlay.onSave = { [weak self] image in
            Clipboard.copyPNG(image)
            self?.dismiss()
            Toast.show("已复制到剪贴板")
        }
        overlay.onIngest = { [weak self] image in
            guard let self else { return }
            let data = Clipboard.pngData(image)
            self.dismiss()
            if let data {
                self.queue.enqueue(data)
            } else {
                Notice.show(title: "上传失败", body: "没能生成图片")
            }
        }
        overlay.onCancel = { [weak self] in
            self?.dismiss()
        }
        self.overlay = overlay
        overlay.show()
    }

    @objc private func retryFailed() {
        for shot in FailedLibrary.all() {
            guard let data = try? Data(contentsOf: shot.file) else { continue }
            queue.enqueue(data, day: shot.day, number: shot.number, libraryID: shot.id)
        }
    }

    @objc private func openFailedLibrary() {
        FailedLibrary.reveal()
    }

    private func refreshLibraryMenu() {
        let count = FailedLibrary.count()
        retryItem.title = count > 0 ? "重传失败库（\(count)）" : "重传失败库"
        retryItem.isEnabled = count > 0
    }

    private func showQueueCount(_ tickets: [ShotTicket]) {
        let pending = tickets.filter { $0.phase == .waiting || $0.phase == .running }.count
        statusItem.length = pending > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = pending > 0 ? " 入库\(pending)" : ""
    }

    private func dismiss() {
        overlay?.close()
        overlay = nil
    }

    private func explain(_ error: Error) {
        if case CaptureError.permission = error {
            Notice.show(title: "还不能截图", body: "把「截图入库」开关关掉再打开，再按一次 F2。这次之后不会再弹窗。")
            let urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            ]
            for raw in urls {
                guard let url = URL(string: raw), NSWorkspace.shared.open(url) else { continue }
                break
            }
            return
        }
        Notice.show(title: "还不能截图", body: error.localizedDescription)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
enum ScreenshotIngestMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
