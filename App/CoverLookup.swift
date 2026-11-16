import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum CoverLookup {
    struct Candidate: Decodable, Identifiable {
        struct Alternate: Decodable {
            let title: String
            let latin: String?
        }

        struct Developer: Decodable {
            let name: String
            let original: String?
        }

        struct Artwork: Decodable {
            let url: URL
            let thumbnail: URL?
            let sexual: Double
            let violence: Double
        }

        let id: String
        let title: String
        let alttitle: String?
        let titles: [Alternate]?
        let developers: [Developer]?
        let image: Artwork?
        var page: URL? { URL(string: "https://vndb.org/" + id) }
    }

    private struct Response: Decodable {
        let results: [Candidate]
        let more: Bool
    }

    static func match(title: String, developer: String?) async throws -> Candidate? {
        guard !GameMetadata.machineTitle(title),
              let url = URL(string: "https://api.vndb.org/kana/vn") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filters": ["search", "=", title],
            "fields": "title,alttitle,titles.title,titles.latin,developers.name,developers.original,image.url,image.thumbnail,image.sexual,image.violence",
            "sort": "searchrank", "results": 50
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let output = try JSONDecoder().decode(Response.self, from: data)
        let key = GameMetadata.key(title)
        let studio = developer.map(GameMetadata.key)
        let matches = output.results.filter { entry in
            let alt = (entry.titles ?? []).flatMap { [$0.title, $0.latin].compactMap { $0 } }
            let names = [entry.title, entry.alttitle].compactMap { $0 } + alt
            guard names.contains(where: { GameMetadata.key($0) == key }) else { return false }
            guard let studio else { return true }
            return (entry.developers ?? []).contains { person in
                GameMetadata.key(person.name) == studio || person.original.map(GameMetadata.key) == studio
            }
        }
        guard !output.more, matches.count == 1, let match = matches.first, let image = match.image,
              image.sexual < 0.1, image.violence < 0.5, isVNDBImage(image.url) else { return nil }
        return match
    }

    static func isVNDBImage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "t.vndb.org"
    }

    static func download(_ url: URL) async throws -> Data {
        guard isVNDBImage(url) else { throw URLError(.badURL) }
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = response.url, isVNDBImage(finalURL) else { throw URLError(.badServerResponse) }
        return try jpeg(from: file)
    }

    static func jpeg(from file: URL) throws -> Data {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
              GameMetadata.validImage(file),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

struct CoverFinder: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let developer: String?
    let save: (Data) throws -> Void
    @State private var candidate: CoverLookup.Candidate?
    @State private var searching = true
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if searching {
                        ProgressView("Looking for an exact title")
                    } else if let candidate, let image = candidate.image {
                        AsyncImage(url: image.thumbnail.flatMap { CoverLookup.isVNDBImage($0) ? $0 : nil } ?? image.url) { phase in
                            if let artwork = phase.image {
                                artwork.resizable().scaledToFit()
                            } else {
                                Color.clear.overlay { ProgressView() }
                            }
                        }
                        .frame(height: 210)
                        .clipShape(.rect(cornerRadius: 13))
                        Text(candidate.title)
                            .font(.headline)
                        if let developers = candidate.developers, !developers.isEmpty {
                            Text(developers.map(\.name).joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Use This Cover") { install(image.url) }
                            .buttonStyle(.glassProminent)
                            .disabled(saving)
                        if let url = candidate.page { Link("View on VNDB", destination: url) }
                    } else {
                        Text("No unique cover match.")
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if let googleImages { Link("Search Google Images", destination: googleImages) }
                }
                .frame(maxWidth: .infinity)
                .padding(18)
            }
            .navigationTitle("Find Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task {
            defer { searching = false }
            do { candidate = try await CoverLookup.match(title: title, developer: developer) }
            catch { message = "Online search is unavailable." }
        }
    }

    private var googleImages: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [.init(name: "tbm", value: "isch"),
            .init(name: "q", value: "\"\(title)\" \(developer ?? "") visual novel cover")]
        return components?.url
    }

    private func install(_ url: URL) {
        saving = true
        Task {
            defer { saving = false }
            do {
                let data = try await CoverLookup.download(url)
                try save(data)
                dismiss()
            } catch { message = "Couldn’t save this cover." }
        }
    }
}
