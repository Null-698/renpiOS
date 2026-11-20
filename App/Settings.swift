import SwiftUI
import UIKit

enum LibraryTheme: String, CaseIterable, Identifiable {
    case standard, observatory, tide
    var id: Self { self }
    var title: String {
        switch self {
        case .standard: "Default"
        case .observatory: "Gilded Observatory"
        case .tide: "Midnight Tide"
        }
    }
    var artwork: String? {
        switch self {
        case .standard: nil
        case .observatory: "Observatory"
        case .tide: nil
        }
    }

    static func color(_ night: Int, _ day: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let n = traits.userInterfaceStyle == .dark ? night : day
            return UIColor(red: CGFloat(n >> 16 & 255) / 255, green: CGFloat(n >> 8 & 255) / 255,
                           blue: CGFloat(n & 255) / 255, alpha: 1)
        })
    }
    static var tideGradient: LinearGradient {
        LinearGradient(colors: [color(0x10152c, 0xeef1fc), color(0x303157, 0xd5d2ee), color(0x174046, 0xc5e9df)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var canvas: Color {
        switch self {
        case .standard: Self.color(0x0c0e13, 0xf5f5f9)
        case .observatory: Self.color(0x21171c, 0xf7ede4)
        case .tide: Self.color(0x10152c, 0xeef1fc)
        }
    }
    var surface: Color {
        switch self {
        case .standard: Color(uiColor: .secondarySystemGroupedBackground)
        case .observatory: Self.color(0x39282c, 0xfffaf3)
        case .tide: Self.color(0x232b49, 0xfafaff)
        }
    }
    var highlight: Color {
        switch self {
        case .standard: Self.color(0xf5ba7a, 0x7b4823)
        case .observatory: Self.color(0xffbc91, 0x83401f)
        case .tide: Self.color(0x91f1c3, 0x146346)
        }
    }
    var lettering: Color {
        switch self {
        case .standard: Color.primary
        case .observatory: Self.color(0xffe8d6, 0x392329)
        case .tide: Self.color(0xdedbff, 0x29254d)
        }
    }
}

@MainActor @Observable
final class ThemeSelection {
    static let shared = ThemeSelection()
    var current: LibraryTheme {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "libraryTheme") }
    }
    private init() {
        current = LibraryTheme(rawValue: UserDefaults.standard.string(forKey: "libraryTheme") ?? "") ?? .standard
    }
}

@MainActor
extension View {
    @ViewBuilder func themedSheet() -> some View {
        if ThemeSelection.shared.current == .standard { self }
        else { self.presentationBackground(ink).tint(amber) }
    }
    @ViewBuilder func themeCase(_ radius: CGFloat) -> some View {
        let theme = ThemeSelection.shared.current
        if theme == .standard { self } else {
            self.overlay {
                let shape = RoundedRectangle(cornerRadius: radius)
                ZStack(alignment: .leading) {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.85), theme.highlight.opacity(0.75),
                        .white.opacity(0.18), theme.highlight], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: theme == .tide ? 2 : 1.4)
                    shape.inset(by: 3).strokeBorder(.white.opacity(0.20), lineWidth: 0.7)
                    if theme == .tide {
                        Rectangle().fill(.white.opacity(0.24)).frame(width: 2).padding(.leading, 7)
                    }
                }.clipShape(shape).allowsHitTesting(false)
            }
        }
    }
}

@MainActor
enum AppStyle {
    static var theme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--launcher-preview"),
           arguments.dropFirst(index + 1).first?.components(separatedBy: "@").first?.hasSuffix("-light") == true { return .light }
        #endif
        return switch UserDefaults.standard.string(forKey: "appearance") ?? "dark" {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    static var accent: Color {
        if ThemeSelection.shared.current != .standard { return ThemeSelection.shared.current.highlight }
        let defaults = UserDefaults.standard
        let red = defaults.object(forKey: "accentRed") == nil ? 0.96 : defaults.double(forKey: "accentRed")
        let green = defaults.object(forKey: "accentGreen") == nil ? 0.73 : defaults.double(forKey: "accentGreen")
        let blue = defaults.object(forKey: "accentBlue") == nil ? 0.48 : defaults.double(forKey: "accentBlue")
        return Color(uiColor: UIColor { traits in
            let light = traits.userInterfaceStyle != .dark
            let background = light ? 0.94 : 0.01
            let target = light ? 0.0 : 1.0
            var rgb = [red, green, blue]
            for _ in 0..<32 {
                let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
                let contrast = (max(luminance, background) + 0.05) / (min(luminance, background) + 0.05)
                if contrast >= 4.5 { break }
                rgb = rgb.map { $0 * 0.92 + target * 0.08 }
            }
            return UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        })
    }

    static func applyToWindows() {
        let style: UIUserInterfaceStyle = theme == .dark ? .dark : theme == .light ? .light : .unspecified
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, newest, oldest, mostPlayed
    var id: Self { self }
    var label: String {
        switch self {
        case .recent: "Last Played"
        case .title: "Title A–Z"
        case .newest: "Newest Added"
        case .oldest: "Oldest Added"
        case .mostPlayed: "Most Played"
        }
    }

    func sorted(_ games: [Novel], history: PlayHistory) -> [Novel] {
        games.sorted { a, b in
            switch self {
            case .recent:
                let lhs = a.lastPlayed ?? .distantPast, rhs = b.lastPlayed ?? .distantPast
                if lhs != rhs { return lhs > rhs }
            case .title:
                let comparison = a.title.localizedStandardCompare(b.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .newest:
                if a.imported != b.imported { return a.imported > b.imported }
            case .oldest:
                if a.imported != b.imported { return a.imported < b.imported }
            case .mostPlayed:
                let lhs = history.games[a.id]?.seconds ?? 0, rhs = history.games[b.id]?.seconds ?? 0
                if lhs != rhs { return lhs > rhs }
            }
            if a.imported != b.imported { return a.imported > b.imported }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

enum EngineOption: String, CaseIterable, Identifiable {
    case fill, dialogue, chinese, memory, refresh, rollback, skip, unseen, developer, console, network
    var id: Self { self }

    var title: String {
        switch self {
        case .fill: "Fill Screen"
        case .dialogue: "Clear Dialogue Backgrounds"
        case .chinese: "Chinese Glyph Fallback"
        case .memory: "Smaller Image Cache"
        case .refresh: "Reduce Screen Refreshes"
        case .rollback: "Extended Rollback"
        case .skip: "Allow Dialogue Skipping"
        case .unseen: "Skip Unread Dialogue"
        case .developer: "Developer Tools"
        case .console: "Interactive Console"
        case .network: "Game Python Networking"
        }
    }

    var standard: Bool {
        if self == .fill { return UserDefaults.standard.bool(forKey: "widescreen") }
        return self == .network
    }
}

struct EnginePreferences: Codable, Equatable, Sendable {
    var flags: [String: Bool] = [:]
    var volume: Double?

    static let defaultsKey = "enginePlaybackDefaults"
    static func decode(_ data: Data?) -> Self {
        data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    static func configuration(for novel: Novel) -> [String: Any] {
        let global = decode(UserDefaults.standard.data(forKey: defaultsKey))
        var config: [String: Any] = ["layout": novel.effectiveLayout,
            "volume": min(1, max(0, novel.enginePreferences?.volume ?? global.volume ?? 1))]
        for option in EngineOption.allCases {
            let local = option == .fill ? novel.fillScreen : novel.enginePreferences?.flags[option.rawValue]
            config[option.rawValue] = local ?? global.flags[option.rawValue] ?? option.standard
        }
        if let base = Bundle.main.url(forResource: "base", withExtension: nil) {
            config["fontDirectory"] = base.appending(path: "ReaderFonts").path
        }
        return config
    }
}

struct EngineSettingsSections: View {
    @AppStorage(EnginePreferences.defaultsKey) private var data = Data()
    var novel: Novel?
    var save: ((Novel) -> Void)?
    @State private var draftVolume: Double?

    init(novel: Novel? = nil, save: ((Novel) -> Void)? = nil) {
        self.novel = novel
        self.save = save
    }

    private var global: EnginePreferences { EnginePreferences.decode(data) }

    private func update(_ edit: (inout EnginePreferences) -> Void) {
        if var game = novel {
            var prefs = game.enginePreferences ?? EnginePreferences()
            edit(&prefs)
            game.enginePreferences = prefs
            save?(game)
        } else {
            var prefs = global
            edit(&prefs)
            if let encoded = try? JSONEncoder().encode(prefs) { data = encoded }
        }
    }

    private func optionRow(_ option: EngineOption) -> some View {
        let inherited = global.flags[option.rawValue] ?? option.standard
        return Group {
            if let game = novel {
                Picker(option.title, selection: Binding<Bool?>(
                    get: { option == .fill ? game.fillScreen : game.enginePreferences?.flags[option.rawValue] },
                    set: { newValue in
                        if option == .fill {
                            var updated = game
                            updated.fillScreen = newValue
                            save?(updated)
                        } else { update { $0.flags[option.rawValue] = newValue } }
                    }
                )) {
                    Text(inherited ? "Use Global (On)" : "Use Global (Off)").tag(nil as Bool?)
                    Text("On").tag(true as Bool?)
                    Text("Off").tag(false as Bool?)
                }
            } else {
                Toggle(option.title, isOn: Binding(get: { inherited }, set: { newValue in
                    update { $0.flags[option.rawValue] = newValue }
                }))
            }
        }
    }

    var body: some View {
        let level = novel?.enginePreferences?.volume ?? global.volume ?? 1
        Section("Audio") {
            if let novel {
                Toggle("Use Global Volume (\(Int(((global.volume ?? 1) * 100).rounded()))%)",
                       isOn: Binding(get: { novel.enginePreferences?.volume == nil },
                                     set: { inherit in update { $0.volume = inherit ? nil : level } }))
            }
            LabeledContent("Game Volume", value: (draftVolume ?? level).formatted(.percent.precision(.fractionLength(0))))
            Slider(value: Binding(get: { draftVolume ?? level }, set: { draftVolume = $0 }),
                   in: 0...1, step: 0.01, onEditingChanged: { active in
                if !active, let volume = draftVolume { update { $0.volume = volume }; draftVolume = nil }
            }).accessibilityLabel("Game Volume")
                .disabled(novel != nil && novel?.enginePreferences?.volume == nil)
        }
        Section("Display and Text") {
            ForEach([EngineOption.fill, .dialogue, .chinese]) { optionRow($0) }
        }
        Section("Performance") {
            ForEach([EngineOption.memory, .refresh]) { optionRow($0) }
        }
        Section {
            ForEach([EngineOption.rollback, .skip, .unseen]) { optionRow($0) }
        } header: { Text("Playback") } footer: { Text("Extended Rollback requests 100 rollback steps and 128 history entries. Games can still set checkpoints or block rollback in a scene.") }
        Section {
            ForEach([EngineOption.developer, .console, .network]) { optionRow($0) }
        } header: { Text("Runtime") } footer: {
            Text("Changes apply on the next game launch. Game Python Networking controls standard Python internet connections during play.")
        }
    }
}

struct AppSettingsView: View {
    enum Page: String, CaseIterable, Identifiable, Hashable {
        case appearance = "Appearance", insights = "Insights", library = "Library"
        case runtime = "Ren’Py", controls = "In-Game Controls", help = "Help"
        var id: Self { self }
        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .insights: "chart.bar.xaxis"
            case .library: "books.vertical"
            case .runtime: "slider.horizontal.3"
            case .controls: "gamecontroller"
            case .help: "questionmark.circle"
            }
        }
    }

    @State private var searchingSettings = false
    @State private var query = ""
    private var matchingPages: [Page] {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        return Page.allCases.filter { page in
            let keywords: String
            switch page {
            case .appearance: keywords = "custom themes gilded observatory midnight tide default dark light system accent color reset"
            case .insights: keywords = "enable disable tracking history streak play time"
            case .library: keywords = "show last played recent cover thumbnails layout grid list sort lock hide hidden privacy face id passcode"
            case .runtime: keywords = "renpy volume rollback console developer network memory skipping refresh dialogue fonts fullscreen global"
            case .controls: keywords = "opacity transparency horizontal vertical row separate buttons drag"
            case .help: keywords = "guide import apk windows zip diagnostics crash saves mods backups patches"
            }
            let terms = page.rawValue + " " + keywords
            return words.allSatisfy { terms.localizedStandardContains(String($0)) }
        }
    }

    @State private var path: [Page]
    init(initialPage: Page? = nil) { _path = State(initialValue: initialPage.map { [$0] } ?? []) }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 570 && geometry.size.width > geometry.size.height {
                let selected = path.last ?? .appearance
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        if searchingSettings {
                            TextField("Find a setting", text: $query)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Text("Settings").font(.title3.weight(.semibold))
                        }
                        Spacer(minLength: 4)
                        Button {
                            searchingSettings.toggle()
                            if !searchingSettings { query = "" }
                        } label: {
                            Image(systemName: searchingSettings ? "xmark" : "magnifyingglass")
                                .frame(width: 34, height: 32)
                        }.buttonStyle(.glass).accessibilityLabel("Search settings")
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(matchingPages) { page in
                                Button { path = [page] } label: {
                                    Label(page.rawValue, systemImage: page.icon)
                                        .font(.subheadline.weight(.medium)).fixedSize()
                                        .padding(.horizontal, 13).frame(minHeight: 36)
                                        .foregroundStyle(page == selected ? amber : cream)
                                        .background(page == selected ? amber.opacity(0.18) : panel, in: .capsule)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.scrollIndicators(.hidden)
                    if matchingPages.isEmpty { ContentUnavailableView.search(text: query) }
                    else {
                        NavigationStack {
                            SettingsPage(page: matchingPages.contains(selected) ? selected : matchingPages[0])
                                .toolbar(.hidden, for: .navigationBar)
                                .contentMargins(.top, 4, for: .scrollContent)
                        }.id(selected)
                    }
                }
                .padding(.horizontal, 16).background(ink)
            } else { portraitSettings }
        }
    }

    private var portraitSettings: some View {
        NavigationStack(path: $path) {
            List(matchingPages) { page in
                NavigationLink(value: page) {
                    Label(page.rawValue, systemImage: page.icon)
                        .padding(.vertical, 8)
                }.listRowBackground(panel)
            }
            .scrollContentBackground(.hidden)
            .background(ink)
            .overlay { if matchingPages.isEmpty { ContentUnavailableView.search(text: query) } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                SettingsPage(page: page)
            }
        }
    }
}

private struct SettingsPage: View {
    let page: AppSettingsView.Page
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("accentRed") private var red = 0.96
    @AppStorage("accentGreen") private var green = 0.73
    @AppStorage("accentBlue") private var blue = 0.48
    @AppStorage("insightsEnabled") private var insightsEnabled = true
    @AppStorage("showRecentGame") private var showRecent = true
    @AppStorage("allowGameLock") private var allowLock = true
    @AppStorage("allowGameHide") private var allowHide = true
    @AppStorage("libraryList") private var libraryList = false
    @AppStorage("showThumbnails") private var thumbnails = true
    @AppStorage("librarySort") private var sort = LibrarySort.recent.rawValue
    @AppStorage("controlsLayout") private var controlsLayout = "horizontal"
    @AppStorage("controlsOpacity") private var controlsOpacity = 1.0

    private var accent: Binding<Color> {
        Binding(get: { Color(red: red, green: green, blue: blue) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
                red = Double(r)
                green = Double(g)
                blue = Double(b)
            }
        })
    }

    var body: some View {
        Group {
            if page == .help {
                QuickGuide()
            } else {
                Form { contents.listRowBackground(panel) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ink)
        .navigationTitle(page.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appearance) { _, _ in AppStyle.applyToWindows() }
    }

    @ViewBuilder private var contents: some View {
        switch page {
        case .runtime: EngineSettingsSections()
        case .appearance:
            Section {
                Picker("Display Mode", selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                NavigationLink("Custom Themes") { ThemeGallery().toolbar(.visible, for: .navigationBar) }
                if ThemeSelection.shared.current == .standard {
                    ColorPicker("Accent Color", selection: accent, supportsOpacity: false)
                    Button("Reset Accent") { red = 0.96; green = 0.73; blue = 0.48 }
                }
            }
        case .insights:
            Section {
                Toggle("Enable Insights", isOn: $insightsEnabled)
            } footer: {
                Text("Turning Insights off hides its tab and pauses new tracking. Existing history stays saved.")
            }
        case .library:
            Section {
                Toggle("Show Last Played", isOn: $showRecent)
                Toggle("Show Cover Thumbnails", isOn: $thumbnails)
                Picker("Layout", selection: $libraryList) {
                    Text("Grid").tag(false)
                    Text("List").tag(true)
                }
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Privacy") {
                Toggle("Allow Locking Games", isOn: $allowLock)
                Toggle("Allow Hiding Games", isOn: $allowHide)
                Text("Hold a cover to lock or hide a game. Swipe down at the top of Library to open Hidden Games. Turning these options off keeps existing games protected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .controls:
            Section {
                Picker("Controls Layout", selection: $controlsLayout) {
                    Text("Horizontal Row").tag("horizontal")
                    Text("Vertical Row").tag("vertical")
                    Text("Separate Buttons").tag("separate")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text(controlsOpacity, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $controlsOpacity, in: 0.25...1)
                }
            } footer: {
                Text("Drag the handle or row to move it. With Separate Buttons, drag each control to its own position. Applies when you next launch a game.")
            }
            Section("Visible Controls") {
                ForEach([1, 2, 3, 4, 6, 7, 8, 5], id: \.self) { key in
                    PlaybackVisibility(key: key)
                }
            }
        case .help: EmptyView()
        }
    }
}

private struct PlaybackVisibility: View {
    let key: Int
    @AppStorage private var hidden: Bool

    init(key: Int) {
        self.key = key
        _hidden = AppStorage(wrappedValue: false, "hidePlaybackControl-" + String(key))
    }

    var body: some View {
        let titles = [1: "Previous", 2: "Skip", 3: "Game Settings", 4: "Keyboard", 5: "Close Game",
                      6: "Game Layout", 7: "Mod Buttons", 8: "Game Tools"]
        Toggle(titles[key] ?? "", isOn: Binding(get: { !hidden }, set: { hidden = !$0 }))
    }
}

private struct ThemeGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(LibraryTheme.allCases) { theme in
                    Button {
                        ThemeSelection.shared.current = theme
                    } label: {
                        HStack {
                            Text(theme.title).font(.system(.title2, design: .serif).weight(.semibold))
                            Spacer()
                            if theme == ThemeSelection.shared.current {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .bottomLeading)
                        .background {
                            ZStack {
                                if theme == .tide { LibraryTheme.tideGradient }
                                else if let name = theme.artwork {
                                    Image(name).resizable().scaledToFill()
                                } else {
                                    LinearGradient(colors: [.black, .brown.opacity(0.58)],
                                                   startPoint: .bottomLeading, endPoint: .topTrailing)
                                }
                                LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                        .clipShape(.rect(cornerRadius: 16))
                        .contentShape(.interaction, RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.title)
                    .accessibilityAddTraits(theme == ThemeSelection.shared.current ? .isSelected : [])
                }
            }.padding()
        }
        .background(ink).navigationTitle("Custom Themes").navigationBarTitleDisplayMode(.inline)
    }
}

private struct QuickGuide: View {
    var body: some View {
        List {
            Group {
                Section("Bring Your Games") {
                    Label("Use a Ren’Py Android APK or a Windows game ZIP. Keep the game folder and its .rpa or .rpy files together.", systemImage: "square.and.arrow.down")
                    Text("Choose Import Game with +. macOS game packages aren’t supported. reniOS identifies duplicates and offers to update matching games while keeping your saves.")
                }
                Section("Play Your Way") {
                    Text("Swipe between covers in landscape. Tap a cover for Play and Options. Portrait shows your library as a grid or list.")
                    Text("Options contains saves, mods, backups, patches, engine selection, and orientation. Updated games keep mods disabled until you turn them back on.")
                }
                Section("The Floating Controls") {
                    Text("Tap ••• to open the bar. Previous rolls back, Skip advances text, the gear opens the game menu, and Keyboard shows or hides typing. Power asks before closing.")
                    Text("Drag controls to move them. Settings lets you choose a horizontal row, a vertical row, separate buttons, and their opacity.")
                }
                Section("If a Game Crashes") {
                    Text("Return to the library, open the game’s Options, tap •••, then Share Diagnostics. Include the game name, its version, the selected engine, and what you did before the crash when sharing the report.")
                    Text("You can select another bundled engine in Options. Keep a save backup before trying an older engine.")
                }
                Section {
                    Button("Submit Bug or Feature Request", systemImage: "bubble.left.and.bubble.right") {}
                        .disabled(true)
                } footer: {
                    Text("Requests will open here in a future update.")
                }
                Section("Make reniOS Yours") {
                    Text("Appearance changes the library theme and accent. Library settings control recent games, layout, and thumbnails. Insights tracks active foreground play time and can be paused. Open a game’s Patches tab to make that game fill the screen.")
                    Text("Find Cover offers an exact catalog match or private in-app browsing. Tap an image and use it as the cover, or select an image you already have with Choose Cover.")
                }
            }.listRowBackground(panel)
        }
        .navigationTitle("Quick Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
