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
    private(set) var importReview: LibraryStore.ImportPlan?
    var updatedGameWithMods: Novel?
    private var pending: Novel?
    @ObservationIgnored private var coverLookups = Set<UUID>()

    static var engine: String {
        Bundle.main.object(forInfoDictionaryKey: "ReniosEngineVersion") as? String ?? ""
    }

    static var installedEngines: [String] {
        Bundle.main.object(forInfoDictionaryKey: "ReniosInstalledEngines") as? [String] ?? [engine]
    }

    static func automaticEngine(for novel: Novel) -> String? {
        EngineVersion.choose(for: novel.detectedEngine, from: installedEngines, default: engine)
    }

    static func engine(for novel: Novel) -> String? {
        if let override = novel.engineOverride, installedEngines.contains(override) { return override }
        return automaticEngine(for: novel)
    }

    func run() {
        LibraryStore.discardAbandonedImports()
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--playback-probe") {
            let engines = ProcessInfo.processInfo.arguments.dropFirst(index + 1)
            do {
                let result = ["importsAndSaves": try LibraryStore.checkImportsAndSaves()]
                let output = URL.cachesDirectory.appending(path: "renios-library.json")
                try JSONEncoder().encode(result).write(to: output, options: .atomic)
                guard let base = Bundle.main.url(forResource: "base", withExtension: nil) else {
                    throw ImportFailure.missingDemo
                }
                let sample = base.appending(path: "Demo")
                for (number, version) in engines.enumerated() {
                    var game = try LibraryStore.install(sample, title: "Playback Probe \(number + 1)", checkDuplicates: false)
                    game.engineOverride = version
                    if try play(game, probe: true) != 0 { return }
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                }
            } catch {
                NSLog("reniOS playback probe: %@", error.localizedDescription)
            }
            return
        }
        #endif

        var previewTab: GameTab?
        var previewLandscape = false
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--launcher-preview") {
            let arguments = ProcessInfo.processInfo.arguments.dropFirst(index + 1)
            previewLandscape = arguments.contains("landscape")
            previewTab = arguments.compactMap(GameTab.init(rawValue:)).first
            if novels.isEmpty {
                do {
                    _ = try LibraryStore.installDemo()
                    novels = LibraryStore.list()
                } catch {
                    NSLog("reniOS launcher preview: %@", error.localizedDescription)
                }
            }
        }
        #endif

        let window = makeWindow()
        let screen = LibraryScreen(session: self, previewTab: previewTab)
        let host = UIHostingController(rootView: screen)
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        if previewLandscape, let scene = window.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                NSLog("reniOS launcher preview: %@", error.localizedDescription)
            }
        }

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
                _ = try play(game, probe: false)
            } catch {
                message = error.localizedDescription
            }
            novels = LibraryStore.list()
            window.makeKeyAndVisible()
            findCoverIfVerified(for: game.id)
        }
    }

    func launch(_ novel: Novel) {
        guard !isImporting else { return }
        pending = novel
    }

    func update(_ novel: Novel) {
        do {
            try LibraryStore.update(novel)
            novels = LibraryStore.list()
        } catch {
            message = error.localizedDescription
        }
    }

    func restore(_ archive: URL, to novel: Novel, replacing: Bool) async throws -> Int {
        guard !isImporting else { return 0 }
        isImporting = true
        defer { isImporting = false }
        return try await Task.detached(priority: .userInitiated) {
            try LibraryStore.restore(archive, to: novel, replacing: replacing)
        }.value
    }

    func add(_ source: URL?) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            do {
                if let source {
                    let plan = try await Task.detached(priority: .userInitiated) {
                        try LibraryStore.prepareImport(source)
                    }.value
                    if plan.needsReview {
                        importReview = plan
                        return
                    }
                    await completeImport(plan, choice: plan.exactSaves.map { .attach($0.id) } ?? .fresh)
                } else {
                    let installed = try await Task.detached(priority: .userInitiated) {
                        try LibraryStore.installDemo()
                    }.value
                    novels = LibraryStore.list()
                    isImporting = false
                    findCoverIfVerified(for: installed.id)
                }
            } catch {
                isImporting = false
                message = error.localizedDescription
            }
        }
    }

    func chooseImport(_ choice: LibraryStore.ImportChoice) {
        guard let plan = importReview else { return }
        importReview = nil
        Task { await completeImport(plan, choice: choice) }
    }

    func cancelImportReview() {
        guard let plan = importReview else { return }
        importReview = nil
        Task {
            await Task.detached(priority: .utility) { LibraryStore.discardImport(plan) }.value
            isImporting = false
        }
    }

    private func completeImport(_ plan: LibraryStore.ImportPlan, choice: LibraryStore.ImportChoice) async {
        do {
            let installed = try await Task.detached(priority: .userInitiated) {
                defer { LibraryStore.discardImport(plan) }
                return try LibraryStore.finishImport(plan, choice: choice)
            }.value
            novels = LibraryStore.list()
            isImporting = false
            if case .update = choice, !LibraryStore.installedMods(for: installed).isEmpty {
                updatedGameWithMods = installed
            }
            coverLookups.remove(installed.id)
            findCoverIfVerified(for: installed.id)
        } catch {
            isImporting = false
            message = error.localizedDescription
        }
    }

    private func findCoverIfVerified(for id: Novel.ID) {
        guard let game = novels.first(where: { $0.id == id }),
              let developer = GameMetadata.displayTitle(game.developer), game.cover == nil,
              game.automaticCoverDisabled != true, coverLookups.insert(id).inserted else { return }
        Task { [weak self] in
            guard let result = try? await CoverLookup.match(title: game.title, developer: developer),
                  let image = result.image, let data = try? await CoverLookup.download(image.url),
                  let self, !isImporting, let current = novels.first(where: { $0.id == id }),
                  current.title == game.title, current.developer == game.developer,
                  current.cover == nil, current.automaticCoverDisabled != true else { return }
            try? setCover(data, for: current)
        }
    }

    func setCover(_ data: Data?, for novel: Novel) throws {
        let current = novels.first { $0.id == novel.id } ?? novel
        try LibraryStore.setCover(data, for: current)
        novels = LibraryStore.list()
    }

    func rename(_ novel: Novel, to name: String) {
        do { try LibraryStore.rename(novel, to: name) }
        catch { message = error.localizedDescription }
        novels = LibraryStore.list()
    }

    func delete(_ novel: Novel, keepingSaves: Bool) {
        do {
            try LibraryStore.delete(novel, keepingSaves: keepingSaves)
            novels = LibraryStore.list()
        } catch {
            message = error.localizedDescription
        }
    }

    private func play(_ novel: Novel, probe: Bool) throws -> Int32 {
        guard let version = Self.engine(for: novel) else {
            message = "This game needs a different Ren’Py engine."
            return -1
        }
        try FileManager.default.createDirectory(at: novel.saves, withIntermediateDirectories: true)
        try LibraryStore.recordPlay(novel)
        let overlay = probe ? nil : makeGameOverlay()
        defer { overlay?.isHidden = true }
        let result = novel.root.path.withCString { game in
            novel.saves.path.withCString { saves in
                version.withCString { engine in
                    (novel.orientation?.sdlHint ?? "").withCString { hint in
                        renios_play(game, saves, engine, hint, probe ? 1 : 0)
                    }
                }
            }
        }
        if result != 0 { message = "Ren’Py closed with code \(result)." }
        return result
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
        let controls = PlaybackControlsController()
        overlay.rootViewController = controls
        overlay.touchTargets = [controls.handle, controls.bar]
        overlay.isHidden = false
        return overlay
    }
}

private final class TouchThroughWindow: UIWindow {
    var touchTargets: [UIView] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard touchTargets.contains(where: { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.contains(convert(point, to: $0)) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
private final class PlaybackControlsController: UIViewController {
    let handle = UIButton(type: .system)
    let bar = UIStackView()
    private var hideTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        handle.configuration = configuration("ellipsis", tint: .white)
        handle.accessibilityLabel = "Show Game Controls"
        handle.addAction(UIAction { [weak self] _ in self?.setExpanded(true) }, for: .touchUpInside)
        handle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handle)

        bar.axis = .horizontal
        bar.spacing = 4
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addArrangedSubview(button("Close Game", "xmark") { renios_request_quit() })
        bar.addArrangedSubview(button("Skip", "forward.end") { renios_playback_key(43, 9) })
        bar.addArrangedSubview(button("Previous", "backward.end") { renios_playback_key(75, 1 << 30 | 75) })
        bar.addArrangedSubview(button("Game Settings", "gearshape") { renios_playback_key(41, 27) })
        bar.addArrangedSubview(button("Show or Hide Keyboard", "keyboard") { renios_toggle_keyboard() })
        bar.addArrangedSubview(button("Hide Game Controls", "chevron.right") {})
        view.addSubview(bar)
        bar.isHidden = true

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            handle.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            handle.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            handle.widthAnchor.constraint(equalToConstant: 44),
            handle.heightAnchor.constraint(equalToConstant: 44),
            bar.trailingAnchor.constraint(equalTo: handle.trailingAnchor),
            bar.topAnchor.constraint(equalTo: handle.topAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 8)
        ])
    }

    private func configuration(_ symbol: String, tint: UIColor) -> UIButton.Configuration {
        var style = UIButton.Configuration.glass()
        style.image = UIImage(systemName: symbol)
        style.baseForegroundColor = tint
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        return style
    }

    private func button(_ title: String, _ symbol: String, action: @escaping @MainActor () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = configuration(symbol, tint: .white)
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in
            self?.setExpanded(false)
            action()
        }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func setExpanded(_ expanded: Bool) {
        hideTask?.cancel()
        handle.isHidden = expanded
        bar.isHidden = !expanded
        if expanded {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }
}

let ink = Color(red: 0.045, green: 0.053, blue: 0.075)
let cream = Color(red: 0.96, green: 0.94, blue: 0.89)
let amber = Color(red: 0.96, green: 0.73, blue: 0.48)
let panel = Color(red: 0.085, green: 0.095, blue: 0.13)

private struct LibraryScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    var session: Session
    var previewTab: GameTab?
    @State private var importing = false
    @State private var filter = ""
    @State private var selected: Novel?
    @State private var selectedTab: GameTab = .overview
    @State private var showingImportReview = false
    @State private var gameToLaunch: Novel?
    @State private var highlightedID: Novel.ID?
    @FocusState private var searching: Bool
    @FocusState private var focusedGame: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: Session, previewTab: GameTab? = nil) {
        self.session = session
        self.previewTab = previewTab
        _selected = State(initialValue: previewTab == nil ? nil : session.novels.first)
        _selectedTab = State(initialValue: previewTab ?? .overview)
    }

    private var visibleNovels: [Novel] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? session.novels : session.novels.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 610 && geometry.size.width > geometry.size.height && !dynamicType.isAccessibilitySize
            let games = visibleNovels

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, wide ? 9 : 13)
                if let feature = games.first(where: { $0.id == highlightedID }) ?? games.first {
                    if wide && searching {
                        landscapeSearchResults(games)
                    } else if wide {
                        landscape(feature: feature, games: games)
                    } else {
                        portrait(feature: feature, games: games)
                    }
                } else if session.novels.isEmpty {
                    emptyLibrary
                } else {
                    ContentUnavailableView.search(text: filter)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: 1320)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            searchDock
                .padding(.top, 7)
                .padding(.bottom, 4)
                .background(ink)
        }
        .background(ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(amber)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder, UTType(filenameExtension: "apk") ?? .data]) {
            switch $0 {
            case .success(let url): session.add(url)
            case .failure(let error): session.message = error.localizedDescription
            }
        }
        .sheet(item: $selected, onDismiss: launchSelectedGame) { novel in
            NovelSheet(novel: novel, session: session, initialTab: selectedTab) { game in
                gameToLaunch = game
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.none)
        }
        .sheet(item: Binding(get: { session.importReview },
                             set: { if $0 == nil { session.cancelImportReview() } }),
               onDismiss: { showingImportReview = false }) { plan in
            ImportReviewSheet(plan: plan, choose: session.chooseImport, cancel: session.cancelImportReview)
                .onAppear { showingImportReview = true }
        }
        .alert("Mods Disabled", isPresented: Binding(
            get: { !showingImportReview && session.updatedGameWithMods != nil },
            set: { if !$0 { session.updatedGameWithMods = nil } }
        ), presenting: session.updatedGameWithMods) { game in
            Button("Open Mods") { showDetails(game, tab: .mods) }
        } message: { game in
            Text("\(game.title) was updated. Your mods are still installed. Re-enable the ones you want in Mods.")
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(amber)
                .frame(width: 28, height: 28)
                .background(amber.opacity(0.12), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            Text("reniOS")
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(cream)
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 15)
                .accessibilityHidden(true)
            Text("Library")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if session.isImporting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Importing")
            }
            Menu {
                Button("Import Game", systemImage: "folder") {
                    searching = false
                    importing = true
                }
                Button("Add Sample", systemImage: "sparkle") { session.add(nil) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.075), in: .circle)
            }
            .accessibilityLabel("Add to Library")
            .accessibilityIdentifier("importGame")
            .disabled(session.isImporting)
        }
    }

    private var searchDock: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(amber)
                .accessibilityHidden(true)
            TextField("Search games", text: $filter)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searching)
                .onSubmit { searching = false }
                .accessibilityIdentifier("searchStories")
            if !filter.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { filter = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 44)
            }
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: 450, minHeight: 46)
        .background(.white.opacity(0.07), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
        .padding(.horizontal, 20)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity)
    }

    private func landscape(feature: Novel, games: [Novel]) -> some View {
        GeometryReader { geometry in
            let tileSize = min(118, max(64, geometry.size.height * 0.32))
            ZStack(alignment: .topLeading) {
                CoverArt(url: feature.cover, tint: amber)
                    .id(feature.id)
                    .transition(.opacity)
                LinearGradient(colors: [ink, ink.opacity(0.87), ink.opacity(0.10)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [ink.opacity(0.48), .clear, ink.opacity(0.84)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(games) { game in
                                    consoleTile(game, selected: feature.id == game.id, size: tileSize)
                                        .id(game.id)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: tileSize + 12)
                        .onChange(of: focusedGame) { _, game in
                            guard let game else { return }
                            highlightedID = game
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                proxy.scrollTo(game, anchor: .center)
                            }
                        }
                    }
                    Spacer(minLength: 1)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(feature.title)
                            .font(.system(size: min(50, max(25, geometry.size.height * 0.15)),
                                          weight: .semibold, design: .serif))
                            .lineLimit(2)
                            .foregroundStyle(cream)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 10) {
                            Button("Play", systemImage: "play.fill") { session.launch(feature) }
                                .buttonStyle(.glassProminent)
                                .disabled(session.isImporting || Session.engine(for: feature) == nil)
                            Button("Details", systemImage: "ellipsis") { showDetails(feature) }
                                .buttonStyle(.glass)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: feature.id)
            .clipShape(.rect(cornerRadius: 21))
            .overlay { RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false) }
        }
        .padding(.horizontal, 20)
    }

    private func consoleTile(_ game: Novel, selected: Bool, size: CGFloat) -> some View {
        Button {
            highlightedID = game.id
        } label: {
            CoverArt(url: game.cover, tint: amber)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomLeading) {
                    if game.cover == nil {
                        Text(game.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(cream)
                            .padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? amber : .white.opacity(0.18), lineWidth: selected ? 2 : 1)
                }
                .opacity(selected ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .focused($focusedGame, equals: game.id)
        .accessibilityLabel(game.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func landscapeSearchResults(_ games: [Novel]) -> some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(games) { game in
                    Button { showDetails(game) } label: { gameRow(game, highlighted: false) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func portrait(feature: Novel, games: [Novel]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                featureCard(feature, compact: false)
                    .frame(minHeight: 248)
                HStack {
                    Text("Games").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(games.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                    ForEach(games) { game in
                        Button { showDetails(game) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CoverArt(url: game.cover, tint: amber)
                                    .aspectRatio(1.52, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 12))
                                Text(game.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2, reservesSpace: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func gameRow(_ game: Novel, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            CoverArt(url: game.cover, tint: amber)
                .frame(width: 52, height: 37)
                .clipShape(.rect(cornerRadius: 6))
            Text(game.title)
                .font(.subheadline.weight(highlighted ? .semibold : .medium))
                .lineLimit(2)
            Spacer(minLength: 2)
            if highlighted {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(amber)
                    .accessibilityHidden(true)
            }
        }
        .padding(6)
        .frame(minHeight: 47)
        .contentShape(.rect)
        .background(highlighted ? amber.opacity(0.15) : .clear, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(highlighted ? amber.opacity(0.35) : .clear)
                .allowsHitTesting(false)
        }
    }

    private func featureCard(_ game: Novel, compact: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverArt(url: game.cover, tint: amber)
            LinearGradient(stops: [.init(color: .clear, location: 0.15),
                                   .init(color: ink.opacity(0.52), location: 0.49),
                                   .init(color: ink.opacity(0.98), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                if let version = Session.engine(for: game) {
                    Label("Ren’Py \(version)", systemImage: "cpu")
                        .font(.caption.monospaced())
                        .foregroundStyle(amber)
                }
                Text(game.title)
                    .font(.system(compact ? .largeTitle : .title, design: .serif).weight(.semibold))
                    .foregroundStyle(cream)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Button("Play", systemImage: "play.fill") {
                        searching = false
                        session.launch(game)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(session.isImporting || Session.engine(for: game) == nil)
                    Button("Details", systemImage: "info.circle") { showDetails(game) }
                        .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(compact ? 17 : 20)
        }
        .clipShape(.rect(cornerRadius: 19))
        .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.16)).allowsHitTesting(false) }
    }

    private var emptyLibrary: some View {
        ZStack {
            CoverArt(url: nil, tint: amber)
            VStack(spacing: 12) {
                Image(systemName: "books.vertical").font(.title2).foregroundStyle(amber)
                Text("Your library is empty")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ViewThatFits {
                    HStack(spacing: 8) { emptyActions }
                    VStack(spacing: 8) { emptyActions }
                }
            }
            .padding(20)
        }
        .clipShape(.rect(cornerRadius: 19))
        .padding(.horizontal, 20)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyActions: some View {
        Button("Import Game", systemImage: "plus") {
            searching = false
            importing = true
        }
        .buttonStyle(.glassProminent)
        .disabled(session.isImporting)
        Button("Add Sample", systemImage: "sparkle") { session.add(nil) }
            .buttonStyle(.glass)
            .disabled(session.isImporting)
    }

    private func showDetails(_ game: Novel, tab: GameTab = .overview) {
        searching = false
        selectedTab = tab
        selected = game
    }

    private func launchSelectedGame() {
        guard let game = gameToLaunch else { return }
        gameToLaunch = nil
        session.launch(game)
    }
}

private struct ImportReviewSheet: View {
    let plan: LibraryStore.ImportPlan
    let choose: (LibraryStore.ImportChoice) -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(plan.incoming.title).font(.headline)
                    Button(plan.matchingGames.isEmpty ? "Start Fresh" : "Install Separately",
                           systemImage: "plus.square.on.square") { choose(.fresh) }
                } footer: {
                    Text("Creates a new game and save folder.")
                }

                if !plan.matchingGames.isEmpty {
                    Section {
                        ForEach(plan.matchingGames) { game in
                            Button {
                                choose(.update(game.id))
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Update \(game.title)")
                                    Text(game.root.lastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Matching Games")
                    } footer: {
                        Text("Keeps your saves and disables installed mods until you re-enable them.")
                    }
                }
                if !plan.retainedSaves.isEmpty {
                    Section("Retained Saves") {
                        ForEach(plan.retainedSaves) { save in
                            Button {
                                choose(.attach(save.id))
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Use Saves for \(save.title)")
                                    Text(save.folder.lastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
        .tint(amber)
        .presentationDragIndicator(.visible)
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

private enum GameTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case saves = "Saves"
    case mods = "Mods"
    case export = "Export"
    case restore = "Restore"

    var id: Self { self }

    var title: String { self == .overview ? "Game" : rawValue }

    var icon: String {
        switch self {
        case .overview: "play.rectangle"
        case .saves: "square.stack"
        case .mods: "puzzlepiece.extension"
        case .export: "square.and.arrow.up"
        case .restore: "arrow.down.to.line"
        }
    }
}

private struct NovelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    let game: Novel
    let launch: (Novel) -> Void
    @Bindable var session: Session
    @State private var tab: GameTab = .overview
    @State private var choosingCover = false
    @State private var findingCover = false
    @State private var choosingEngine = false
    @State private var confirmingRemoval = false
    @State private var renaming = false
    @State private var newTitle = ""

    init(novel: Novel, session: Session, initialTab: GameTab, launch: @escaping (Novel) -> Void) {
        game = novel
        self.session = session
        self.launch = launch
        _tab = State(initialValue: initialTab)
    }

    private var novel: Novel {
        session.novels.first { $0.id == game.id } ?? game
    }

    private var orientation: Binding<GameOrientation> {
        Binding(get: { novel.orientation ?? .automatic }, set: { value in
            var updated = novel
            updated.orientation = value
            session.update(updated)
        })
    }

    private var engine: Binding<String?> {
        Binding(get: { novel.engineOverride }, set: { value in
            var updated = novel
            updated.engineOverride = value
            session.update(updated)
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 560 && geometry.size.width > geometry.size.height && !dynamicType.isAccessibilitySize
            VStack(spacing: 10) {
                header
                if wide {
                    HStack(spacing: 14) {
                        tabRail
                        if tab == .overview {
                            ScrollView {
                                HStack(alignment: .top, spacing: 16) {
                                    artwork.frame(height: 195)
                                    VStack(alignment: .leading, spacing: 12) {
                                        playButton
                                        settings
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 9) {
                                    artwork.frame(height: 125)
                                    playButton
                                }
                            }
                            .frame(width: min(geometry.size.width * 0.27, 275))
                            managementPage
                        }
                    }
                } else {
                    if tab == .overview {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 13) {
                                artwork.frame(height: 195)
                                playButton
                                settings
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        managementPage
                    }
                    tabBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 17)
            .padding(.bottom, 6)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(ink.ignoresSafeArea())
        .tint(amber)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(session.isImporting)
        .fileImporter(isPresented: $choosingCover, allowedContentTypes: [.image]) { result in
            do {
                let file = try result.get()
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                try session.setCover(CoverLookup.jpeg(from: file), for: novel)
            } catch { session.message = error.localizedDescription }
        }
        .sheet(isPresented: $findingCover) {
            CoverFinder(title: novel.title, developer: novel.developer) { data in
                try session.setCover(data, for: novel)
            }
            .tint(amber)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $choosingEngine) {
            EnginePicker(selection: engine, automaticVersion: Session.automaticEngine(for: novel))
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
                .preferredColorScheme(.dark)
                .tint(amber)
        }
        .confirmationDialog("Remove \(novel.title)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Game, Keep Saves") { session.delete(novel, keepingSaves: true); dismiss() }
            Button("Remove Game and Saves", role: .destructive) { session.delete(novel, keepingSaves: false); dismiss() }
        }
        .alert("Rename Game", isPresented: $renaming) {
            TextField("Game title", text: $newTitle)
            Button("Save") { session.rename(novel, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("reniOS", isPresented: Binding(
            get: { session.message != nil }, set: { if !$0 { session.message = nil } }
        )) {
            Button("OK") { session.message = nil }
        } message: { Text(session.message ?? "") }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Button("Close Game Details", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.07), in: .circle)
                .disabled(session.isImporting)
            Text(novel.title)
                .font(.system(.headline, design: .serif).weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(cream)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newTitle = novel.title
                    renaming = true
                }
                Button("Choose Cover", systemImage: "photo") { choosingCover = true }
                Button("Find Cover", systemImage: "magnifyingglass") { findingCover = true }
                if novel.coverOverride != nil {
                    Button("Reset Cover", systemImage: "arrow.uturn.backward") {
                        do { try session.setCover(nil, for: novel) }
                        catch { session.message = error.localizedDescription }
                    }
                }
                ShareLink(item: LibraryStore.diagnostics(for: novel, engine: Session.engine(for: novel))) {
                    Label("Share Diagnostics", systemImage: "doc.text")
                }
                Button("Remove Game", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.07), in: .circle)
            }
            .accessibilityLabel("Game Options")
            .disabled(session.isImporting)
        }
    }

    private var tabBar: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(GameTab.allCases) { tabButton($0).fixedSize(horizontal: true, vertical: false) }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                HStack(spacing: 4) {
                    ForEach(GameTab.allCases) { tabButton($0) }
                }
            }
        }
        .padding(4)
        .background(panel, in: .rect(cornerRadius: 18))
        .disabled(session.isImporting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Game tabs")
    }

    private var tabRail: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(GameTab.allCases) { tabButton($0) }
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
        .frame(width: 80)
        .background(panel, in: .rect(cornerRadius: 18))
        .disabled(session.isImporting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Game tabs")
    }

    private func tabButton(_ destination: GameTab) -> some View {
        let selected = destination == tab
        return Button {
            tab = destination
        } label: {
            VStack(spacing: 4) {
                Image(systemName: destination.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(destination.title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? amber : .secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(selected ? amber.opacity(0.13) : .clear, in: .rect(cornerRadius: 13))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("gameTab\(destination.rawValue)")
    }

    private var artwork: some View {
        ZStack {
            CoverArt(url: novel.cover, tint: amber)
            LinearGradient(colors: [.clear, ink.opacity(0.34)], startPoint: .top, endPoint: .bottom)
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false) }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var managementPage: some View {
        switch tab {
        case .overview: EmptyView()
        case .saves: SaveManager(novel: novel)
        case .mods: ModManager(novel: novel, working: $session.isImporting)
        case .export: SaveExportTab(novel: novel, working: $session.isImporting)
        case .restore: SaveRestoreTab(novel: novel, session: session)
        }
    }

    private var playButton: some View {
        Button {
            launch(novel)
            dismiss()
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(ink)
                .background(amber, in: .rect(cornerRadius: 15))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(canPlay ? 1 : 0.45)
        .disabled(!canPlay)
    }

    private var canPlay: Bool {
        !session.isImporting && Session.engine(for: novel) != nil
    }

    private var automaticEngine: String {
        Session.automaticEngine(for: novel).map { "Auto · Ren’Py \($0)" } ?? "Auto · Unavailable"
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Game Settings")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Button {
                    choosingEngine = true
                } label: {
                    settingRow("Engine", icon: "cpu",
                               value: novel.engineOverride.map { "Ren’Py \($0)" } ?? automaticEngine)
                }
                .buttonStyle(.plain)
                Divider()
                Menu {
                    Picker("Orientation", selection: orientation) {
                        ForEach(GameOrientation.allCases) { mode in
                            Label(mode.rawValue, systemImage: orientationIcon(mode)).tag(mode)
                        }
                    }
                } label: {
                    settingRow("Orientation", icon: "iphone", value: orientation.wrappedValue.rawValue)
                }
            }
            .padding(.horizontal, 12)
            .background(panel, in: .rect(cornerRadius: 14))
            .disabled(session.isImporting)
        }
    }

    private func settingRow(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 7) {
            Label(title, systemImage: icon).foregroundStyle(cream)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(amber).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(amber)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .frame(minHeight: 46)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func orientationIcon(_ mode: GameOrientation) -> String {
        switch mode {
        case .automatic: "rotate.right"
        case .portrait: "iphone"
        case .landscape: "iphone.landscape"
        }
    }
}

private struct EnginePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    let automaticVersion: String?
    @State private var query = ""

    private var versions: [String] {
        Session.installedEngines.reversed().filter { query.isEmpty || "Ren’Py \($0)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                engineRow("Auto", detail: automaticVersion.map { "Ren’Py \($0)" } ?? "Unavailable", version: nil)
                Section("Installed versions") {
                    ForEach(versions, id: \.self) { version in
                        engineRow("Ren’Py \(version)", detail: nil, version: version)
                    }
                    if versions.isEmpty {
                        Text("No matching versions").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ren’Py Engine")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search versions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func engineRow(_ title: String, detail: String?, version: String?) -> some View {
        Button {
            selection = version
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == version {
                    Image(systemName: "checkmark").foregroundStyle(amber).accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == version ? .isSelected : [])
    }
}
