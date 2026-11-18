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
        case .tide: "Tide"
        }
    }

    static func color(_ night: Int, _ day: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let n = traits.userInterfaceStyle == .dark ? night : day
            return UIColor(red: CGFloat(n >> 16 & 255) / 255, green: CGFloat(n >> 8 & 255) / 255,
                           blue: CGFloat(n & 255) / 255, alpha: 1)
        })
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

struct AppSettingsView: View {
    enum Page: String, CaseIterable, Identifiable, Hashable {
        case appearance = "Appearance", insights = "Insights", library = "Library"
        case controls = "In-Game Controls", help = "Help"
        var id: Self { self }
        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .insights: "chart.bar.xaxis"
            case .library: "books.vertical"
            case .controls: "gamecontroller"
            case .help: "questionmark.circle"
            }
        }
    }

    @State private var query = ""
    private var matchingPages: [Page] {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        return Page.allCases.filter { page in
            let keywords: String
            switch page {
            case .appearance: keywords = "custom themes gilded observatory midnight tide default dark light system accent color reset"
            case .insights: keywords = "enable disable tracking history streak play time"
            case .library: keywords = "show last played recent cover thumbnails layout grid list sort"
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
        case .appearance:
            Section {
                Picker("Display Mode", selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                NavigationLink("Custom Themes") { ThemeGallery() }
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
        case .help: EmptyView()
        }
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
                        ZStack(alignment: .bottomLeading) {
                            theme.canvas
                            if let name = theme.artwork {
                                Color.clear.overlay { Image(name).resizable().scaledToFill() }.clipped()
                            } else {
                                LinearGradient(colors: [.black, Color.brown.opacity(0.58)],
                                               startPoint: .bottomLeading, endPoint: .topTrailing)
                            }
                            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                            HStack {
                                Text(theme.title).font(.system(.title2, design: .serif).weight(.semibold))
                                Spacer()
                                if theme == ThemeSelection.shared.current {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }.foregroundStyle(.white).padding(16)
                        }
                        .frame(height: 130).clipped().clipShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
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
