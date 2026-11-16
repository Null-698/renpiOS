import CryptoKit
import Foundation
import ImageIO

enum GameMetadata {
    struct Runtime: Decodable {
        var title: String?
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

    static func files(in root: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let file as URL in files {
            if ["cache", "saves", "__pycache__", "tl"].contains(file.lastPathComponent.lowercased()),
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
        let pattern = #"(?m)^[\t ]*(?:(?:define|default|\$)[\t ]+)?((?:config\.(?:name|save_directory|window_icon|developer)|build\.(?:name|directory_name)|gui\.main_menu_background))[\t ]*=[\t ]*(?:(?:__|_)\([\t ]*)?[uUrR]?(["'])((?:\\.|(?!\2)[^\r\n])*)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var values: [String: String] = [:]
        for file in (options + rest).prefix(160) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let name = Range(match.range(at: 1), in: source),
                      let range = Range(match.range(at: 3), in: source) else { continue }
                let key = String(source[name])
                let literal = String(source[range]).replacingOccurrences(of: #"\(["'\])"#,
                                                                          with: "$1", options: .regularExpression)
                if !literal.isEmpty, values[key] == nil { values[key] = literal }
            }
            if values.count == 7 { break }
        }
        return values
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
