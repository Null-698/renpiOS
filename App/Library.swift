import Foundation
import ZIPFoundation
import zlib

struct Novel: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let imported: Date
    var lastPlayed: Date?
    var detectedEngine: String?
    var engineOverride: String?
    var orientation: GameOrientation?
    var gameFolder: String?
    var saveFolder: String?
    var saveIdentity: String?

    var root: URL { LibraryStore.games.appending(path: gameFolder ?? id.uuidString, directoryHint: .isDirectory) }
    var saves: URL { LibraryStore.saves.appending(path: saveFolder ?? id.uuidString, directoryHint: .isDirectory) }
    var titleIsManual: Bool?
    var gameKeys: [String]?
    var fingerprint: String?
    var contentDigest: String?
    var localCover: String?
    var coverScanned: Bool?
    var developer: String?
    var coverOverride: UUID?
    var automaticCoverDisabled: Bool?

    var customCover: URL? { coverOverride.map { root.appending(path: ".renios-cover-\($0.uuidString).jpg") } }

    var cover: URL? {
        let fm = FileManager.default
        if let customCover, fm.fileExists(atPath: customCover.path) { return customCover }
        let cached = root.appending(path: ".renios-archive-cover")
        let archived = fm.fileExists(atPath: cached.path) ? cached : nil
        if let localCover, !localCover.hasPrefix("/"),
           !localCover.split(separator: "/").contains("..") {
            let candidate = root.appending(path: "game").appending(path: localCover)
            if fm.fileExists(atPath: candidate.path) {
                let stem = candidate.deletingPathExtension().lastPathComponent.lowercased()
                return GameMetadata.iconNames.contains(stem) ? archived ?? candidate : candidate
            }
        }
        return archived
    }
}

enum ImportFailure: LocalizedError {
    case missingGame, unsafeEntry, tooLarge, missingDemo, missingSaves, missingMod
    case duplicate(String)
    case importChoiceRequired
    case saveFolderInUse

    var errorDescription: String? {
        switch self {
        case .importChoiceRequired: "Review the matching games or saves before installing."
        case .saveFolderInUse: "This save folder belongs to another installed game."
        case .duplicate(let title): "\(title) is already in your library."
        case .missingGame: "No Ren’Py game folder was found."
        case .unsafeEntry: "The archive contains an unsupported file path."
        case .tooLarge: "The game is too large for the available storage."
        case .missingDemo: "The sample game is missing from this build."
        case .missingSaves: "This archive contains no Ren’Py saves."
        case .missingMod: "No mod files were found."
        }
    }
}

enum LibraryStore {
    private static var documents: URL { URL.documentsDirectory.appending(path: "reniOS") }
    static var games: URL { documents.appending(path: "Games") }
    static var saves: URL { documents.appending(path: "Saves") }
    private static let fm = FileManager.default

    private struct SaveOwner: Codable {
        let game: UUID
        let identity: String
        var title: String?
        var gameKeys: [String]?
        var contentDigest: String?
    }

    struct RetainedSave: Identifiable, Sendable {
        let folder: URL
        let owner: UUID
        let title: String
        var id: URL { folder }
    }

    struct ImportPlan: Identifiable, Sendable {
        let incoming: Novel
        let staging: URL
        let matchingGames: [Novel]
        let retainedSaves: [RetainedSave]
        let exactSaves: RetainedSave?
        var id: UUID { incoming.id }
        var needsReview: Bool { !matchingGames.isEmpty || (!retainedSaves.isEmpty && exactSaves == nil) }
    }

    enum ImportChoice: Sendable {
        case fresh
        case update(Novel.ID)
        case attach(RetainedSave.ID)
    }

    private static func owner(at folder: URL) -> SaveOwner? {
        guard let data = try? Data(contentsOf: folder.appending(path: ".renios-save.json")) else { return nil }
        return try? JSONDecoder().decode(SaveOwner.self, from: data)
    }

    private static func registerSaves(for novel: Novel) throws {
        try fm.createDirectory(at: novel.saves, withIntermediateDirectories: true)
        let record = SaveOwner(game: novel.id, identity: novel.saveIdentity ?? identity(novel.title),
                               title: novel.title, gameKeys: novel.gameKeys, contentDigest: novel.contentDigest)
        try JSONEncoder().encode(record).write(to: novel.saves.appending(path: ".renios-save.json"), options: .atomic)
    }

    private static func folders(in parent: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    private static func readNovel(in folder: URL) -> Novel? {
        guard let data = try? Data(contentsOf: folder.appending(path: "novel.json")),
              var novel = try? JSONDecoder().decode(Novel.self, from: data) else { return nil }
        if novel.gameFolder != nil || folder.lastPathComponent != novel.id.uuidString {
            novel.gameFolder = folder.lastPathComponent
        }
        let saveName = novel.saveFolder ?? novel.id.uuidString
        guard !saveName.isEmpty, saveName != ".", saveName != "..",
              !saveName.contains("/"), !saveName.contains("\0") else { return nil }
        return novel
    }

    static func list() -> [Novel] {
        folders(in: games).compactMap { folder -> Novel? in
            guard let novel = readNovel(in: folder) else { return nil }
            let updated = updateMetadata(migrate(novel))
            recoverMod(for: updated)
            refreshSample(for: updated)
            return updated
        }.sorted { ($0.lastPlayed ?? $0.imported) > ($1.lastPlayed ?? $1.imported) }
    }

    private static func folderName(for title: String, in parent: URL) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var name = String(cleaned.prefix(70))
        while name.utf8.count > 160 { name.removeLast() }
        if name.isEmpty { name = "Untitled Game" }
        var candidate = name
        var number = 2
        while fm.fileExists(atPath: parent.appending(path: candidate).path) {
            candidate = "\(name) (\(number))"
            number += 1
        }
        return candidate
    }

    private static func identity(_ source: String) -> String {
        source.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func declaration(_ key: String, in game: URL) -> String? {
        let names = ["options.rpy", "script.rpy", "gui.rpy"]
        let pattern = #"(?m)^\s*(?:define\s+|\$\s*)?"# + NSRegularExpression.escapedPattern(for: key)
            + #"\s*=\s*(?:_\(\s*)?[uU]?(["'])([^\r\n]+?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for name in names {
            let path = game.appending(path: name)
            guard let info = try? path.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  info.isSymbolicLink != true, let size = info.fileSize, size < 524_288,
                  let source = try? String(contentsOf: path, encoding: .utf8),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let span = Range(match.range(at: 2), in: source) else { continue }
            let value = String(source[span]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func migrate(_ original: Novel) -> Novel {
        guard original.gameFolder == nil || original.saveFolder == nil else { return original }
        var novel = original
        let game = original.root.appending(path: "game")
        novel.title = declaration("config.name", in: game) ?? original.title
        novel.saveIdentity = original.saveIdentity ?? identity(declaration("build.name", in: game) ?? original.title)
        let oldSaves = original.saves
        if original.gameFolder == nil {
            novel.gameFolder = folderName(for: novel.title, in: games)
            do { try fm.moveItem(at: original.root, to: novel.root) }
            catch { novel.gameFolder = original.gameFolder }
        }
        if original.saveFolder == nil {
            novel.saveFolder = folders(in: saves).first(where: { $0.lastPathComponent != original.id.uuidString && owner(at: $0)?.game == novel.id })?.lastPathComponent
                ?? folderName(for: novel.title, in: saves)
            do {
                if fm.fileExists(atPath: oldSaves.path), oldSaves != novel.saves {
                    // Register ownership before the move so migration can resume after interruption.
                    var old = novel
                    old.saveFolder = original.id.uuidString
                    try registerSaves(for: old)
                    try fm.moveItem(at: oldSaves, to: novel.saves)
                }
                try registerSaves(for: novel)
            } catch {
                if fm.fileExists(atPath: oldSaves.path) { novel.saveFolder = nil }
            }
        }
        try? write(novel, to: novel.root)
        return novel
    }

    private static func updateMetadata(_ original: Novel) -> Novel {
        var novel = original
        if novel.coverScanned != true {
            let game = novel.root.appending(path: "game")
            let files = GameMetadata.files(in: game)
            let metadata = GameMetadata.declarations(in: files)
            if novel.titleIsManual == nil {
                novel.titleIsManual = !GameMetadata.machineTitle(novel.title)
                    && GameMetadata.filenameTitle(novel.title) == novel.title
            }
            if novel.titleIsManual != true, let title = GameMetadata.displayTitle(metadata["config.name"]) {
                novel.title = title
            }
            novel.gameKeys = GameMetadata.identityKeys(package: novel.saveIdentity, save: metadata["config.save_directory"],
                build: metadata["build.name"], title: metadata["config.name"])
            novel.fingerprint = GameMetadata.fingerprint(files, in: game)
            novel.localCover = GameMetadata.localCover(files: files, in: game, declarations: metadata)
            novel.developer = metadata["config.developer"]
            novel.coverScanned = true
        }
        if novel.coverOverride == nil {
            let archived = novel.root.appending(path: ".renios-archive-cover")
            if fm.fileExists(atPath: archived.path), !GameMetadata.validImage(archived) {
                try? fm.removeItem(at: archived)
            }
        }
        if let data = try? Data(contentsOf: novel.root.appending(path: ".renios-runtime.json")),
           let metadata = try? JSONDecoder().decode(GameMetadata.Runtime.self, from: data) {
            if novel.titleIsManual != true, let title = GameMetadata.displayTitle(metadata.title) {
                novel.title = title
            }
            if let developer = GameMetadata.displayTitle(metadata.developer) { novel.developer = developer }
            let keys = GameMetadata.identityKeys(package: nil, save: metadata.saveDirectory,
                build: metadata.buildName, title: metadata.title)
            novel.gameKeys = Array(Set((novel.gameKeys ?? []) + keys)).sorted()
        }
        if novel != original { try? write(novel, to: novel.root) }
        return novel
    }

    static func setCover(_ data: Data?, for novel: Novel) throws {
        guard let current = readNovel(in: novel.root), current.id == novel.id else {
            throw CocoaError(.fileNoSuchFile)
        }
        var updated = current
        updated.coverOverride = data.map { _ in UUID() }
        if data == nil { updated.automaticCoverDisabled = true }
        if let data, let url = updated.customCover {
            try data.write(to: url, options: .atomic)
        }
        do { try write(updated, to: updated.root) }
        catch {
            if let url = updated.customCover { try? fm.removeItem(at: url) }
            throw error
        }
        if let old = current.customCover { try? fm.removeItem(at: old) }
    }

    static func recordPlay(_ novel: Novel) throws {
        var updated = novel
        updated.lastPlayed = .now
        try write(updated, to: novel.root)
    }

    static func delete(_ novel: Novel, keepingSaves: Bool = true) throws {
        if keepingSaves, fm.fileExists(atPath: novel.saves.path) {
            try registerSaves(for: novel)
        }
        try fm.removeItem(at: novel.root)
        if !keepingSaves, fm.fileExists(atPath: novel.saves.path) {
            try fm.removeItem(at: novel.saves)
        }
    }

    static func install(_ source: URL, title: String? = nil, checkDuplicates: Bool = true) throws -> Novel {
        let plan = try prepareImport(source, title: title, checkDuplicates: checkDuplicates)
        defer { discardImport(plan) }
        guard !plan.needsReview else { throw ImportFailure.importChoiceRequired }
        return try finishImport(plan, choice: plan.exactSaves.map { .attach($0.id) } ?? .fresh)
    }

    static func prepareImport(_ source: URL, title override: String? = nil,
                              checkDuplicates: Bool = true) throws -> ImportPlan {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let filename = source.deletingPathExtension().lastPathComponent
        var novel = Novel(id: UUID(), title: override ?? filename, imported: .now)
        let temp = games.appending(path: ".import-\(novel.id.uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: temp) } }
        let game = temp.appending(path: "game")
        var apkTitle: String?
        var apkIdentifier: String?
        var projectName: String?
        try fm.createDirectory(at: game, withIntermediateDirectories: true)

        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try importDirectory(source, into: game)
            novel.detectedEngine = detectInDirectory(source)
        } else {
            let metadata = try importArchive(source, into: game)
            novel.detectedEngine = metadata.engine
            apkTitle = metadata.title
            apkIdentifier = metadata.identifier
            projectName = metadata.project
        }

        guard containsScripts(in: game) else { throw ImportFailure.missingGame }
        let files = GameMetadata.files(in: game)
        let metadata = GameMetadata.declarations(in: files)
        let scriptTitle = GameMetadata.displayTitle(metadata["config.name"])
        novel.title = override ?? scriptTitle ?? GameMetadata.displayTitle(apkTitle)
            ?? GameMetadata.filenameTitle(projectName ?? filename) ?? GameMetadata.filenameTitle(filename)
            ?? GameMetadata.filenameTitle(metadata["build.name"] ?? "") ?? filename
        novel.titleIsManual = override != nil
        novel.fingerprint = GameMetadata.fingerprint(files, in: game)
        novel.gameKeys = GameMetadata.identityKeys(package: apkIdentifier, save: metadata["config.save_directory"],
                                                 build: metadata["build.name"], title: scriptTitle)
        novel.localCover = GameMetadata.localCover(files: files, in: game, declarations: metadata)
        novel.coverScanned = true
        novel.developer = metadata["config.developer"]

        novel.contentDigest = try GameMetadata.contentDigest(in: game)
        let key = identity(override ?? apkIdentifier ?? metadata["build.name"] ?? filename)
        novel.saveIdentity = key
        var matchingGames: [Novel] = []
        var retainedSaves: [RetainedSave] = []
        var exactSaves: [RetainedSave] = []
        if checkDuplicates {
            let existing = folders(in: games).compactMap { readNovel(in: $0) }.map(updateMetadata)
            let keys = Set(novel.gameKeys ?? [])
            for current in existing {
                let sharedID = !keys.isDisjoint(with: current.gameKeys ?? [])
                let similarFiles = novel.fingerprint != nil && novel.fingerprint == current.fingerprint
                var digest = current.contentDigest
                if digest == nil, sharedID || similarFiles {
                    digest = try? GameMetadata.contentDigest(in: pristineGame(for: current))
                }
                if let digest, digest == novel.contentDigest { throw ImportFailure.duplicate(current.title) }
                if sharedID { matchingGames.append(current) }
            }
            let installedIDs = Set(existing.map(\.id))
            let installedFolders = Set(existing.map { $0.saves.standardizedFileURL.path })
            for folder in folders(in: saves) {
                guard let record = owner(at: folder), !installedIDs.contains(record.game),
                      !installedFolders.contains(folder.standardizedFileURL.path) else { continue }
                let match = RetainedSave(folder: folder, owner: record.game,
                                         title: record.title ?? folder.lastPathComponent)
                if let digest = record.contentDigest, digest == novel.contentDigest {
                    exactSaves.append(match)
                    retainedSaves.append(match)
                } else if record.identity == key || !keys.isDisjoint(with: record.gameKeys ?? []) {
                    retainedSaves.append(match)
                }
            }
        }
        prepared = true
        return ImportPlan(incoming: novel, staging: temp,
                          matchingGames: matchingGames.sorted { $0.root.path < $1.root.path },
                          retainedSaves: retainedSaves.sorted { $0.folder.path < $1.folder.path },
                          exactSaves: exactSaves.count == 1 ? exactSaves.first : nil)
    }

    static func discardImport(_ plan: ImportPlan) {
        try? fm.removeItem(at: plan.staging)
    }

    static func discardAbandonedImports() {
        let entries = (try? fm.contentsOfDirectory(at: games, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".import-") {
            guard UUID(uuidString: String(entry.lastPathComponent.dropFirst(8))) != nil else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    static func finishImport(_ plan: ImportPlan, choice: ImportChoice) throws -> Novel {
        let existing = folders(in: games).compactMap { readNovel(in: $0) }
        var incoming = plan.incoming
        switch choice {
        case .update(let id):
            guard plan.matchingGames.contains(where: { $0.id == id }),
                  var updated = existing.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
            let current = updated
            guard !existing.contains(where: { $0.id != id && $0.saves.standardizedFileURL.path == updated.saves.standardizedFileURL.path }),
                  owner(at: updated.saves).map({ $0.game == id }) ?? true else {
                throw ImportFailure.saveFolderInUse
            }
            if updated.titleIsManual != true { updated.title = incoming.title }
            updated.detectedEngine = incoming.detectedEngine
            updated.gameKeys = incoming.gameKeys
            updated.fingerprint = incoming.fingerprint
            updated.contentDigest = incoming.contentDigest
            updated.localCover = incoming.localCover
            updated.coverScanned = incoming.coverScanned
            updated.developer = incoming.developer
            if let cover = current.customCover, fm.fileExists(atPath: cover.path) {
                try fm.copyItem(at: cover, to: plan.staging.appending(path: cover.lastPathComponent))
            }
            try retainMods(for: current, in: plan.staging)
            try write(updated, to: plan.staging)
            _ = try fm.replaceItemAt(current.root, withItemAt: plan.staging, options: [.usingNewMetadataOnly])
            try? registerSaves(for: updated)
            return updated

        case .attach(let folder):
            guard let candidate = plan.retainedSaves.first(where: { $0.id == folder }),
                  owner(at: folder)?.game == candidate.owner,
                  !existing.contains(where: { $0.id == candidate.owner || $0.saves.standardizedFileURL.path == folder.standardizedFileURL.path }) else {
                throw ImportFailure.saveFolderInUse
            }
            incoming.saveFolder = folder.lastPathComponent

        case .fresh:
            incoming.saveFolder = folderName(for: incoming.title, in: saves)
        }
        incoming.gameFolder = folderName(for: incoming.title, in: games)
        try write(incoming, to: plan.staging)
        try fm.moveItem(at: plan.staging, to: incoming.root)
        do { try registerSaves(for: incoming) }
        catch {
            try? fm.removeItem(at: incoming.root)
            throw error
        }
        return incoming
    }

    private static func refreshSample(for novel: Novel) {
        guard novel.saveIdentity == identity("The Observatory"),
              let bundled = Bundle.main.url(forResource: "base", withExtension: nil)?.appending(path: "Demo/game")
        else { return }
        let game = novel.root.appending(path: "game")
        let confirm = game.appending(path: "confirm.rpy")
        guard !fm.fileExists(atPath: confirm.path),
              let script = try? String(contentsOf: game.appending(path: "script.rpy"), encoding: .utf8),
              script.contains("Who should sign the visitor’s book?"),
              script.contains("the keeper left you a choice.") else { return }
        try? fm.copyItem(at: bundled.appending(path: "confirm.rpy"), to: confirm)
    }

    static func installDemo() throws -> Novel {
        guard let root = Bundle.main.url(forResource: "base", withExtension: nil) else {
            throw ImportFailure.missingDemo
        }
        return try install(root.appending(path: "Demo"), title: "The Observatory")
    }

    static func rename(_ novel: Novel, to title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != novel.title else { return }
        var updated = novel
        updated.title = title
        updated.titleIsManual = true
        updated.gameFolder = folderName(for: title, in: games)
        try write(updated, to: novel.root)
        try fm.moveItem(at: novel.root, to: updated.root)
        if fm.fileExists(atPath: novel.saves.path) {
            updated.saveFolder = folderName(for: title, in: saves)
            // Ownership allows discovery of the directory if metadata persistence fails.
            try registerSaves(for: novel)
            try fm.moveItem(at: novel.saves, to: updated.saves)
            do { try write(updated, to: updated.root) }
            catch {
                try? fm.moveItem(at: updated.saves, to: novel.saves)
                throw error
            }
        }
    }

    struct SaveSlot: Identifiable, Sendable {
        let url: URL
        let date: Date
        var id: String { url.lastPathComponent }
    }

    static func slots(for novel: Novel) -> [SaveSlot] {
        folders(in: novel.saves).compactMap { url -> SaveSlot? in
            guard url.pathExtension.lowercased() == "save",
                  let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
            return SaveSlot(url: url, date: info.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    static func thumbnail(for slot: SaveSlot) -> Data? {
        guard let archive = try? Archive(url: slot.url, accessMode: .read),
              let screenshot = archive["screenshot.png"], screenshot.type == .file,
              screenshot.uncompressedSize <= 2 * 1024 * 1024 else { return nil }
        var data = Data()
        do { _ = try archive.extract(screenshot) { data.append($0) } }
        catch { return nil }
        return data
    }

    static func duplicate(_ slot: SaveSlot) throws {
        let stem = slot.url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        let directory = slot.url.deletingLastPathComponent()
        if parts.count >= 2, Int(parts[1]) != nil {
            for page in 1...999 {
                for number in 1...6 {
                    let suffix = parts.dropFirst(2).map(String.init)
                    let name = ([String(page), String(number)] + suffix).joined(separator: "-") + ".save"
                    let output = directory.appending(path: name)
                    if !fm.fileExists(atPath: output.path) {
                        try fm.copyItem(at: slot.url, to: output)
                        return
                    }
                }
            }
        }
        let name = folderName(for: stem + " Backup", in: directory)
        let output = directory.appending(path: "\(name)-\(UUID().uuidString.prefix(8)).save")
        try fm.copyItem(at: slot.url, to: output)
    }

    struct InstalledMod: Identifiable, Sendable {
        let id: UUID
        let name: String
        let enabled: Bool
    }

    private static func modStore(in root: URL) -> URL { root.appending(path: ".mods") }
    private static func modBaseline(in root: URL) -> URL { root.appending(path: ".mods-original") }
    private static func legacyMod(in root: URL) -> URL { root.appending(path: ".mod") }
    private static func modState(in game: URL) -> URL { game.appending(path: ".renios-mod-state.json") }

    private static func enabledMods(in game: URL) throws -> [UUID] {
        let state = modState(in: game)
        guard fm.fileExists(atPath: state.path) else { return [] }
        return try JSONDecoder().decode([UUID].self, from: Data(contentsOf: state))
    }

    private static func writeMods(_ ids: [UUID], in game: URL) throws {
        try JSONEncoder().encode(ids).write(to: modState(in: game), options: .atomic)
    }

    static func installedMods(for novel: Novel) -> [InstalledMod] {
        let game = novel.root.appending(path: "game")
        let enabled = Set((try? enabledMods(in: game)) ?? [])
        var mods = folders(in: modStore(in: novel.root)).compactMap { dir -> InstalledMod? in
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let name = try? String(contentsOf: dir.appending(path: "name"), encoding: .utf8),
                  fm.fileExists(atPath: dir.appending(path: "payload").path) else { return nil }
            return InstalledMod(id: id, name: name, enabled: enabled.contains(id))
        }
        if let name = legacyModName(for: novel) {
            mods.removeAll { $0.id == novel.id }
            mods.append(InstalledMod(id: novel.id, name: name, enabled: true))
        }
        return mods.sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
    }

    private static func legacyModName(for novel: Novel) -> String? {
        let folder = legacyMod(in: novel.root)
        guard !fm.fileExists(atPath: modState(in: novel.root.appending(path: "game")).path),
              fm.fileExists(atPath: folder.appending(path: "original").path) else { return nil }
        return try? String(contentsOf: folder.appending(path: "name"), encoding: .utf8)
    }

    private static func recoverMod(for novel: Novel) {
        let game = novel.root.appending(path: "game")
        let original = legacyMod(in: novel.root).appending(path: "original")
        if !fm.fileExists(atPath: game.path), fm.fileExists(atPath: original.path) {
            try? fm.moveItem(at: original, to: game)
        }
    }

    private static func pristineGame(for novel: Novel) -> URL {
        let baseline = modBaseline(in: novel.root)
        let game = novel.root.appending(path: "game")
        if (try? enabledMods(in: game).isEmpty) == false { return baseline }
        if legacyModName(for: novel) != nil { return legacyMod(in: novel.root).appending(path: "original") }
        return game
    }

    private static func retainLegacyMod(for novel: Novel, in root: URL) throws {
        guard let name = legacyModName(for: novel) else { return }
        let game = novel.root.appending(path: "game")
        let original = legacyMod(in: novel.root).appending(path: "original")
        let package = modStore(in: root).appending(path: novel.id.uuidString)
        if fm.fileExists(atPath: package.path) { try fm.removeItem(at: package) }
        let payload = package.appending(path: "payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let depth = game.standardizedFileURL.pathComponents.count
        for file in GameMetadata.files(in: game, includeTranslations: true) {
            let ext = file.pathExtension.lowercased()
            let parts = file.standardizedFileURL.pathComponents.dropFirst(depth)
            let vanilla = parts.reduce(original) { $0.appending(path: $1) }
            if ext == "rpyb" { continue }
            if ["rpyc", "pyc", "pyo"].contains(ext) {
                let sourceExtension = ext == "rpyc" ? "rpy" : "py"
                let source = file.deletingPathExtension().appendingPathExtension(sourceExtension)
                let vanillaSource = vanilla.deletingPathExtension().appendingPathExtension(sourceExtension)
                if fm.fileExists(atPath: source.path),
                   !fm.fileExists(atPath: vanilla.path) ||
                    !fm.contentsEqual(atPath: source.path, andPath: vanillaSource.path) { continue }
            }
            if fm.contentsEqual(atPath: file.path, andPath: vanilla.path) { continue }
            let destination = parts.reduce(payload) { $0.appending(path: $1) }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: destination)
        }
        try name.write(to: package.appending(path: "name"), atomically: true, encoding: .utf8)
    }

    private static func migrateLegacyMod(for novel: Novel) throws {
        guard legacyModName(for: novel) != nil else { return }
        try retainLegacyMod(for: novel, in: novel.root)
        let baseline = modBaseline(in: novel.root)
        if fm.fileExists(atPath: baseline.path) { try fm.removeItem(at: baseline) }
        let folder = legacyMod(in: novel.root)
        try fm.copyItem(at: folder.appending(path: "original"), to: baseline)
        try writeMods([novel.id], in: novel.root.appending(path: "game"))
        try? fm.removeItem(at: folder)
    }

    private static func retainMods(for novel: Novel, in staging: URL) throws {
        let store = modStore(in: novel.root)
        if fm.fileExists(atPath: store.path) {
            try fm.copyItem(at: store, to: modStore(in: staging))
        }
        try retainLegacyMod(for: novel, in: staging)
    }

    private static func modPayload(in archive: Archive) throws -> [(Entry, [String])] {
        var files: [(Entry, [String])] = []
        for entry in archive {
            let parts = try safeParts(entry.path)
            if entry.type == .symlink { throw ImportFailure.unsafeEntry }
            guard entry.type == .file, !parts.isEmpty,
                  !parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { continue }
            files.append((entry, parts))
        }
        guard !files.isEmpty else { throw ImportFailure.missingMod }
        let prefixes = Set(files.compactMap { _, parts -> [String]? in
            parts.dropLast().firstIndex(of: "game").map { Array(parts[...$0]) }
        })
        let prefix = prefixes.count == 1 ? prefixes.first : nil
        let payload: [(Entry, [String])] = files.compactMap { entry, parts in
            guard let prefix else { return (entry, parts) }
            guard parts.starts(with: prefix), parts.count > prefix.count else { return nil }
            return (entry, Array(parts.dropFirst(prefix.count)))
        }
        guard prefixes.count <= 1, !payload.isEmpty else { throw ImportFailure.missingMod }

        return payload
    }

    static func modConflicts(_ source: URL, on novel: Novel) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let archive = try Archive(url: source, accessMode: .read)
        let game = novel.root.appending(path: "game")
        return try modPayload(in: archive).filter { _, parts in
            let file = parts.reduce(game) { $0.appending(path: $1) }
            return fm.fileExists(atPath: file.path)
        }.count
    }

    @discardableResult
    static func installMod(_ source: URL, on novel: Novel, replacing old: UUID? = nil) throws -> Int {
        try migrateLegacyMod(for: novel)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let archive = try Archive(url: source, accessMode: .read)
        let entries = try modPayload(in: archive)
        let game = novel.root.appending(path: "game")
        let enabled = try enabledMods(in: game)
        let id = UUID()
        let store = modStore(in: novel.root)
        let package = store.appending(path: id.uuidString)
        let oldPackage = old.map { store.appending(path: $0.uuidString) }
        if let oldPackage, !fm.fileExists(atPath: oldPackage.path) { throw ImportFailure.missingMod }
        let payload = package.appending(path: "payload")
        var installed = false
        defer { if !installed { try? fm.removeItem(at: package) } }
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let space = (try? payload.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        var available = UInt64(max(0, space))
        var seen: Set<String> = []
        var conflicts = 0
        for (entry, parts) in entries {
            guard seen.insert(identity(parts.joined(separator: "/"))).inserted else { throw ImportFailure.unsafeEntry }
            let size = UInt64(entry.uncompressedSize)
            guard size <= available else { throw ImportFailure.tooLarge }
            available -= size
            let output = parts.reduce(payload) { $0.appending(path: $1) }
            if fm.fileExists(atPath: parts.reduce(game, { $0.appending(path: $1) }).path) { conflicts += 1 }
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: output)
        }
        let name = source.deletingPathExtension().lastPathComponent
        try name.write(to: package.appending(path: "name"), atomically: true, encoding: .utf8)

        if let old {
            if enabled.contains(old) {
                try applyMods(enabled.map { $0 == old ? id : $0 }, to: novel)
            }
            if let oldPackage { try? fm.removeItem(at: oldPackage) }
        } else {
            try applyMods(enabled + [id], to: novel)
        }
        installed = true
        return conflicts
    }

    static func setMod(_ id: UUID, enabled: Bool, on novel: Novel) throws {
        try migrateLegacyMod(for: novel)
        guard fm.fileExists(atPath: modStore(in: novel.root).appending(path: id.uuidString).path) else {
            throw ImportFailure.missingMod
        }
        let current = try enabledMods(in: novel.root.appending(path: "game"))
        guard current.contains(id) != enabled else { return }
        try applyMods(enabled ? current + [id] : current.filter { $0 != id }, to: novel)
    }

    static func removeMod(_ id: UUID, from novel: Novel) throws {
        try setMod(id, enabled: false, on: novel)
        try fm.removeItem(at: modStore(in: novel.root).appending(path: id.uuidString))
    }

    private static func applyMods(_ ids: [UUID], to novel: Novel) throws {
        let game = novel.root.appending(path: "game")
        let baseline = modBaseline(in: novel.root)
        if try enabledMods(in: game).isEmpty {
            if fm.fileExists(atPath: baseline.path) { try fm.removeItem(at: baseline) }
            try fm.copyItem(at: game, to: baseline)
        }
        let staged = novel.root.appending(path: ".mod-build")
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: baseline, to: staged)
        for id in ids {
            let payload = modStore(in: novel.root).appending(path: id.uuidString).appending(path: "payload")
            try overlayMod(from: payload, into: staged)
        }
        try writeMods(ids, in: staged)
        _ = try fm.replaceItemAt(game, withItemAt: staged, options: [.usingNewMetadataOnly])
        if ids.isEmpty { try? fm.removeItem(at: baseline) }
    }

    private static func overlayMod(from payload: URL, into game: URL) throws {
        for path in try fm.subpathsOfDirectory(atPath: payload.path) {
            let parts = try safeParts(path)
            let file = parts.reduce(payload) { $0.appending(path: $1) }
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            var output = game
            for part in parts {
                output = output.appending(path: part)
                guard (try? output.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                    throw ImportFailure.unsafeEntry
                }
            }
            if fm.fileExists(atPath: output.path) {
                guard try output.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ImportFailure.unsafeEntry
                }
                try fm.removeItem(at: output)
            }
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: output)
        }
    }

    static func diagnostics(for novel: Novel, engine: String?) -> String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        var lines = [novel.title, "reniOS " + appVersion,
                     "Ren’Py " + (engine ?? "Unavailable"), ProcessInfo.processInfo.operatingSystemVersionString]
        for filename in ["traceback.txt", "errors.txt", "log.txt"] {
            let url = novel.root.appending(path: filename)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            try? handle.seek(toOffset: size > 48_000 ? size - 48_000 : 0)
            if let data = try? handle.read(upToCount: 48_000), !data.isEmpty {
                lines += ["", filename, String(decoding: data, as: UTF8.self)]
            }
        }
        return lines.joined(separator: "\n")
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

        guard try checkImportIdentity(in: fixtures) else { return false }

        let desktop = fixtures.appending(path: "desktop")
        try add("version = '8.3.4.25010101'", at: "Novel/renpy/vc_version.py", in: desktop)
        try add("label start:\n    return", at: "Novel/game/script.rpy", in: desktop)
        try add("define config.name = _(\"The Sample Novel\")", at: "Novel/game/options.rpy", in: desktop)
        let zip = fixtures.appending(path: "novel.zip")
        try fm.zipItem(at: desktop, to: zip, shouldKeepParent: false)
        let novel = try install(zip)
        defer {
            try? delete(novel)
            try? fm.removeItem(at: novel.saves)
        }
        let copy = fixtures.appending(path: "renamed-copy.zip")
        try fm.copyItem(at: zip, to: copy)
        do {
            let copy = try install(copy)
            try? delete(copy, keepingSaves: false)
            return false
        } catch ImportFailure.duplicate {}

        let android = fixtures.appending(path: "android")
        try add("label start:\n    return", at: "assets/x-game/x-script.rpy", in: android)
        // Use RAPT’s private.mp3 layout for the Android fixture.
        let privateData = Data(base64Encoded: "H4sIAAAAAAACA+3RsQrCMBSF4Tv7FNm6xZs0TVx8FhHp0KWW1Bb69qYiCM4ihf7fci5nOcPNbT8sx/l2mds8dvfeDov8mhYxhFcW36lah8+99s5FH8Wo/ME0Pq65zMs+vd9uzmaqkj3ZZH2jtUvqq4MAAAAAAAAAAAAAAAAAADbrCUT0DV0AKAAA")!
        try privateData.write(to: android.appending(path: "assets/private.mp3"))
        try Data(base64Encoded: "AwAIAOgAAAABABwAcAAAAAUAAAAAAAAAAAEAADAAAAAAAAAAAAAAAAsAAAAVAAAAKQAAADcAAAAICG1hbmlmZXN0AAcHcGFja2FnZQAREWNvbS5leGFtcGxlLm5vdmVsAAsLYXBwbGljYXRpb24ABQVsYWJlbAAAAgEQADgAAAABAAAA//////////8AAAAAFAAUAAEAAAAAAAAA/////wEAAAACAAAACAAAAwIAAAACARAAOAAAAAEAAAD//////////wMAAAAUABQAAQAAAAAAAAD/////BAAAAP////8IAAABAAAFfw==")!.write(to: android.appending(path: "AndroidManifest.xml"))
        try Data(base64Encoded: "AgAMAIwBAAABAAAAAQAcADQAAAABAAAAAAAAAAABAAAgAAAAAAAAAAAAAAAREVRoZSBBbmRyb2lkIE5vdmVsAAACIAFMAQAAfwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAECGAAsAAAABQAAAAEAAAAcAAAABAAAAAAAAAAIAAAAAAAAAAgAAAMAAAAA")!.write(to: android.appending(path: "resources.arsc"))
        let apk = fixtures.appending(path: "novel.apk")
        try fm.zipItem(at: android, to: apk, shouldKeepParent: false)
        let mobile = try install(apk)
        defer { try? delete(mobile, keepingSaves: false) }

        guard novel.title == "The Sample Novel", novel.root.lastPathComponent.hasPrefix(novel.title),
              novel.saves.lastPathComponent.hasPrefix(novel.title),
              novel.detectedEngine == "8.3.4", mobile.detectedEngine == "7.8.7",
              mobile.title == "The Android Novel", mobile.saveIdentity == "com.example.novel",
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
        guard replaceCount == 2, (try? String(contentsOf: slot, encoding: .utf8)) == "backup",
              fm.fileExists(atPath: novel.saves.appending(path: "2-1-LT1.save").path) else { return false }
        try delete(novel)
        let reinstalled = try install(zip)
        defer { try? delete(reinstalled, keepingSaves: false) }
        guard reinstalled.saves == novel.saves, LibraryStore.slots(for: reinstalled).count == 2 else { return false }

        let mod = fixtures.appending(path: "mod")
        try add("modded", at: "game/script.rpy", in: mod)
        let modZip = fixtures.appending(path: "mod.zip")
        try fm.zipItem(at: mod, to: modZip, shouldKeepParent: false)
        let script = reinstalled.root.appending(path: "game/script.rpy")
        guard try modConflicts(modZip, on: reinstalled) == 1,
              try installMod(modZip, on: reinstalled) == 1,
              try String(contentsOf: script, encoding: .utf8) == "modded" else { return false }
        guard let installed = installedMods(for: reinstalled).first, installed.enabled else { return false }
        try setMod(installed.id, enabled: false, on: reinstalled)
        guard try String(contentsOf: script, encoding: .utf8) == "label start:\n    return",
              installedMods(for: reinstalled).first?.enabled == false else { return false }
        try setMod(installed.id, enabled: true, on: reinstalled)
        try removeMod(installed.id, from: reinstalled)
        return try String(contentsOf: script, encoding: .utf8) == "label start:\n    return"
    }
    private static func checkImportIdentity(in fixtures: URL) throws -> Bool {
        let token = UUID().uuidString
        let title = "Identity Test " + token
        func source(_ parent: String, bytes: String) throws -> URL {
            let root = fixtures.appending(path: parent).appending(path: "SameArchive")
            let game = root.appending(path: "game")
            try fm.createDirectory(at: game, withIntermediateDirectories: true)
            let script = "define config.name = \"\(title)\"\ndefine config.save_directory = \"\(token)\"\nlabel start:\n    return"
            try Data(script.utf8).write(to: game.appending(path: "script.rpy"))
            try Data(bytes.utf8).write(to: game.appending(path: "story.txt"))
            return root
        }

        let first = try source("first", bytes: "AAAA")
        let newer = try source("newer", bytes: "BBBB")
        let unrelated = try source("unrelated", bytes: "CCCC")
        var cleanup: [Novel] = []
        defer {
            for game in cleanup.reversed() {
                if fm.fileExists(atPath: game.root.path) { try? delete(game, keepingSaves: false) }
            }
            if let first = cleanup.first { try? fm.removeItem(at: first.saves) }
        }

        let installed = try install(first)
        cleanup.append(installed)
        let slot = installed.saves.appending(path: "progress.save")
        try Data("progress".utf8).write(to: slot)

        let separatePlan = try prepareImport(newer)
        defer { discardImport(separatePlan) }
        guard separatePlan.matchingGames.map(\.id) == [installed.id] else { return false }
        let separate = try finishImport(separatePlan, choice: .fresh)
        cleanup.append(separate)
        guard separate.saves != installed.saves,
              !fm.fileExists(atPath: separate.saves.appending(path: "progress.save").path) else { return false }
        try delete(separate, keepingSaves: false)
        cleanup.removeLast()

        // Recreate the format used by already installed mods before the update.
        let legacy = legacyMod(in: installed.root)
        let installedGame = installed.root.appending(path: "game")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.copyItem(at: installedGame, to: legacy.appending(path: "original"))
        try "Legacy patch".write(to: legacy.appending(path: "name"), atomically: true, encoding: .utf8)
        let story = installedGame.appending(path: "story.txt")
        try Data("MOD1".utf8).write(to: story)
        guard installedMods(for: installed).first?.enabled == true else { return false }
        let archiveRoot = fixtures.appending(path: "additional-mod")
        try fm.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try Data("MOD2".utf8).write(to: archiveRoot.appending(path: "story.txt"))
        let archive = fixtures.appending(path: "extra.zip")
        try fm.zipItem(at: archiveRoot, to: archive, shouldKeepParent: false)
        try installMod(archive, on: installed)
        guard installedMods(for: installed).filter(\.enabled).count == 2,
              try String(contentsOf: story, encoding: .utf8) == "MOD2" else { return false }

        let updatePlan = try prepareImport(newer)
        defer { discardImport(updatePlan) }
        let updated = try finishImport(updatePlan, choice: .update(installed.id))
        guard updated.id == installed.id, updated.root == installed.root, updated.saves == installed.saves,
              try String(contentsOf: updated.root.appending(path: "game/story.txt"), encoding: .utf8) == "BBBB",
              try String(contentsOf: slot, encoding: .utf8) == "progress" else { return false }

        let mods = installedMods(for: updated)
        guard mods.count == 2, mods.allSatisfy({ !$0.enabled }),
              let legacyPatch = mods.first(where: { $0.name == "Legacy patch" }),
              let extra = mods.first(where: { $0.name == "extra" }) else { return false }
        try setMod(legacyPatch.id, enabled: true, on: updated)
        guard try String(contentsOf: story, encoding: .utf8) == "MOD1" else { return false }
        try setMod(extra.id, enabled: true, on: updated)
        try setMod(extra.id, enabled: false, on: updated)
        guard try String(contentsOf: story, encoding: .utf8) == "MOD1" else { return false }
        try installMod(archive, on: updated, replacing: extra.id)
        guard installedMods(for: updated).first(where: { $0.name == "extra" })?.enabled == false else { return false }
        try setMod(legacyPatch.id, enabled: false, on: updated)
        guard try String(contentsOf: story, encoding: .utf8) == "BBBB" else { return false }
        try delete(updated)

        let freshPlan = try prepareImport(unrelated)
        defer { discardImport(freshPlan) }
        guard freshPlan.needsReview, freshPlan.exactSaves == nil,
              freshPlan.retainedSaves.map({ $0.folder.path }) == [installed.saves.path] else { return false }
        let fresh = try finishImport(freshPlan, choice: .fresh)
        cleanup.append(fresh)
        guard fresh.saves != installed.saves, fm.fileExists(atPath: slot.path),
              !fm.fileExists(atPath: fresh.saves.appending(path: "progress.save").path) else { return false }
        try delete(fresh, keepingSaves: false)
        cleanup.removeLast()

        let attachPlan = try prepareImport(unrelated)
        defer { discardImport(attachPlan) }
        guard let retained = attachPlan.retainedSaves.first else { return false }
        let attached = try finishImport(attachPlan, choice: .attach(retained.id))
        cleanup.append(attached)
        return attached.saves.path == installed.saves.path && fm.fileExists(atPath: slot.path)
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

    private static func importArchive(_ source: URL, into destination: URL)
        throws -> (engine: String?, title: String?, identifier: String?, project: String?) {
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
        guard isAPK else { return (detected, nil, nil, prefix.dropLast().last) }
        func androidFile(_ path: String, limit: Int) -> Data? {
            guard let entry = entries.first(where: { $0.1 == [path] })?.0,
                  UInt64(entry.uncompressedSize) <= UInt64(limit) else { return nil }
            var data = Data()
            do { _ = try archive.extract(entry) { data.append($0) } }
            catch { return nil }
            return data
        }
        let details = androidFile("AndroidManifest.xml", limit: 524_288).map { manifest in
            APKTitle.read(manifest: manifest) { androidFile("resources.arsc", limit: 16 * 1024 * 1024) }
        }
        return (detected ?? detectInAndroidPrivateData(archive, entries: entries), details?.title, details?.identifier, nil)
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
