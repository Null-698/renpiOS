import UIKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@_cdecl("renios_library")
func runReniOSLibrary() {
    UserDefaults.standard.register(defaults: [
        "appearance": "dark", "accentRed": 0.96, "accentGreen": 0.73, "accentBlue": 0.48,
        "insightsEnabled": true, "showRecentGame": true, "showThumbnails": true,
        "libraryList": false, "librarySort": "recent", "controlsLayout": "horizontal",
        "controlsOpacity": 1.0, "widescreen": false
    ])
    Session().run()
}

@MainActor
@Observable
final class Session {
    var novels = LibraryStore.list()
    let activity = PlayActivity()
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
        var previewTab: GameTab?
        var previewLandscape = false
        var previewOpen = false
        var previewName: String?
        var previewInsights: PlayHistory?
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--launcher-preview") {
            let arguments = ProcessInfo.processInfo.arguments.dropFirst(index + 1)
            previewName = arguments.first
            previewOpen = arguments.contains("landscape-open")
            previewLandscape = previewOpen || arguments.contains("landscape") || arguments.contains("landscape-options")
                || arguments.contains(where: { $0.hasPrefix("landscape-return") }) || arguments.contains("landscape-insights")
            previewTab = arguments.compactMap(GameTab.init(rawValue:)).first
            if novels.isEmpty {
                do {
                    _ = try LibraryStore.installDemo()
                    novels = LibraryStore.list()
                } catch {
                    NSLog("reniOS launcher preview: %@", error.localizedDescription)
                }
            }
            if previewLandscape, let base = Bundle.main.url(forResource: "base", withExtension: nil) {
                do {
                    let sample = base.appending(path: "Demo")
                    novels = try ["Afterlight", "Night Crossing", "Quiet Orbit"].map { title in
                        if let game = novels.first(where: { $0.title == title }) { return game }
                        return try LibraryStore.install(sample, title: title, checkDuplicates: false)
                    }
                } catch {
                    NSLog("reniOS carousel preview: %@", error.localizedDescription)
                }
            }
            if arguments.contains("Insights") || arguments.contains("landscape-insights"), let game = novels.first {
                var history = PlayHistory()
                for offset in [0, -1, -2, -5, -6, -7, -8] {
                    let date = Date.now.addingTimeInterval(Double(offset) * 86400)
                    let duration = 2100 + Double(abs(offset)) * 790
                    history.record(game: game, from: date, seconds: duration, sessionLength: duration)
                }
                previewInsights = history
            }
        }
        #endif

        let window = makeWindow()
        let screen = LibraryScreen(session: self, previewTab: previewTab, previewOpen: previewOpen,
                                   previewInsights: previewInsights, previewName: previewName,
                                   previewLandscape: previewLandscape)
        let host = UIHostingController(rootView: screen)
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.overrideUserInterfaceStyle = AppStyle.theme == .dark ? .dark : AppStyle.theme == .light ? .light : .unspecified
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
                _ = try play(game)
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

    private func play(_ novel: Novel) throws -> Int32 {
        guard let version = Self.engine(for: novel) else {
            message = "This game needs a different Ren’Py engine."
            return -1
        }
        try FileManager.default.createDirectory(at: novel.saves, withIntermediateDirectories: true)
        let startedAt = Date.now
        let displayConfiguration = novel.root.appending(path: ".renios-display.json")
        let fillScreen = UserDefaults.standard.bool(forKey: "widescreen")
        try JSONEncoder().encode(["fill": fillScreen]).write(to: displayConfiguration, options: .atomic)
        let overlay = makeGameOverlay()
        activity.begin(novel)
        defer {
            activity.finish()
            overlay.isHidden = true
        }
        let result = novel.root.path.withCString { game in
            novel.saves.path.withCString { saves in
                version.withCString { engine in
                    (novel.orientation?.sdlHint ?? "").withCString { hint in
                        renios_play(game, saves, engine, hint)
                    }
                }
            }
        }
        if result == 0 { try LibraryStore.recordPlay(novel, at: startedAt) }
        else { message = "Ren’Py closed with code \(result)." }
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
            overlay.frame = scene.coordinateSpace.bounds
        } else {
            overlay = TouchThroughWindow(frame: UIScreen.main.bounds)
        }
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        let controls = PlaybackControlsController()
        overlay.rootViewController = controls
        controls.loadViewIfNeeded()
        overlay.touchTargets = [controls.handle, controls.bar] + controls.independentButtons
        overlay.isHidden = false
        return overlay
    }
}

private final class TouchThroughWindow: UIWindow {
    var touchTargets: [UIView] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if rootViewController?.presentedViewController != nil {
            return super.hitTest(point, with: event)
        }
        guard touchTargets.contains(where: { !$0.isHidden && $0.isUserInteractionEnabled && $0.alpha > 0.01 && $0.bounds.contains(convert(point, to: $0)) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
private final class PlaybackControlsController: UIViewController {
    let handle = UIButton(type: .system)
    let bar = UIStackView()
    private(set) var independentButtons: [UIButton] = []
    private let controlsMode = UserDefaults.standard.string(forKey: "controlsLayout") ?? "horizontal"
    private let controlsOpacity = UserDefaults.standard.object(forKey: "controlsOpacity") == nil
        ? 1.0 : min(max(UserDefaults.standard.double(forKey: "controlsOpacity"), 0.25), 1.0)
    private var independentPositions: [Int: CGPoint] = [:]
    private var hideTask: Task<Void, Never>?
    private var expanded = false
    private var dragging = false
    private var dragOrigin = CGPoint.zero
    private var dragPosition: CGPoint?
    private var dock = CGPoint(x: 1, y: 0)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        if let saved = UserDefaults.standard.array(forKey: "playbackControlsPosition") as? [Double],
           saved.count == 2, saved.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            dock = CGPoint(x: saved[0], y: saved[1])
        }

        handle.configuration = configuration("ellipsis")
        handle.accessibilityLabel = "Show Game Controls"
        handle.addAction(UIAction { [weak self] _ in self?.setExpanded(true) }, for: .touchUpInside)
        view.addSubview(handle)

        bar.axis = controlsMode == "vertical" ? .vertical : .horizontal
        bar.spacing = 4
        bar.alignment = .center
        bar.addArrangedSubview(button("Hide Game Controls", "chevron.down") { [weak self] in self?.setExpanded(false) })
        bar.addArrangedSubview(button("Previous", "backward.end.fill") { renios_playback_key(75, 1 << 30 | 75) })
        bar.addArrangedSubview(button("Skip", "forward.end.fill") { renios_playback_key(43, 9) })
        bar.addArrangedSubview(button("Game Settings", "gearshape") { renios_playback_key(41, 27) })
        bar.addArrangedSubview(button("Show or Hide Keyboard", "keyboard") { renios_toggle_keyboard() })
        bar.addArrangedSubview(button("Close Game", "power", tint: .systemOrange) { [weak self] in
            self?.confirmExit()
        })
        if controlsMode == "separate" {
            independentButtons = bar.arrangedSubviews.compactMap { $0 as? UIButton }
            for (index, button) in independentButtons.enumerated() {
                bar.removeArrangedSubview(button)
                button.removeFromSuperview()
                for constraint in button.constraints where constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                    constraint.isActive = false
                }
                button.translatesAutoresizingMaskIntoConstraints = true
                button.tag = index
                let values = UserDefaults.standard.array(forKey: "controlPosition-\(index)") as? [Double]
                if let values, values.count == 2, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                    independentPositions[index] = CGPoint(x: values[0], y: values[1])
                }
                view.addSubview(button)
                button.alpha = 0
                button.isUserInteractionEnabled = false
                button.accessibilityElementsHidden = true
                button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragIndependent(_:))))
            }
        }
        handle.alpha = controlsOpacity
        view.addSubview(bar)
        bar.alpha = 0
        if !UIAccessibility.isReduceMotionEnabled { bar.transform = CGAffineTransform(scaleX: 0.87, y: 0.87) }
        bar.isUserInteractionEnabled = false
        bar.accessibilityElementsHidden = true
        for target in [handle as UIView, bar] {
            target.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionControls()
    }

    private var available: CGRect { view.bounds }

    private func confirmExit() {
        guard presentedViewController == nil else { return }
        hideTask?.cancel()
        let alert = UIAlertController(title: "Close Game?", message: "Return to your library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel) { [weak self] _ in
            self?.scheduleCollapse()
        })
        alert.addAction(UIAlertAction(title: "Close Game", style: .destructive) { [weak self] _ in
            self?.setExpanded(false)
            renios_request_quit()
        })
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func positionControls() {
        let bounds = available
        let count = max(bar.arrangedSubviews.count, 1)
        let span = CGFloat(count) * 44 + CGFloat(count - 1) * bar.spacing
        let barWidth: CGFloat = controlsMode == "vertical" ? 44 : span
        let barHeight: CGFloat = controlsMode == "vertical" ? span : 44
        // Both layouts share a proportional position within their usable ranges.
        func frame(width: CGFloat, height: CGFloat) -> CGRect {
            let horizontal = max(0, bounds.width - width)
            let vertical = max(0, bounds.height - height)
            let x = dragPosition.map { min(max($0.x - bounds.minX - width / 2, 0), horizontal) }
                ?? horizontal * dock.x
            let y = dragPosition.map { min(max($0.y - bounds.minY - height / 2, 0), vertical) }
                ?? vertical * dock.y
            return CGRect(x: bounds.minX + x, y: bounds.minY + y, width: width, height: height)
        }
        handle.bounds.size = CGSize(width: 44, height: 44)
        bar.bounds.size = CGSize(width: barWidth, height: barHeight)
        let handleFrame = frame(width: 44, height: 44)
        let barFrame = frame(width: barWidth, height: barHeight)
        handle.center = .init(x: handleFrame.midX, y: handleFrame.midY)
        bar.center = .init(x: barFrame.midX, y: barFrame.midY)
        for button in independentButtons {
            let point = independentPositions[button.tag]
                ?? CGPoint(x: 1, y: CGFloat(button.tag + 1) / CGFloat(independentButtons.count + 1))
            button.frame = CGRect(x: bounds.minX + max(bounds.width - 44, 0) * point.x,
                                  y: bounds.minY + max(bounds.height - 44, 0) * point.y, width: 44, height: 44)
        }
    }

    @objc private func dragIndependent(_ recognizer: UIPanGestureRecognizer) {
        guard let target = recognizer.view else { return }
        let bounds = available
        switch recognizer.state {
        case .began:
            hideTask?.cancel()
            dragging = true
            dragOrigin = target.center
        case .changed:
            let translation = recognizer.translation(in: view)
            let x = min(max(dragOrigin.x + translation.x - 22, bounds.minX), max(bounds.maxX - 44, bounds.minX))
            let y = min(max(dragOrigin.y + translation.y - 22, bounds.minY), max(bounds.maxY - 44, bounds.minY))
            let point = CGPoint(x: (x - bounds.minX) / max(bounds.width - 44, 1),
                                y: (y - bounds.minY) / max(bounds.height - 44, 1))
            independentPositions[target.tag] = point
            target.frame.origin = CGPoint(x: x, y: y)
        case .ended, .cancelled, .failed:
            if let point = independentPositions[target.tag] {
                UserDefaults.standard.set([Double(point.x), Double(point.y)], forKey: "controlPosition-\(target.tag)")
            }
            dragging = false
            scheduleCollapse()
        default: break
        }
    }

    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        guard let target = recognizer.view else { return }
        switch recognizer.state {
        case .began:
            hideTask?.cancel()
            dragging = true
            dragOrigin = target.center
        case .changed:
            let translation = recognizer.translation(in: view)
            dragPosition = CGPoint(x: dragOrigin.x + translation.x, y: dragOrigin.y + translation.y)
            positionControls()
        case .ended, .cancelled, .failed:
            let bounds = available
            let horizontal = bounds.width - target.bounds.width
            let vertical = bounds.height - target.bounds.height
            if horizontal > 0 { dock.x = min(max((target.frame.minX - bounds.minX) / horizontal, 0), 1) }
            if vertical > 0 { dock.y = min(max((target.frame.minY - bounds.minY) / vertical, 0), 1) }
            UserDefaults.standard.set([Double(dock.x), Double(dock.y)], forKey: "playbackControlsPosition")
            dragPosition = nil
            dragging = false
            positionControls()
            scheduleCollapse()
        default: break
        }
    }

    private func configuration(_ symbol: String, tint: UIColor = .white) -> UIButton.Configuration {
        var style = UIButton.Configuration.glass()
        style.image = UIImage(systemName: symbol)
        style.baseForegroundColor = tint
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        return style
    }

    private func button(_ title: String, _ symbol: String, tint: UIColor = .white,
                        action: @escaping @MainActor () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = configuration(symbol, tint: tint)
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in
            action()
            self?.scheduleCollapse()
        }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func setExpanded(_ showing: Bool) {
        guard showing != expanded else { return }
        expanded = showing
        handle.isUserInteractionEnabled = !showing
        handle.accessibilityElementsHidden = showing
        bar.isUserInteractionEnabled = showing && controlsMode != "separate"
        bar.accessibilityElementsHidden = !showing || controlsMode == "separate"
        for button in independentButtons {
            button.isUserInteractionEnabled = showing
            button.accessibilityElementsHidden = !showing
        }
        let reduced = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduced ? 0.12 : 0.28, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
            self.handle.alpha = showing ? 0 : self.controlsOpacity
            self.bar.alpha = showing && self.controlsMode != "separate" ? self.controlsOpacity : 0
            for button in self.independentButtons {
                button.alpha = showing ? self.controlsOpacity : 0
                button.transform = showing || reduced ? .identity : CGAffineTransform(scaleX: 0.87, y: 0.87)
            }
            self.handle.transform = showing && !reduced ? CGAffineTransform(scaleX: 0.78, y: 0.78) : .identity
            self.bar.transform = showing || reduced ? .identity : CGAffineTransform(scaleX: 0.87, y: 0.87)
        }
        scheduleCollapse()
    }

    private func scheduleCollapse() {
        hideTask?.cancel()
        guard expanded, !dragging, presentedViewController == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.setExpanded(false)
        }
    }
}

@MainActor var ink: Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.045, green: 0.053, blue: 0.075, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.975, alpha: 1)
    })
}
@MainActor var cream: Color { Color.primary }
@MainActor var amber: Color { AppStyle.accent }
@MainActor var panel: Color { Color(uiColor: .secondarySystemGroupedBackground) }

private struct LibraryScreen: View {
    private enum LibraryTab: Hashable {
        case library, insights, settings, search
    }

    @Environment(\.dynamicTypeSize) private var dynamicType
    var session: Session
    let previewInsights: PlayHistory?
    let previewName: String?
    let previewLandscape: Bool
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("accentRed") private var accentRed = 0.96
    @AppStorage("accentGreen") private var accentGreen = 0.73
    @AppStorage("accentBlue") private var accentBlue = 0.48
    @AppStorage("showRecentGame") private var showRecent = true
    @AppStorage("showThumbnails") private var showThumbnails = true
    @AppStorage("libraryList") private var libraryList = false
    @AppStorage("librarySort") private var sortKey = LibrarySort.recent.rawValue
    @State private var importing = false
    @State private var filter = ""
    @State private var searchPresented = false
    @State private var selected: Novel?
    @State private var selectedTab: GameTab = .overview
    @State private var showingImportReview = false
    @State private var gameToLaunch: Novel?
    @State private var highlightedID: Novel.ID?
    @State private var openedID: Novel.ID?
    @State private var libraryTab: LibraryTab = .library
    @GestureState private var carouselDrag: CGFloat = 0
    @State private var coverAccent: Color?
    @State private var wideLayout = false
    @Namespace private var optionsMotion
    @FocusState private var focusedGame: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: Session, previewTab: GameTab?, previewOpen: Bool, previewInsights: PlayHistory?,
         previewName: String?, previewLandscape: Bool) {
        self.session = session
        self.previewInsights = previewInsights
        self.previewName = previewName
        self.previewLandscape = previewLandscape
        if previewOpen {
            let id = session.novels.first?.id
            _openedID = State(initialValue: id)
            _highlightedID = State(initialValue: id)
        }
        _libraryTab = State(initialValue: previewName == "Settings" ? .settings : previewInsights == nil ? .library : .insights)
        _selected = State(initialValue: previewTab != nil || previewName == "landscape-options" ? session.novels.first : nil)
        _wideLayout = State(initialValue: previewLandscape)
        _selectedTab = State(initialValue: previewTab ?? .overview)
    }

    private var sortedNovels: [Novel] {
        (LibrarySort(rawValue: sortKey) ?? .recent).sorted(session.novels, history: session.activity.history)
    }

    private var visibleNovels: [Novel] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? sortedNovels : sortedNovels.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 500 && geometry.size.width > geometry.size.height && !dynamicType.isAccessibilitySize
            let games = sortedNovels

            let feature = games.first(where: { $0.id == highlightedID }) ?? games.first
            let inlineGame = wide ? selected : nil
            let backdropGame = inlineGame ?? feature
            ZStack {
                launcher(wide: wide, games: games, feature: feature)
                    .opacity(inlineGame == nil ? 1 : 0)
                    .allowsHitTesting(inlineGame == nil)
                    .accessibilityHidden(inlineGame != nil)
                    .zIndex(0)
                if let inlineGame {
                    NovelSheet(novel: inlineGame, session: session, initialTab: selectedTab, namespace: optionsMotion,
                               close: closeOptions) { game in
                        session.launch(game)
                    }
                    .id(inlineGame.id)
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .frame(maxWidth: 1320)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: wide, initial: true) { _, value in wideLayout = value }
            .task(id: wide) {
                guard let previewName, wide == previewLandscape else { return }
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
                if previewName == "Search" {
                    libraryTab = .search
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    searchPresented = true
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                }
                if previewName.hasPrefix("landscape-return") {
                    let index = previewName.hasSuffix("second") ? 1 : 2
                    guard session.novels.indices.contains(index) else { return }
                    let game = session.novels[index]
                    toggleCover(game)
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    showOptions(game)
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    closeOptions()
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                }
                let marker = URL.cachesDirectory.appending(path: "renios-preview.txt")
                try? Data(previewName.utf8).write(to: marker, options: .atomic)
            }
            .task(id: wide ? backdropGame?.cover : nil) {
                let url = wide ? backdropGame?.cover : nil
                let rgb = await Task.detached(priority: .utility) { Self.coverColor(at: url) }.value
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                    coverAccent = rgb.map {
                        Color(red: Double(($0 >> 16) & 255) / 255,
                              green: Double(($0 >> 8) & 255) / 255,
                              blue: Double($0 & 255) / 255)
                    }
                }
            }
            .background {
                if wide && libraryTab == .library, let coverAccent {
                    RadialGradient(colors: [coverAccent.opacity(0.22), .clear], center: .center,
                                   startRadius: 0, endRadius: geometry.size.width * 0.75)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .background(ink.ignoresSafeArea())
        .preferredColorScheme(AppStyle.theme)
        .tint(Color(red: accentRed, green: accentGreen, blue: accentBlue))
        .onChange(of: appearance) { _, _ in AppStyle.applyToWindows() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder, UTType(filenameExtension: "apk") ?? .data]) {
            switch $0 {
            case .success(let url): session.add(url)
            case .failure(let error): session.message = error.localizedDescription
            }
        }
        .sheet(item: Binding(get: { wideLayout ? nil : selected },
                             set: { if !wideLayout { selected = $0 } }), onDismiss: launchSelectedGame) { novel in
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
            Button("Open Mods") { showOptions(game, tab: .mods) }
        } message: { game in
            Text("\(game.title) was updated. Your mods are still installed. Re-enable the ones you want in Mods.")
        }
        .alert("reniOS", isPresented: Binding(
            get: { !(wideLayout && selected != nil) && session.message != nil },
            set: { if !$0 { session.message = nil } }
        )) {
            Button("OK", role: .cancel) { session.message = nil }
        } message: {
            Text(session.message ?? "")
        }
    }

    private func launcher(wide: Bool, games: [Novel], feature: Novel?) -> some View {
        TabView(selection: $libraryTab) {
            Tab("Library", systemImage: "books.vertical", value: .library) {
                VStack(spacing: 0) {
                    header("Library", showsImport: true)
                    if let feature {
                        if wide {
                            landscape(feature: feature, games: games)
                        } else {
                            portrait(games: games)
                        }
                    } else {
                        emptyLibrary
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            Tab("Insights", systemImage: "chart.bar.xaxis", value: .insights) {
                VStack(spacing: 0) {
                    header("Insights")
                    InsightsView(history: previewInsights ?? session.activity.history,
                                 titles: Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0.title) }),
                                 wide: wide)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                AppSettingsView()
            }

            Tab(value: .search, role: .search) {
                NavigationStack {
                    Group {
                        if visibleNovels.isEmpty {
                            if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ContentUnavailableView("No games in your library", systemImage: "books.vertical")
                            } else {
                                ContentUnavailableView.search(text: filter)
                            }
                        } else {
                            searchResults(visibleNovels)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ink)
                    .navigationTitle("Search Games")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Import Game", systemImage: "plus") {
                                searchPresented = false
                                importing = true
                            }
                            .disabled(session.isImporting)
                        }
                    }
                }
                .searchable(text: $filter, isPresented: $searchPresented,
                            placement: .navigationBarDrawer(displayMode: .always), prompt: "Search games")
            }
        }
        .onChange(of: libraryTab) { _, tab in
            searchPresented = tab == .search
        }
    }

    private func header(_ title: String, showsImport: Bool = false) -> some View {
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
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if session.isImporting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Importing")
            }
            if showsImport {
                Menu {
                    Picker("Sort By", selection: $sortKey) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Sort Library")
                importButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 9)
    }

    private var importButton: some View {
        Button {
            searchPresented = false
            importing = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(amber)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import Game")
        .accessibilityIdentifier("importGame")
        .disabled(session.isImporting)
    }

    private func landscape(feature: Novel, games: [Novel]) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let cardWidth = min(640, width * 0.66)
            let cardHeight = max(106, geometry.size.height - 18)
            let stride = cardWidth + 16
            let center = games.firstIndex(where: { $0.id == feature.id }) ?? 0
            let visible = max(0, center - 2)...min(games.count - 1, center + 2)

            ZStack {
                ForEach(visible.map { games[$0] }) { game in
                    if let index = games.firstIndex(where: { $0.id == game.id }) {
                        let distance = CGFloat(index - center) + carouselDrag / stride
                        let emphasis = min(abs(distance), 1)
                        carouselCard(game, selected: index == center, width: cardWidth, height: cardHeight)
                            .scaleEffect(reduceMotion ? 1 : 1 - 0.11 * emphasis)
                            .opacity(reduceMotion ? 1 : 1 - 0.42 * emphasis)
                            .offset(x: distance * stride)
                            .allowsHitTesting(abs(distance) * stride < (width + cardWidth) / 2)
                            .accessibilityHidden(abs(index - center) > 1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight + 8)
            .contentShape(.rect)
            .clipped()
            .animation(carouselMotion, value: carouselDrag == 0)
            .highPriorityGesture(
                carouselSwipe(games: games, center: center, stride: stride),
                including: games.count > 1 ? .all : .subviews
            )
            .accessibilityScrollAction { edge in
                switch edge {
                case .leading: moveCarousel(in: games, from: center, direction: -1)
                case .trailing: moveCarousel(in: games, from: center, direction: 1)
                default: break
                }
            }
            .onChange(of: games.map(\.id), initial: true) {
                if !games.contains(where: { $0.id == highlightedID }) {
                    highlightedID = games.first?.id
                }
            }
            .onChange(of: focusedGame) { _, id in
                if let id { centerGame(id) }
            }
        }
    }

    private func carouselSwipe(games: [Novel], center: Int, stride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($carouselDrag) { value, offset, transaction in
                transaction.animation = nil
                let distance = value.translation.width
                guard abs(distance) > abs(value.translation.height) else { return }
                let atEdge = (center == 0 && distance > 0) || (center == games.count - 1 && distance < 0)
                offset = min(max(distance, -stride), stride) * (atEdge ? 0.23 : 1)
            }
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height), openedID != nil else { return }
                withAnimation(carouselMotion) { openedID = nil }
            }
            .onEnded { value in
                let distance = value.translation.width
                guard abs(distance) > abs(value.translation.height) else { return }
                let projected = value.predictedEndTranslation.width
                let direction = abs(distance) > stride * 0.22 ? distance : projected
                if abs(direction) > stride * 0.22 {
                    moveCarousel(in: games, from: center, direction: direction < 0 ? 1 : -1)
                }
            }
    }

    private func moveCarousel(in games: [Novel], from index: Int, direction: Int) {
        let target = min(max(index + direction, 0), games.count - 1)
        centerGame(games[target].id)
    }

    private var carouselMotion: Animation? {
        reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.86)
    }

    private func carouselCard(_ game: Novel, selected: Bool, width: CGFloat, height: CGFloat) -> some View {
        let open = openedID == game.id
        let cover = Button {
            toggleCover(game)
        } label: {
            let face = carouselFace(game, selected: selected, height: height)
            if self.selected?.id == game.id || reduceMotion {
                face
            } else {
                face.matchedGeometryEffect(id: game.id, in: optionsMotion)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedGame, equals: game.id)
        .accessibilityLabel(game.title)
        .accessibilityHint(open ? "Hide game actions" : "Show game actions")
        .accessibilityAddTraits(selected ? .isSelected : [])

        return ZStack(alignment: .trailing) {
            if open {
                CoverArt(url: showThumbnails ? game.cover : nil, tint: carouselTint(game))
                    .scaleEffect(1.15)
                    .blur(radius: 32)
                    .overlay {
                        LinearGradient(colors: [ink.opacity(0.42), ink.opacity(0.70)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .clipShape(.rect(cornerRadius: 19))
                    .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.12)) }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            cover
                .frame(width: reduceMotion && open ? width * 0.52 : width, height: height)
                .rotation3DEffect(.degrees(open && !reduceMotion ? 53 : 0), axis: (x: 0, y: 1, z: 0),
                                  anchor: .leading, perspective: 0.32)
                .frame(width: width, alignment: .leading)
            if open {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 10) {
                        libraryAction("Play", icon: "play.fill", prominent: true) { session.launch(game) }
                            .disabled(session.isImporting || Session.engine(for: game) == nil)
                        libraryAction("Options", icon: "text.alignleft") { showOptions(game) }
                    }
                    .padding(.horizontal, 13)
                }
                .frame(width: width * 0.40)
                .transition(reduceMotion ? .opacity : .offset(x: 16, y: 0).combined(with: .opacity))
            }
        }
        .frame(width: width, height: height)
    }

    private func carouselFace(_ game: Novel, selected: Bool, height: CGFloat) -> some View {
        CoverArt(url: showThumbnails ? game.cover : nil, tint: carouselTint(game))
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.title)
                        .font(.system(size: min(36, max(19, height * 0.18)), weight: .semibold, design: .serif))
                        .lineLimit(2)
                    gameVersions(game)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .clipShape(.rect(cornerRadius: 19))
            .overlay {
                RoundedRectangle(cornerRadius: 19)
                    .strokeBorder(selected ? amber.opacity(0.8) : .white.opacity(0.16), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 19))
    }

    private func toggleCover(_ game: Novel) {
        withAnimation(carouselMotion) {
            highlightedID = game.id
            openedID = openedID == game.id ? nil : game.id
        }
    }

    private func centerGame(_ id: Novel.ID) {
        withAnimation(carouselMotion) {
            if openedID != id { openedID = nil }
            highlightedID = id
        }
    }

    private func carouselTint(_ game: Novel) -> Color {
        let index = game.title.utf8.reduce(0) { ($0 * 31 + Int($1)) % 4 }
        return [amber, Color(red: 0.56, green: 0.63, blue: 0.97),
                Color(red: 0.48, green: 0.81, blue: 0.70), Color(red: 0.91, green: 0.54, blue: 0.64)][index]
    }

    private func libraryAction(_ title: String, icon: String, prominent: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold))
                Text(title).font(.headline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.white : cream)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .glassEffect(.regular.tint(prominent ? amber.opacity(0.46) : nil).interactive(),
                         in: .rect(cornerRadius: prominent ? 17 : 22))
        }
        .buttonStyle(.plain)
    }

    private nonisolated static func coverColor(at url: URL?) -> UInt32? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 24
              ] as CFDictionary),
              let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        var red = 0
        var green = 0
        var blue = 0
        var total = 0
        for index in stride(from: 0, to: 1024, by: 4) where pixels[index + 3] > 192 {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let light = max(r, g, b)
            guard light > 25 else { continue }
            let weight = light - min(r, g, b) + 1
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return nil }
        return UInt32(red / total) << 16 | UInt32(green / total) << 8 | UInt32(blue / total)
    }

    private func gameVersions(_ game: Novel) -> some View {
        HStack(spacing: 7) {
            if let version = game.gameVersion { Text(version).accessibilityLabel("Game version \(version)") }
            if let engine = game.detectedEngine {
                Text("Ren’Py \(engine)").foregroundStyle(amber)
            } else if let selection = game.engineOverride, Session.installedEngines.contains(selection) {
                Text("Ren’Py \(selection) selected").foregroundStyle(amber)
            } else if let engine = Session.automaticEngine(for: game) {
                Text("Ren’Py \(engine) auto").foregroundStyle(amber)
            } else {
                Text("Ren’Py —").accessibilityLabel("Ren’Py version unknown")
            }
        }
        .font(.caption2.monospacedDigit().weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .capsule)
    }

    private func searchResults(_ games: [Novel]) -> some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(games) { game in
                    Button { showOptions(game) } label: { gameRow(game, highlighted: false) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func portrait(games: [Novel]) -> some View {
        let lastPlayed = games.filter { $0.lastPlayed != nil }.max {
            ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                if showRecent, let feature = lastPlayed ?? games.first {
                    VStack(alignment: .leading, spacing: 8) {
                        if lastPlayed != nil {
                            Text("Last Played").font(.headline).accessibilityAddTraits(.isHeader)
                        }
                        featureCard(feature, compact: false).frame(minHeight: 238)
                    }
                }
                HStack {
                    Text("Games").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(games.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if libraryList {
                    LazyVStack(spacing: 6) {
                        ForEach(games) { game in
                            Button { showOptions(game) } label: { gameRow(game, highlighted: false) }
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                        ForEach(games) { game in
                            Button { showOptions(game) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    if showThumbnails {
                                        CoverArt(url: showThumbnails ? game.cover : nil, tint: amber)
                                            .aspectRatio(1.52, contentMode: .fit)
                                            .overlay(alignment: .bottomLeading) {
                                                gameVersions(game)
                                                    .padding(7)
                                            }
                                            .clipShape(.rect(cornerRadius: 12))
                                    }
                                    Text(game.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2, reservesSpace: true)
                                    if !showThumbnails { gameVersions(game) }
                                }
                                .padding(showThumbnails ? 0 : 12)
                                .background(showThumbnails ? Color.clear : panel, in: .rect(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
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
            if showThumbnails {
                CoverArt(url: game.cover, tint: amber)
                    .frame(width: 52, height: 37)
                    .clipShape(.rect(cornerRadius: 6))
            }
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
            CoverArt(url: showThumbnails ? game.cover : nil, tint: amber)
            LinearGradient(stops: [.init(color: .clear, location: 0.15),
                                   .init(color: Color.black.opacity(0.52), location: 0.49),
                                   .init(color: Color.black.opacity(0.88), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                gameVersions(game)
                Text(game.title)
                    .font(.system(compact ? .largeTitle : .title, design: .serif).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        libraryAction("Play", icon: "play.fill", prominent: true) {
                            session.launch(game)
                        }
                        .disabled(session.isImporting || Session.engine(for: game) == nil)
                        libraryAction("Options", icon: "text.alignleft") { showOptions(game) }
                    }
                    .frame(maxWidth: 315)
                }
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
            searchPresented = false
            importing = true
        }
        .buttonStyle(.glassProminent)
        .disabled(session.isImporting)
    }

    private func showOptions(_ game: Novel, tab: GameTab = .overview) {
        searchPresented = false
        selectedTab = tab
        withAnimation(wideLayout ? carouselMotion : nil) {
            if wideLayout {
                libraryTab = .library
                highlightedID = game.id
            }
            selected = game
        }
    }

    private func closeOptions() {
        guard let game = selected else { return }
        withAnimation(carouselMotion) {
            if session.novels.contains(where: { $0.id == game.id }) {
                highlightedID = game.id
            }
            selected = nil
        }
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.incoming.title).font(.headline)
                        Text(plan.incoming.gameVersion.map { "Importing version \($0)" } ?? "Incoming version unknown")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                                    Text(actionTitle(for: game))
                                    Text(versionSummary(for: game))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if plan.matchingGames.count > 1 {
                                        Text(game.root.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Installed Games")
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

    private func actionTitle(for game: Novel) -> String {
        switch GameMetadata.compareVersions(plan.incoming.gameVersion, game.gameVersion) {
        case .orderedDescending?: "Update \(game.title)"
        case .orderedAscending?: "Install Older Version"
        case .orderedSame?: "Replace Same Version"
        case nil: "Replace \(game.title)"
        }
    }

    private func versionSummary(for game: Novel) -> String {
        let installed = game.gameVersion ?? "Unknown"
        let incoming = plan.incoming.gameVersion ?? "Unknown"
        return "Installed \(installed) → Incoming \(incoming)"
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
    let namespace: Namespace.ID?
    let close: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: Session
    @State private var tab: GameTab = .overview
    @State private var choosingCover = false
    @State private var findingCover = false
    @State private var choosingEngine = false
    @State private var confirmingRemoval = false
    @State private var renaming = false
    @State private var newTitle = ""

    init(novel: Novel, session: Session, initialTab: GameTab, namespace: Namespace.ID? = nil,
         close: (() -> Void)? = nil, launch: @escaping (Novel) -> Void) {
        game = novel
        self.session = session
        self.launch = launch
        self.namespace = namespace
        self.close = close
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
            Group {
                if namespace != nil { inlineOptions(width: geometry.size.width) }
                else { sheetOptions(wide: wide, width: geometry.size.width) }
            }
            .padding(.horizontal, 16)
            .padding(.top, namespace == nil ? 17 : 6)
            .padding(.bottom, 6)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background {
            if namespace == nil { ink.ignoresSafeArea() }
        }
        .tint(amber)
        .preferredColorScheme(AppStyle.theme)
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
                .preferredColorScheme(AppStyle.theme)
                .tint(amber)
        }
        .confirmationDialog("Remove \(novel.title)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Game, Keep Saves") { session.delete(novel, keepingSaves: true); leaveOptions() }
            Button("Remove Game and Saves", role: .destructive) { session.delete(novel, keepingSaves: false); leaveOptions() }
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

    private func inlineOptions(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 10) {
                if let namespace {
                    artwork.matchedGeometryEffect(id: game.id, in: namespace)
                }
                playButton
            }
            .frame(width: min(width * 0.34, 300))
            .padding(.vertical, 6)
            VStack(spacing: 10) {
                header
                tabBar
                if tab == .overview {
                    ScrollView { settings }
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    managementPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(reduceMotion ? .opacity : .offset(x: 30, y: 0).combined(with: .opacity))
        }
    }

    private func sheetOptions(wide: Bool, width: CGFloat) -> some View {
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
                            .frame(width: min(width * 0.27, 275))
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
    }

    private func leaveOptions() {
        if let close { close() } else { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Button("Back to Library", systemImage: namespace == nil ? "xmark" : "chevron.left") { leaveOptions() }
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.07), in: .circle)
                .disabled(session.isImporting)
            VStack(alignment: .leading, spacing: 2) {
                Text(novel.title)
                    .font(.system(.headline, design: .serif).weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(cream)
                    .accessibilityAddTraits(.isHeader)
                if let version = novel.gameVersion {
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
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
            leaveOptions()
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
