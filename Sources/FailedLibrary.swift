import AppKit

struct FailedShot {
    let id: String
    let day: Int
    let number: Int
    let error: String
    let file: URL
}

enum FailedLibrary {
    static func prepare() {
        let folder = supportDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("config.json")
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        let text = "{\n  \"failedLibrary\": \"\"\n}\n"
        try? text.write(to: config, atomically: true, encoding: .utf8)
    }

    static func directory() -> URL {
        let folder = supportDirectory()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = (json["failedLibrary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = folder.appendingPathComponent("failed", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func count() -> Int {
        all().count
    }

    static func all() -> [FailedShot] {
        let folder = directory()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> FailedShot? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let day = json["day"] as? Int ?? (json["day"] as? NSNumber)?.intValue,
                  let number = json["number"] as? Int ?? (json["number"] as? NSNumber)?.intValue else { return nil }
            let png = folder.appendingPathComponent("\(id).png")
            guard FileManager.default.fileExists(atPath: png.path) else { return nil }
            return FailedShot(id: id, day: day, number: number, error: json["error"] as? String ?? "", file: png)
        }.sorted { lhs, rhs in
            if lhs.day == rhs.day { return lhs.number < rhs.number }
            return lhs.day < rhs.day
        }
    }

    @discardableResult
    static func save(id: String?, day: Int, number: Int, error: String, png: Data) -> String? {
        let folder = directory()
        let shotID = id ?? UUID().uuidString
        let image = folder.appendingPathComponent("\(shotID).png")
        let meta = folder.appendingPathComponent("\(shotID).json")
        do {
            try png.write(to: image, options: .atomic)
            let body: [String: Any] = [
                "id": shotID,
                "day": day,
                "number": number,
                "error": error,
            ]
            let raw = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])
            try raw.write(to: meta, options: .atomic)
            return shotID
        } catch {
            return nil
        }
    }

    static func remove(id: String) {
        let folder = directory()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id).png"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id).json"))
    }

    static func reveal() {
        NSWorkspace.shared.open(directory())
    }

    private static func supportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/截图入库", isDirectory: true)
    }
}
