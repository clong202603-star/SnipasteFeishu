import AppKit
import Darwin

enum ScreenGrabber {
    struct Shot {
        let screen: NSScreen
        let image: CGImage
    }

    static func capture() async throws -> [Shot] {
        var data = try HelperBridge.roundtrip()
        if HelperBridge.isPermission(data) {
            HelperBridge.relaunch()
            data = try HelperBridge.roundtrip()
        }
        if HelperBridge.isPermission(data) {
            throw CaptureError.permission
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureError.helper
        }
        if (object["ok"] as? Bool) != true {
            throw CaptureError.helper
        }
        let rows = object["shots"] as? [[String: Any]] ?? []
        var shots: [Shot] = []
        for row in rows {
            guard let displayID = row["displayID"] as? Int ?? (row["displayID"] as? NSNumber)?.intValue,
                  let path = row["path"] as? String,
                  let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let screen = NSScreen.screens.first { screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return number?.intValue == displayID
            }
            if let screen {
                shots.append(Shot(screen: screen, image: image))
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        if shots.isEmpty { throw CaptureError.empty }
        return shots
    }
}

enum CaptureError: LocalizedError {
    case permission
    case empty
    case helper

    var errorDescription: String? {
        switch self {
        case .permission:
            return "把「截图入库」的屏幕录制开关关掉再打开，再按 F2。"
        case .empty:
            return "没有截到屏幕。"
        case .helper:
            return "截图组件没有返回画面。"
        }
    }
}

enum HelperBridge {
    static let port: UInt16 = 47821
    static var appURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/截图入库/CaptureHelper.app")
    }

    static func isPermission(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (object["error"] as? String) == "permission"
    }

    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-x", "CaptureHelper"]
        try? process.run()
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", appURL.path]
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<30 {
            if portOpen() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func roundtrip() throws -> Data {
        if !portOpen() { relaunch() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CaptureError.helper }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw CaptureError.helper }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
            if buffer.contains(10) { break }
        }
        guard !buffer.isEmpty else { throw CaptureError.helper }
        return buffer
    }

    private static func portOpen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
