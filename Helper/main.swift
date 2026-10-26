import AppKit
import Darwin
import ScreenCaptureKit

private let port: UInt16 = 47821
private let askedURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/截图入库/permission-asked")

private func captureJSON() -> String {
    if !CGPreflightScreenCaptureAccess() {
        if !FileManager.default.fileExists(atPath: askedURL.path) {
            try? FileManager.default.createDirectory(at: askedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = CGRequestScreenCaptureAccess()
            try? Data("1".utf8).write(to: askedURL)
        }
        if !CGPreflightScreenCaptureAccess() {
            return #"{"ok":false,"error":"permission"}"#
        }
    }
    let semaphore = DispatchSemaphore(value: 0)
    var payload = #"{"ok":false,"error":"没有截到屏幕"}"#
    Task {
        do {
            payload = try await grab()
        } catch {
            let text = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            payload = #"{"ok":false,"error":"\#(text)"}"#
        }
        semaphore.signal()
    }
    semaphore.wait()
    return payload
}

private func grab() async throws -> String {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var shots: [[String: Any]] = []
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
        let file = folder.appendingPathComponent("\(displayID).png")
        try data.write(to: file)
        shots.append(["displayID": Int(displayID), "path": file.path])
    }
    if shots.isEmpty { throw CaptureHelperError.empty }
    let body: [String: Any] = ["ok": true, "shots": shots]
    let raw = try JSONSerialization.data(withJSONObject: body)
    return String(data: raw, encoding: .utf8) ?? #"{"ok":false,"error":"编码失败"}"#
}

private enum CaptureHelperError: Error { case empty }

private func serve() {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
        close(fd)
        return
    }
    while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        let text = captureJSON() + "\n"
        _ = text.withCString { write(client, $0, strlen($0)) }
        close(client)
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Thread.detachNewThread {
            serve()
        }
    }
}

let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
