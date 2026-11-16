import CryptoKit
import Foundation
import ImageIO

enum GameMetadata {
    struct Runtime: Decodable {
        var title: String?
        var version: String?
        var modsActive: Bool?
        var saveDirectory: String?
        var buildName: String?
        var developer: String?
    }

    static let iconNames: Set<String> = ["icon", "window_icon", "app_icon"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "avif", "heic", "bmp"]
    private static let genericNames: Set<String> = ["game", "renpy", "ren'py", "ren'py game", "ren’py game", "untitled", "mygame", "example", "unknown"]

    static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func machineTitle(_ value: String) -> Bool {
        let value = key(value)
        return genericNames.contains(value) ||
            value.range(of: #"^[a-z][a-z0-9_-]*(?:\.[a-z0-9_-]+){2,}$"#, options: .regularExpression) != nil
    }

    static func displayTitle(_ input: String?) -> String? {
        guard let input else { return nil }
        let value = input.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !value.isEmpty, !machineTitle(value) else { return nil }
        return String(value.prefix(160))
    }

    static func filenameTitle(_ filename: String) -> String? {
        guard !machineTitle(filename) else { return nil }
        let value = filename.replacingOccurrences(
            of: #"(?i)(?:[-_ .]+(?:win(?:dows)?|linux|mac(?:os)?|android|pc|universal|v?\d+(?:\.\d+)+(?:[a-z]+\d*)?))+$"#,
            with: "", options: .regularExpression
        ).replacingOccurrences(of: "_", with: " ")
        return displayTitle(value)
    }

    static func files(in root: URL, includeTranslations: Bool = false) -> [URL] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let excludedFolders = ["cache", "saves", "__pycache__"] + (includeTranslations ? [] : ["tl"])
        var result: [URL] = []
        for case let file as URL in files {
            if excludedFolders.contains(file.lastPathComponent.lowercased()),
               (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                files.skipDescendants()
                continue
            }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
                .map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true {
                result.append(file)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func declarations(in files: [URL]) -> [String: String] {
        let prioritized = files.filter { $0.pathExtension.lowercased() == "rpy" }
        let options = prioritized.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == "options" }
        let rest = prioritized.filter { !options.contains($0) }
        let pattern = #"(?m)^[\t ]*(?:(?:define|default|\$)[\t ]+)?((?:config\.(?:name|version|save_directory|window_icon|developer)|build\.(?:name|directory_name)|gui\.main_menu_background))[\t ]*=[\t ]*(?:(?:__|_)\([\t ]*)?[uUrR]?(["'])((?:\\.|(?!\2)[^\r\n])*)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var values: [String: String] = [:]
        for file in (options + rest).prefix(160) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let name = Range(match.range(at: 1), in: source),
                      let range = Range(match.range(at: 3), in: source) else { continue }
                let key = String(source[name])
                if key == "config.version", let full = Range(match.range, in: source) {
                    let remainder = source[full.upperBound...].prefix(while: { !$0.isNewline })
                    guard remainder.range(of: #"^\s*\)?\s*(?:#.*)?$"#, options: .regularExpression) != nil else { continue }
                }
                let literal = String(source[range]).replacingOccurrences(of: #"\(["'\])"#,
                                                                          with: "$1", options: .regularExpression)
                if !literal.isEmpty, values[key] == nil { values[key] = literal }
            }
            if values.count == 8 { break }
        }
        return values
    }

    static func versionLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 72,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return label
    }

    static func packagedVersion(_ project: String?) -> String? {
        guard let project, let range = project.range(
            of: #"(?i)(?<=-)[v]?[0-9]+(?:\.[0-9]+)+(?:[._-]?(?:alpha|beta|rc|a|b)[0-9]*)?(?=-(?:pc|win|windows|mac|linux|market)$)"#,
            options: .regularExpression
        ) else { return nil }
        return versionLabel(String(project[range]))
    }

    static func compareVersions(_ incoming: String?, _ installed: String?) -> ComparisonResult? {
        guard let incoming = versionLabel(incoming), let installed = versionLabel(installed) else { return nil }
        if incoming.caseInsensitiveCompare(installed) == .orderedSame { return .orderedSame }
        guard let lhs = orderedVersion(incoming), let rhs = orderedVersion(installed) else { return nil }
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = lhs.parts.indices.contains(index) ? lhs.parts[index] : 0
            let b = rhs.parts.indices.contains(index) ? rhs.parts[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if lhs.stage != rhs.stage { return lhs.stage < rhs.stage ? .orderedAscending : .orderedDescending }
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    private static func orderedVersion(_ label: String) -> (parts: [Int], stage: Int, revision: Int)? {
        let pattern = #"^v?([0-9]+(?:\.[0-9]+)*)(?:[ ._-]*(alpha|beta|rc|a|b)[ ._-]*([0-9]*))?(?:\+[a-z0-9.-]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let core = Range(match.range(at: 1), in: label) else { return nil }
        let numbers = label[core].split(separator: ".")
        let parts = numbers.compactMap { Int($0) }
        guard parts.count == numbers.count else { return nil }
        guard let suffix = Range(match.range(at: 2), in: label) else { return (parts, 3, 0) }
        let stage = ["a": 0, "alpha": 0, "b": 1, "beta": 1, "rc": 2][label[suffix].lowercased()] ?? 3
        let revision = Range(match.range(at: 3), in: label).map { label[$0] } ?? ""
        guard let count = Int(revision.isEmpty ? "0" : revision) else { return nil }
        return (parts, stage, count)
    }

    static func identityKeys(package: String?, save: String?, build: String?, title: String?) -> [String] {
        var result: [String] = []
        if let package, package.range(of: #"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*){2,}$"#,
                                       options: .regularExpression) != nil,
           !["org.renpy", "com.example", "com.test"].contains(where: package.hasPrefix) {
            result.append("package:" + key(package))
        }
        if let save, !machineTitle(save), key(save).count >= 4 { result.append("save:" + key(save)) }
        if let build, let title, !machineTitle(build), !machineTitle(title), key(build).count >= 4 {
            result.append("build:" + key(build) + ":" + key(title))
        }
        return result
    }

    static func fingerprint(_ files: [URL], in folder: URL) -> String? {
        let sourcePaths = Set(files.filter { $0.pathExtension.lowercased() == "rpy" }
            .map { $0.deletingPathExtension().path.lowercased() })
        let scripts = files.filter { file in
            switch file.pathExtension.lowercased() {
            case "rpy", "rpa": true
            case "rpyc": !sourcePaths.contains(file.deletingPathExtension().path.lowercased())
            default: false
            }
        }.prefix(512)
        guard !scripts.isEmpty else { return nil }
        var hash = SHA256()
        let limit = 48 * 1024
        let count = folder.standardizedFileURL.pathComponents.count
        let resources = files.filter { file in
            !["rpy", "rpyc", "rpa", "rpyb", "pyc"].contains(file.pathExtension.lowercased())
        }
        for resource in resources {
            guard let size = try? resource.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            let path = resource.standardizedFileURL.pathComponents.dropFirst(count).joined(separator: "/")
            hash.update(data: Data((path + "\0" + String(size) + "\0").utf8))
        }
        for file in scripts {
            guard let handle = try? FileHandle(forReadingFrom: file),
                  let size = try? handle.seekToEnd() else { return nil }
            defer { try? handle.close() }
            let path = file.standardizedFileURL.pathComponents.dropFirst(count).joined(separator: "/")
            hash.update(data: Data((path + "\0" + String(size) + "\0").utf8))
            do {
                try handle.seek(toOffset: 0)
                hash.update(data: try handle.read(upToCount: limit) ?? Data())
                if size > UInt64(limit) {
                    try handle.seek(toOffset: max(UInt64(limit), size - UInt64(limit)))
                    hash.update(data: try handle.read(upToCount: limit) ?? Data())
                }
            } catch { return nil }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func contentDigest(in folder: URL) throws -> String {
        let files = files(in: folder, includeTranslations: true)
        let paths = Set(files.map(\.path))
        let depth = folder.standardizedFileURL.pathComponents.count
        var hash = SHA256()
        for file in files {
            let ext = file.pathExtension.lowercased()
            let source = file.deletingPathExtension()
            if ext == "rpyb" ||
                (ext == "rpyc" && paths.contains(source.appendingPathExtension("rpy").path)) ||
                (["pyc", "pyo"].contains(ext) && paths.contains(source.appendingPathExtension("py").path)) {
                continue
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let path = file.standardizedFileURL.pathComponents.dropFirst(depth).joined(separator: "/")
            hash.update(data: Data((path + "\0" + String(size) + "\0").utf8))
            var remaining = size
            while remaining > 0 {
                let bytes = try handle.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
                guard !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                hash.update(data: bytes)
                remaining -= UInt64(bytes.count)
            }
            if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func localCover(files: [URL], in game: URL, declarations: [String: String]) -> String? {
        let rootCount = game.standardizedFileURL.pathComponents.count
        let icon = declarations["config.window_icon"]?.lowercased()
        let background = declarations["gui.main_menu_background"]?.lowercased()
        let candidates = files.compactMap { file -> (URL, String, Int)? in
            guard imageExtensions.contains(file.pathExtension.lowercased()) else { return nil }
            let part = file.standardizedFileURL.pathComponents.dropFirst(rootCount).joined(separator: "/")
            let path = part.lowercased()
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            let rank: Int
            if ["cover", "boxart", "box_art", "poster", "keyart", "key_art", "game_cover", "cover_art"].contains(name) {
                rank = 0
            } else if path == background { rank = 1 }
            else if ["main_menu", "mainmenu", "title_screen", "title_background", "menubg", "menu_background"].contains(name) { rank = 2 }
            else if path == icon { rank = 3 }
            else if iconNames.contains(name) || (path.hasPrefix("gui/") && name == "title") { rank = 4 }
            else { return nil }
            return (file, part, rank)
        }.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? (lhs.1.count, lhs.1) < (rhs.1.count, rhs.1) : lhs.2 < rhs.2
        }
        return candidates.prefix(60).first { validImage($0.0) }?.1
    }

    static func validImage(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width >= 64 && height >= 64 && width <= 16_384 && height <= 16_384
    }
}
