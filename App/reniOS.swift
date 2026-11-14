import UIKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@_cdecl("renios_library")
func runReniOSLibrary() {
    Session().run()
}

@MainActor
@Observable
final class Session {
    var novels = LibraryStore.list()
    var isImporting = false
    var message: String?
    var hasPlayed = false
    private var pending: Novel?

    static var engine: String {
        Bundle.main.object(forInfoDictionaryKey: "ReniosEngineVersion") as? String ?? ""
    }

    func run() {
        if ProcessInfo.processInfo.arguments.contains("--keyboard-probe") {
            do {
                let demo = try LibraryStore.installDemo()
                try play(demo, probe: true)
            } catch {
                NSLog("Renios probe: %@", error.localizedDescription)
            }
            return
        }

        let window = makeWindow()
        let host = UIHostingController(rootView: LibraryScreen(session: self))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()

        // SDL owns UIApplication. Let UIKit service its normal run loop while
        // its main-function callback waits for the library to select a game.
        while true {
            guard let game = pending else {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
                continue
            }
            pending = nil
            window.isHidden = true
            do {
                try play(game)
            } catch {
                message = error.localizedDescription
            }
            novels = LibraryStore.list()
            window.makeKeyAndVisible()
        }
    }

    func launch(_ novel: Novel) {
        pending = novel
    }

    func add(_ source: URL?) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                if let source {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try LibraryStore.install(source)
                    }.value
                } else {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try LibraryStore.installDemo()
                    }.value
                }
                novels = LibraryStore.list()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func delete(_ novel: Novel) {
        do {
            try LibraryStore.delete(novel)
            novels = LibraryStore.list()
        } catch {
            message = error.localizedDescription
        }
    }

    private func play(_ novel: Novel, probe: Bool = false) throws {
        try FileManager.default.createDirectory(at: novel.saves, withIntermediateDirectories: true)
        try LibraryStore.recordPlay(novel)
        let overlay = probe ? nil : makeGameOverlay()
        defer { overlay?.isHidden = true }
        let result = novel.root.path.withCString { game in
            novel.saves.path.withCString { saves in
                renios_play(game, saves, probe ? 1 : 0)
            }
        }
        hasPlayed = true
        if result != 0 { message = "Ren’Py closed with code \(result)." }
    }

    private func makeWindow() -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return UIWindow(windowScene: scene)
        }
        return UIWindow(frame: UIScreen.main.bounds)
    }

    private func makeGameOverlay() -> UIWindow {
        let overlay: TouchThroughWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            overlay = TouchThroughWindow(windowScene: scene)
        } else {
            overlay = TouchThroughWindow(frame: UIScreen.main.bounds)
        }
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        let container = UIViewController()
        container.view.backgroundColor = .clear
        let close = UIButton(type: .system)
        var style = UIButton.Configuration.glass()
        style.image = UIImage(systemName: "xmark")
        close.configuration = style
        close.tintColor = .white
        close.accessibilityLabel = "Close Game"
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { _ in renios_request_quit() }, for: .touchUpInside)
        container.view.addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            close.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44)
        ])
        overlay.rootViewController = container
        overlay.touchTarget = close
        overlay.isHidden = false
        return overlay
    }
}

private final class TouchThroughWindow: UIWindow {
    weak var touchTarget: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = touchTarget,
              target.bounds.contains(convert(point, to: target)) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private let ink = Color(red: 0.065, green: 0.075, blue: 0.1)
private let cream = Color(red: 0.96, green: 0.92, blue: 0.84)
private let amber = Color(red: 0.91, green: 0.69, blue: 0.45)

private struct LibraryScreen: View {
    var session: Session
    @State private var importing = false
    @State private var filter = ""
    @State private var selected: Novel?

    private var visibleNovels: [Novel] {
        filter.isEmpty ? session.novels : session.novels.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    masthead
                    if session.novels.isEmpty {
                        emptyLibrary
                    } else {
                        if let featured = visibleNovels.first {
                            Button { selected = featured } label: { FeatureCard(novel: featured) }
                                .buttonStyle(.plain)
                        }
                        if visibleNovels.isEmpty {
                            ContentUnavailableView.search(text: filter)
                        } else {
                            shelf
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            .background(ink.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("reniOS").font(.system(.headline, design: .monospaced)).foregroundStyle(amber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import", systemImage: "plus") { importing = true }
                        .labelStyle(.iconOnly)
                        .disabled(session.isImporting)
                        .accessibilityIdentifier("importGame")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder, UTType(filenameExtension: "apk") ?? .data]) {
                switch $0 {
                case .success(let url): session.add(url)
                case .failure(let error): session.message = error.localizedDescription
                }
            }
            .sheet(item: $selected) { novel in
                NovelSheet(novel: novel, session: session)
            }
            .alert("reniOS", isPresented: Binding(
                get: { session.message != nil },
                set: { if !$0 { session.message = nil } }
            )) {
                Button("OK", role: .cancel) { session.message = nil }
            } message: {
                Text(session.message ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .tint(amber)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Library")
                .font(.system(size: 55, weight: .medium, design: .serif))
                .tracking(-2.5)
                .foregroundStyle(cream)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Text(session.novels.count == 1 ? "1 story" : "\(session.novels.count) stories")
                Spacer()
                Text("Ren’Py \(Session.engine)").fontDesign(.monospaced)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 19) {
            ZStack(alignment: .bottomLeading) {
                CoverArt(url: nil, tint: amber)
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "book.closed").font(.system(size: 30, weight: .light))
                    Text("A shelf of\nyour own.")
                        .font(.system(size: 38, weight: .medium, design: .serif))
                }
                .foregroundStyle(cream)
                .padding(23)
            }
            .frame(height: 264)
            .clipShape(.rect(cornerRadius: 28))

            ViewThatFits {
                HStack(spacing: 12) { importButton; demoButton }
                VStack(alignment: .leading, spacing: 12) { importButton; demoButton }
            }
        }
    }

    private var importButton: some View {
        Button("Import Game", systemImage: "plus") { importing = true }
            .buttonStyle(.glassProminent)
            .disabled(session.isImporting)
    }

    private var demoButton: some View {
        Button("Add Sample", systemImage: "sparkle") { session.add(nil) }
            .buttonStyle(.glass)
            .disabled(session.isImporting)
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("All Stories").font(.title3.weight(.semibold)).foregroundStyle(cream)
                Spacer()
                if session.isImporting { ProgressView().accessibilityLabel("Importing") }
            }
            TextField("Search", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("searchStories")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 15)], alignment: .leading, spacing: 20) {
                ForEach(visibleNovels) { novel in
                    Button { selected = novel } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            CoverArt(url: novel.cover, tint: amber)
                                .frame(height: 104)
                                .clipShape(.rect(cornerRadius: 15))
                            Text(novel.title)
                                .font(.headline)
                                .foregroundStyle(cream)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct FeatureCard: View {
    let novel: Novel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverArt(url: novel.cover, tint: amber)
            LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(novel.lastPlayed == nil ? "Recently Added" : "Last Played")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(amber)
                    Text(novel.title)
                        .font(.system(.largeTitle, design: .serif).weight(.medium))
                        .foregroundStyle(cream)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.title3.weight(.medium))
                    .foregroundStyle(cream)
                    .padding(13)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .padding(22)
        }
        .frame(height: 235)
        .clipShape(.rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }
}

private struct CoverArt: View {
    let url: URL?
    let tint: Color
    @State private var cover: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.23, green: 0.18, blue: 0.24), ink],
                                       startPoint: .topTrailing, endPoint: .bottomLeading)
                        Canvas { context, size in
                            let side = max(size.width, size.height)
                            for index in 0..<9 {
                                let span = side * (0.30 + CGFloat(index) * 0.12)
                                let rect = CGRect(x: size.width * 0.73 - span / 2,
                                                  y: size.height * 0.28 - span / 2,
                                                  width: span, height: span)
                                context.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.28 - Double(index) * 0.022)),
                                               lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: url) {
            cover = nil
            guard let url else { return }
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 900
                      ] as CFDictionary) else { return nil as CGImage? }
                return thumbnail
            }.value
            if let image, !Task.isCancelled { cover = UIImage(cgImage: image) }
        }
        .accessibilityHidden(true)
    }
}

private struct NovelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let novel: Novel
    let session: Session
    @State private var backup: URL?
    @State private var confirmingRemoval = false
    @State private var backupError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CoverArt(url: novel.cover, tint: amber)
                        .frame(height: 205)
                        .clipShape(.rect(cornerRadius: 24))
                    Text(novel.title)
                        .font(.system(.largeTitle, design: .serif))
                        .foregroundStyle(cream)
                    Text("Ren’Py \(Session.engine)")
                        .font(.footnote.monospaced()).foregroundStyle(.secondary)
                    if session.hasPlayed {
                        Label("Reopen reniOS to play again.", systemImage: "arrow.clockwise")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Play", systemImage: "play.fill") {
                            dismiss()
                            session.launch(novel)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if let backup {
                        ShareLink(item: backup) { Label("Share Saves", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.glass)
                    } else {
                        Button("Export Saves", systemImage: "archivebox") {
                            do { backup = try LibraryStore.backup(novel) }
                            catch { backupError = error.localizedDescription }
                        }
                        .buttonStyle(.glass)
                    }
                    if let backupError { Text(backupError).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ink.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove Game", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                        .labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("Remove \(novel.title)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove Game", role: .destructive) { session.delete(novel); dismiss() }
            } message: {
                Text("Your saves stay in Files.")
            }
        }
        .tint(amber)
    }
}
