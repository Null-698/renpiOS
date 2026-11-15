import Foundation

struct EngineVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count), let major = Int(parts[0]), major > 0,
              let minor = Int(parts[1]), minor >= 0, let patch = Int(parts[2]), patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var name: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func choose(for detected: String?, from installed: [String], default fallback: String) -> String? {
        let versions = installed.compactMap(Self.init).sorted()
        guard let detected = detected.flatMap(Self.init) else {
            return installed.contains(fallback) ? fallback : versions.last?.name
        }
        let family = versions.filter { $0.major == detected.major }
        let series = family.filter { $0.minor == detected.minor }
        return (series.first { $0 >= detected } ?? series.last
            ?? family.first { $0 >= detected } ?? family.last)?.name
    }

    static func detect(in data: Data, filename: String) -> String? {
        let contents = String(decoding: data, as: UTF8.self)
        let dotted = #"([0-9]{1,2}\.[0-9]{1,3}\.[0-9]{1,3})(?:\.[0-9]{1,12})?"#
        if filename.hasSuffix(".py") {
            let assignment = #"(?m)^\s*(?:version|version_only)\s*=\s*['"](?:Ren['’]Py\s+)?"# + dotted + #"['"]"#
            if let found = match(assignment, in: contents) { return found }
            let tuple = #"(?m)^\s*version_tuple\s*=\s*(?:VersionTuple\s*)?\(\s*([0-9]{1,2})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*[,\)]"#
            return match(tuple, in: contents)
        }
        // In vc_version bytecode, the full build string is a Python constant.
        // Read only the bytes and never load game code into the host.
        if filename.hasPrefix("vc_version.") {
            return match(#"(?<![0-9.])"# + dotted + #"(?![0-9.])"#, in: contents)
        }
        return match(#"Ren['’]Py\s+"# + dotted + #"(?![0-9.])"#, in: contents)
    }

    private static func match(_ pattern: String, in contents: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)) else {
            return nil
        }
        let fields = (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: contents).map { String(contents[$0]) }
        }
        return Self(fields.joined(separator: "."))?.name
    }

    static let metadata = ["vc_version.py", "vc_version.pyc", "vc_version.pyo", "__init__.py", "__init__.pyc", "__init__.pyo"]

    static func isMetadata(_ parts: [String]) -> Bool {
        parts.count >= 2 && parts[parts.count - 2] == "renpy" && metadata.contains(parts.last ?? "")
    }
}

enum GameOrientation: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "Auto"
    case portrait = "Portrait"
    case landscape = "Landscape"

    var id: Self { self }

    var sdlHint: String? {
        switch self {
        case .automatic: nil
        case .portrait: "Portrait PortraitUpsideDown"
        case .landscape: "LandscapeLeft LandscapeRight"
        }
    }
}
