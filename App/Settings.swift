import SwiftUI
import UIKit

@MainActor
enum AppStyle {
    static var theme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "dark" {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    static var accent: Color {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "accentRed") != nil else {
            return Color(red: 0.96, green: 0.73, blue: 0.48)
        }
        return Color(red: defaults.double(forKey: "accentRed"), green: defaults.double(forKey: "accentGreen"),
                     blue: defaults.double(forKey: "accentBlue"))
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
    @AppStorage("widescreen") private var widescreen = false

    private var accent: Binding<Color> {
        Binding(get: { Color(red: red, green: green, blue: blue) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
                red = Double(r); green = Double(g); blue = Double(b)
            }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("System").tag("system")
                    }
                    ColorPicker("Accent Color", selection: accent, supportsOpacity: false)
                    Button("Reset Accent") { red = 0.96; green = 0.73; blue = 0.48 }
                }
                Section {
                    Toggle("Track Play Time", isOn: $insightsEnabled)
                } header: { Text("Insights") } footer: {
                    Text("Turning tracking off pauses new play-time records. Your existing history stays here.")
                }
                Section("Library") {
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
                } header: { Text("In-Game Controls") } footer: {
                    Text("Drag the handle or row to move it. With Separate Buttons, drag each control to its own position. Changes apply the next time you open a game.")
                }
                Section {
                    Toggle("Fill Screen", isOn: $widescreen)
                } header: { Text("Ren’Py") } footer: {
                    Text("Expands the game image to remove engine-generated black borders. This stretches the image to fit your screen. Borders drawn inside a game’s artwork may remain. Applies when you next launch a game.")
                }
                Section {
                    NavigationLink {
                        QuickGuide()
                    } label: {
                        Label("Quick Guide", systemImage: "questionmark.circle")
                    }
                    Button("Submit Bug or Feature Request", systemImage: "bubble.left.and.bubble.right") {}
                        .disabled(true)
                } header: { Text("Help") } footer: {
                    Text("Requests will open here in a future update.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ink)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: appearance) { _, _ in AppStyle.applyToWindows() }
    }
}

private struct QuickGuide: View {
    var body: some View {
        List {
            Section("Bring Your Games") {
                Label("Use a Ren’Py Android APK or a Windows game ZIP. Keep the game folder and its .rpa or .rpy files together.", systemImage: "square.and.arrow.down")
                Text("Choose Import Game with +. macOS game packages aren’t supported. reniOS identifies duplicates and offers to update matching games while keeping your saves.")
            }
            Section("Play Your Way") {
                Text("Swipe between covers in landscape. Tap a cover for Play and Options. Portrait shows your library as a grid or list.")
                Text("Options contains saves, mods, backups, engine selection, and orientation. Updated games keep mods disabled until you turn them back on.")
            }
            Section("The Floating Controls") {
                Text("Tap ••• to open the bar. Previous rolls back, Skip advances text, the gear opens the game menu, and Keyboard shows or hides typing. Power asks before closing.")
                Text("Drag controls to move them. Settings lets you choose a horizontal row, a vertical row, separate buttons, and their opacity.")
            }
            Section("If a Game Crashes") {
                Text("Return to the library, open the game’s Options, tap •••, then Share Diagnostics. Include the game name, its version, the selected engine, and what you did before the crash when sharing the report.")
                Text("You can select another bundled engine in Options. Keep a save backup before trying an older engine.")
            }
            Section("Make reniOS Yours") {
                Text("Appearance changes the library theme and accent. Library settings control recent games, layout, and thumbnails. Insights tracks active foreground play time and can be paused. Fill Screen stretches a game to use the display.")
                Text("Find Cover offers an exact catalog match or private in-app browsing. Tap an image and use it as the cover, or select an image you already have with Choose Cover.")
            }
        }
        .navigationTitle("Quick Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
