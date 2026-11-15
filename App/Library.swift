import Foundation
import ZIPFoundation
import zlib

struct Novel: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let imported: Date
    var lastPlayed: Date?
    var detectedEngine: String?
    var engineOverride: String?
    var orientation: GameOrientation?

    var root: URL { LibraryStore.games.appending(path: id.uuidString, directoryHint: .isDirectory) }
    var saves: URL { LibraryStore.saves.appending(path: id.uuidString, directoryHint: .isDirectory) }
    var cover: URL? {
        let game = root.appending(path: "game")
        for filename in ["cover.png", "cover.jpg", "gui/main_menu.png", "gui/main_menu.jpg"] {
            let candidate = game.appending(path: filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

enum ImportFailure: LocalizedError {
    case missingGame, unsafeEntry, tooLarge, missingDemo, missingSaves

    var errorDescription: String? {
        switch self {
        case .missingGame: "No Ren’Py game folder was found."
        case .unsafeEntry: "The archive contains an unsupported file path."
        case .tooLarge: "The game is too large for the available storage."
        case .missingDemo: "The sample game is missing from this build."
        case .missingSaves: "This archive contains no Ren’Py saves."
        }
    }
}

enum LibraryStore {
    private static var documents: URL { URL.documentsDirectory.appending(path: "reniOS") }
    static var games: URL { documents.appending(path: "Games") }
    static var saves: URL { documents.appending(path: "Saves") }
    private static let fm = FileManager.default

    static func list() -> [Novel] {
        let folders = (try? fm.contentsOfDirectory(at: games, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "novel.json")) else { return nil }
            return try? JSONDecoder().decode(Novel.self, from: data)
        }.sorted { ($0.lastPlayed ?? $0.imported) > ($1.lastPlayed ?? $1.imported) }
    }

    static func recordPlay(_ novel: Novel) throws {
        var updated = novel
        updated.lastPlayed = .now
        try write(updated, to: novel.root)
    }

    static func delete(_ novel: Novel) throws {
        try fm.removeItem(at: novel.root)
        // Saves live outside the game payload and remain available in Files.
    }

    static func install(_ source: URL, title override: String? = nil) throws -> Novel {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let title = override ?? source.deletingPathExtension().lastPathComponent
        var novel = Novel(id: UUID(), title: title, imported: .now)
        let temp = games.appending(path: ".import-\(novel.id.uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let game = temp.appending(path: "game")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)

        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try importDirectory(source, into: game)
            novel.detectedEngine = detectInDirectory(source)
        } else {
            novel.detectedEngine = try importArchive(source, into: game)
        }

        guard containsScripts(in: game) else { throw ImportFailure.missingGame }
        try write(novel, to: temp)
        try fm.moveItem(at: temp, to: novel.root)
        return novel
    }

    static func installDemo() throws -> Novel {
        guard let root = Bundle.main.url(forResource: "base", withExtension: nil) else {
            throw ImportFailure.missingDemo
        }
        return try install(root.appending(path: "Demo"), title: "The Observatory")
    }

    static func backup(_ novel: Novel) throws -> URL {
        let destination = URL.temporaryDirectory.appending(path: "reniOS-\(UUID().uuidString).zip")
        try fm.createDirectory(at: novel.saves, withIntermediateDirectories: true)
        try fm.zipItem(at: novel.saves, to: destination, shouldKeepParent: false, compressionMethod: .deflate)
        return destination
    }

    static func update(_ novel: Novel) throws {
        try write(novel, to: novel.root)
    }

    static func restore(_ source: URL, to novel: Novel, replacing: Bool) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let archive = try Archive(url: source, accessMode: .read)
        var entries: [(Entry, String)] = []
        var names: Set<String> = []
        var directories: Set<[String]> = []
        for entry in archive {
            let parts = try safeParts(entry.path)
            guard let name = parts.last, name == "persistent" || name.lowercased().hasSuffix(".save") else {
                continue
            }
            let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
            guard entry.type == .file, names.insert(normalized).inserted else {
                throw ImportFailure.unsafeEntry
            }
            directories.insert(Array(parts.dropLast()))
            entries.append((entry, name))
        }
        guard !entries.isEmpty else { throw ImportFailure.missingSaves }
        guard directories.count == 1 else { throw ImportFailure.unsafeEntry }

        try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let staging = saves.appending(path: ".restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let alreadyExists = fm.fileExists(atPath: novel.saves.path)
        if alreadyExists {
            try fm.copyItem(at: novel.saves, to: staging)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        }

        var count = 0
        for (entry, name) in entries {
            let destination = staging.appending(path: name)
            if fm.fileExists(atPath: destination.path) {
                guard replacing else { continue }
                try fm.removeItem(at: destination)
            }
            _ = try archive.extract(entry, to: destination)
            count += 1
        }
        guard count > 0 else { return 0 }
        if alreadyExists {
            _ = try fm.replaceItemAt(novel.saves, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: novel.saves)
        }
        return count
    }

    #if DEBUG
    static func checkImportsAndSaves() throws -> Bool {
        let fixtures = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixtures) }
        func add(_ contents: String, at path: String, in directory: URL) throws {
            let output = directory.appending(path: path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: output)
        }

        let desktop = fixtures.appending(path: "desktop")
        try add("version = '8.3.4.25010101'", at: "Novel/renpy/vc_version.py", in: desktop)
        try add("label start:\n    return", at: "Novel/game/script.rpy", in: desktop)
        let zip = fixtures.appending(path: "novel.zip")
        try fm.zipItem(at: desktop, to: zip, shouldKeepParent: false)
        let novel = try install(zip)
        defer {
            try? delete(novel)
            try? fm.removeItem(at: novel.saves)
        }

        let android = fixtures.appending(path: "android")
        try add("label start:\n    return", at: "assets/x-game/x-script.rpy", in: android)
        // Use RAPT’s private.mp3 layout for the Android fixture.
        let privateData = Data(base64Encoded: "H4sIAAAAAAACA+3RsQrCMBSF4Tv7FNm6xZs0TVx8FhHp0KWW1Bb69qYiCM4ihf7fci5nOcPNbT8sx/l2mds8dvfeDov8mhYxhFcW36lah8+99s5FH8Wo/ME0Pq65zMs+vd9uzmaqkj3ZZH2jtUvqq4MAAAAAAAAAAAAAAAAAADbrCUT0DV0AKAAA")!
        try privateData.write(to: android.appending(path: "assets/private.mp3"))
        let apk = fixtures.appending(path: "novel.apk")
        try fm.zipItem(at: android, to: apk, shouldKeepParent: false)
        let mobile = try install(apk)
        defer { try? delete(mobile) }

        guard novel.detectedEngine == "8.3.4", mobile.detectedEngine == "7.8.7",
              fm.fileExists(atPath: mobile.root.appending(path: "game/script.rpy").path),
              EngineVersion.choose(for: novel.detectedEngine, from: ["8.3.4", "8.3.7", "8.6.0"], default: "8.6.0") == "8.3.4",
              EngineVersion.choose(for: mobile.detectedEngine, from: ["8.6.0"], default: "8.6.0") == nil else {
            return false
        }

        let saved = fixtures.appending(path: "saved")
        try add("backup", at: "1-1-LT1.save", in: saved)
        try add("persistent", at: "persistent", in: saved)
        let saveZip = fixtures.appending(path: "saves.zip")
        try fm.zipItem(at: saved, to: saveZip, shouldKeepParent: false)
        try add("current", at: "1-1-LT1.save", in: novel.saves)
        try add("unrelated", at: "2-1-LT1.save", in: novel.saves)
        let slot = novel.saves.appending(path: "1-1-LT1.save")
        let keepCount = try restore(saveZip, to: novel, replacing: false)
        guard keepCount == 1, try String(contentsOf: slot, encoding: .utf8) == "current" else { return false }
        let replaceCount = try restore(saveZip, to: novel, replacing: true)
        return replaceCount == 2 && (try? String(contentsOf: slot, encoding: .utf8)) == "backup"
            && fm.fileExists(atPath: novel.saves.appending(path: "2-1-LT1.save").path)
    }
    #endif

    private static func write(_ novel: Novel, to folder: URL) throws {
        try JSONEncoder().encode(novel).write(to: folder.appending(path: "novel.json"), options: .atomic)
    }

    private static func safeParts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !parts.contains(".."), !parts.contains(".") else { throw ImportFailure.unsafeEntry }
        return parts.filter { !$0.isEmpty }
    }

    private static let metadataLimit = 256 * 1024

    private static func detectInDirectory(_ source: URL) -> String? {
        let engine = source.appending(path: "renpy")
        guard let info = try? engine.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink != true else { return nil }
        for name in EngineVersion.metadata {
            let file = engine.appending(path: name)
            guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true,
                  let bytes = info.fileSize, bytes <= metadataLimit,
                  let data = try? Data(contentsOf: file) else { continue }
            if let version = EngineVersion.detect(in: data, filename: name) { return version }
        }
        return nil
    }

    private static func detectInArchive(_ archive: Archive, entries: [(Entry, [String])],
                                        project: [String], android: Bool) -> String? {
        let candidates = entries.compactMap { entry, parts -> (Entry, String, Int)? in
            let normalized = android ? parts.map { $0.hasPrefix("x-") ? String($0.dropFirst(2)) : $0 } : parts
            guard EngineVersion.isMetadata(normalized),
                  UInt64(entry.uncompressedSize) <= UInt64(metadataLimit),
                  let name = normalized.last, let rank = EngineVersion.metadata.firstIndex(of: name) else { return nil }
            let root = Array(normalized.dropLast(2))
            guard root == project || (android && (root == ["assets"] || root == ["assets", "private"])) else {
                return nil
            }
            return (entry, name, rank)
        }
        for (entry, name, _) in candidates.sorted(by: { $0.2 < $1.2 }).prefix(12) {
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
                if let version = EngineVersion.detect(in: data, filename: name) { return version }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func detectInAndroidPrivateData(_ archive: Archive, entries: [(Entry, [String])]) -> String? {
        let limit = 96 * 1024 * 1024
        guard let (entry, _) = entries.first(where: { $0.1 == ["assets", "private.mp3"] }),
              UInt64(entry.uncompressedSize) <= UInt64(limit) else { return nil }
        let temporary = URL.temporaryDirectory.appending(path: "reniOS-\(UUID().uuidString).tar.gz")
        defer { try? fm.removeItem(at: temporary) }
        guard (try? archive.extract(entry, to: temporary)) != nil,
              let stream = gzopen(temporary.path, "rb") else { return nil }
        defer { gzclose(stream) }

        func read(_ count: Int) -> Data? {
            var data = Data(count: count)
            let bytes = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                gzread(stream, buffer.baseAddress, UInt32(count))
            }
            return bytes == Int32(count) ? data : nil
        }
        func string(_ field: Data.SubSequence) -> String {
            String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
        }
        var metadata: [String: String] = [:]
        var position = 0
        while position + 512 <= limit, let header = read(512), header.contains(where: { $0 != 0 }) {
            position += 512
            let sizeString = string(header[124..<136]).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeString, radix: 8), size >= 0, size <= limit - position else { break }
            let next = position + (size + 511) / 512 * 512
            guard next <= limit else { break }

            let name = string(header[0..<100])
            let prefix = string(header[345..<500])
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let parts = path.split(separator: "/").map(String.init)
            if (header[156] == 0 || header[156] == 48), size > 0, size <= metadataLimit,
               Array(parts.dropLast()) == ["renpy"], let filename = parts.last, EngineVersion.metadata.contains(filename),
               let data = read(size), let version = EngineVersion.detect(in: data, filename: filename) {
                metadata[filename] = version
                if filename == "vc_version.py" { return version }
            }
            guard Int(gzseek(stream, numericCast(next), SEEK_SET)) == next else { break }
            position = next
        }
        return EngineVersion.metadata.compactMap { metadata[$0] }.first
    }

    private static func importArchive(_ source: URL, into destination: URL) throws -> String? {
        let archive = try Archive(url: source, accessMode: .read)
        let isAPK = source.pathExtension.lowercased() == "apk"
        var entries: [(Entry, [String])] = []
        var possibleRoots: Set<[String]> = []
        for entry in archive {
            let parts = try safeParts(entry.path)
            guard entry.type == .file else { continue }
            entries.append((entry, parts))
            if let index = parts.dropLast().firstIndex(of: "game"),
               let name = parts.last, ["rpy", "rpyc", "rpa"].contains((name as NSString).pathExtension.lowercased()) {
                possibleRoots.insert(Array(parts[...index]))
            }
        }

        var prefix = possibleRoots.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.joined(separator: "/") < rhs.joined(separator: "/") : lhs.count < rhs.count
        }.first
        var stripAndroidPrefix = false
        if isAPK {
            let packaged = ["assets", "x-game"]
            if entries.contains(where: { $0.1.starts(with: packaged) }) {
                prefix = packaged
                stripAndroidPrefix = true
            } else if prefix == nil && entries.contains(where: { $0.1.starts(with: ["assets"]) }) {
                prefix = ["assets"]
                stripAndroidPrefix = true
            }
        }
        guard let prefix else { throw ImportFailure.missingGame }

        let volume = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let space = volume?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        var available = UInt64(max(0, space))
        var destinations: Set<String> = []
        for (entry, parts) in entries where parts.starts(with: prefix) && parts.count > prefix.count {
            let relative = parts.dropFirst(prefix.count).map { component in
                stripAndroidPrefix && component.hasPrefix("x-") ? String(component.dropFirst(2)) : component
            }
            guard !relative.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw ImportFailure.unsafeEntry
            }
            let key = relative.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            guard destinations.insert(key).inserted else { throw ImportFailure.unsafeEntry }
            let size = UInt64(entry.uncompressedSize)
            guard size <= available else { throw ImportFailure.tooLarge }
            available -= size
            let output = relative.reduce(destination) { $0.appending(path: $1) }
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: output)
        }
        let detected = detectInArchive(archive, entries: entries, project: Array(prefix.dropLast()), android: isAPK)
        if let detected { return detected }
        return isAPK ? detectInAndroidPrivateData(archive, entries: entries) : nil
    }

    private static func importDirectory(_ source: URL, into destination: URL) throws {
        let nested = source.appending(path: "game")
        let root = fm.fileExists(atPath: nested.path) ? nested : source
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ImportFailure.unsafeEntry
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let contents = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsHiddenFiles]) else {
            throw ImportFailure.missingGame
        }
        let count = root.standardizedFileURL.pathComponents.count
        for case let file as URL in contents {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw ImportFailure.unsafeEntry }
            let parts = file.standardizedFileURL.pathComponents.dropFirst(count)
            let output = parts.reduce(destination) { $0.appending(path: $1) }
            if values.isDirectory == true {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fm.copyItem(at: file, to: output)
            }
        }
    }

    private static func containsScripts(in game: URL) -> Bool {
        guard let files = fm.enumerator(at: game, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in files {
            if ["rpy", "rpyc", "rpa"].contains(file.pathExtension.lowercased()) { return true }
        }
        return false
    }
}
