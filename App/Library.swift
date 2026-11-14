import Foundation
import ZIPFoundation

struct Novel: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let imported: Date
    var lastPlayed: Date?

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
    case missingGame, unsafeEntry, tooLarge, missingDemo

    var errorDescription: String? {
        switch self {
        case .missingGame: "No Ren’Py game folder was found."
        case .unsafeEntry: "The archive contains an unsupported file path."
        case .tooLarge: "The game is too large for the available storage."
        case .missingDemo: "The sample game is missing from this build."
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
        let novel = Novel(id: UUID(), title: title, imported: .now)
        let temp = games.appending(path: ".import-\(novel.id.uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let game = temp.appending(path: "game")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)

        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try importDirectory(source, into: game)
        } else {
            try importArchive(source, into: game)
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

    private static func write(_ novel: Novel, to folder: URL) throws {
        try JSONEncoder().encode(novel).write(to: folder.appending(path: "novel.json"), options: .atomic)
    }

    private static func safeParts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !parts.contains(".."), !parts.contains(".") else { throw ImportFailure.unsafeEntry }
        return parts.filter { !$0.isEmpty }
    }

    private static func importArchive(_ source: URL, into destination: URL) throws {
        let archive = try Archive(url: source, accessMode: .read)
        let isAPK = source.pathExtension.lowercased() == "apk"
        var entries: [(Entry, [String])] = []
        var possibleRoots: Set<[String]> = []
        for entry in archive {
            let parts = try safeParts(entry.path)
            guard entry.type == .file else { continue }
            entries.append((entry, parts))
            if let index = parts.dropLast().firstIndex(of: "game") {
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
