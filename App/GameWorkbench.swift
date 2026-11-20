import SwiftUI

struct ToolEntry: Decodable, Identifiable {
    let name, value, kind: String
    let watched, frozen: Bool
    let truncated: Bool?
    var id: String { name }
}

struct ToolReply: Decodable {
    let id: String
    let rows: [ToolEntry]
    let total: Int
    let enabled, canUndo: Bool
    let error: String?
    let activated, limited: Bool?
}

private enum ToolPage: String, CaseIterable, Identifiable {
    case values, gallery, replays, mods
    var id: Self { self }
    var title: String { self == .mods ? "Mod Buttons" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .values: "slider.horizontal.3"
        case .gallery: "photo.stack"
        case .replays: "play.rectangle.on.rectangle"
        case .mods: "puzzlepiece.extension"
        }
    }
}

struct GameWorkbench: View {
    let request: URL
    let mods: Bool
    let close: () -> Void
    let shortcut: (Int32, Int32) -> Void
    @State private var page = ToolPage.values
    @State private var query = ""
    @State private var filter = "All"
    @State private var offset = 0
    @State private var reply: ToolReply?
    @State private var busy = false
    @State private var scope = "Name or value"
    @State private var valueType = "Original"
    @State private var newName = ""
    @State private var creating = false
    @State private var message: String?
    @State private var editing: ToolEntry?
    @State private var draft = ""
    @FocusState private var searching: Bool

    private var current: ToolPage { mods ? .mods : page }
    private var filterID: [String] { [current.rawValue, query, filter, scope, String(offset)] }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height && geo.size.width > 620
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: mods ? ToolPage.mods.icon : "switch.2")
                        .font(.title2).foregroundStyle(amber)
                    Text(mods ? "Mod Buttons" : "Game Tools").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done", action: close).buttonStyle(.glass)
                }
                HStack(alignment: .top, spacing: 16) {
                    if wide && !mods { VStack(spacing: 6) { tabs }.frame(width: 140) }
                    VStack(alignment: .leading, spacing: 8) {
                        if !wide && !mods { HStack(spacing: 5) { tabs } }
                        if !mods { search }
                        if current == .values { filters }
                        if current == .gallery || current == .replays {
                            Toggle(current == .gallery ? "Unlock game gallery" : "Unlock game replays",
                                   isOn: Binding(get: { reply?.enabled ?? false }, set: { _ in command("toggle") }))
                                .font(.subheadline.weight(.medium)).disabled(busy || reply == nil)
                        }
                        if current == .values && reply?.limited == true {
                            Text("Large collection: showing the first indexed values.").font(.footnote)
                        }
                        if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(reply?.rows ?? []) { entry in entryRow(entry) }
                                if let reply, reply.rows.isEmpty {
                                    Text(mods ? "No named mod buttons found in this scene." : "No matching items.")
                                        .foregroundStyle(.secondary).padding(12)
                                }
                                if mods { shortcuts }
                                if let reply, reply.total > 40 {
                                    HStack {
                                        Button("Previous") { offset = max(0, offset - 40) }.disabled(offset == 0)
                                        Spacer()
                                        Text("\(offset + 1)–\(min(offset + 40, reply.total)) of \(reply.total)")
                                            .font(.caption.monospacedDigit())
                                        Spacer()
                                        Button("Next") { offset += 40 }.disabled(offset + 40 >= reply.total)
                                    }.buttonStyle(.borderless).padding(.vertical, 6)
                                }
                            }
                        }.scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .padding(.horizontal, wide ? 24 : 17).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: [ink, panel], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .center) { if busy && reply == nil { ProgressView() } }
        }
        .tint(amber)
        .task(id: filterID) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            if !Task.isCancelled { _ = await send("list") }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled && current == .values && !busy && editing == nil && !searching {
                    _ = await send("list")
                }
            }
        }
        .alert("Create game variable", isPresented: $creating) {
            TextField("Variable name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Initial value", text: $draft)
            Button("Create") { command("create", key: newName, draft: draft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a number, true, false, or text.")
        }
        .sheet(item: $editing) { entry in editor(entry) }
    }

    @ViewBuilder private var tabs: some View {
        ForEach([ToolPage.values, .gallery, .replays]) { item in
            Button {
                page = item; query = ""; filter = "All"; offset = 0; reply = nil
            } label: {
                Label(item.title, systemImage: item.icon)
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(item == page ? amber : cream)
                    .background(item == page ? amber.opacity(0.15) : Color.clear, in: .capsule)
            }.buttonStyle(.plain)
        }
    }

    private var search: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(current == .values ? "Find a name or value" : "Find " + current.title.lowercased(), text: $query)
                .focused($searching).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: query) { _, _ in offset = 0 }
            if !query.isEmpty { Button("Clear", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly) }
        }.padding(10).background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    private var filters: some View {
        HStack {
            Menu {
                Picker("Search in", selection: $scope) {
                    ForEach(["Name or value", "Name", "Value"], id: \.self) { Text($0).tag($0) }
                }
                Button("Capture comparison values") { command("snapshot") }
                Button("Create variable") { newName = ""; draft = ""; creating = true }
                Picker("Show", selection: $filter) {
                    ForEach(["All", "Watching", "Frozen", "Changed", "Increased", "Decreased"], id: \.self) { Text($0).tag($0) }
                }
            } label: { Label(filter == "All" ? "All values" : filter, systemImage: "line.3.horizontal.decrease") }
                .onChange(of: scope) { _, _ in offset = 0 }
                .onChange(of: filter) { _, _ in offset = 0 }
            Spacer()
            Button("Undo", systemImage: "arrow.uturn.backward") { command("undo") }.disabled(reply?.canUndo != true || busy)
        }.font(.footnote.weight(.semibold))
    }

    private func entryRow(_ entry: ToolEntry) -> some View {
        Button {
            if current == .values {
                valueType = "Original"; draft = entry.value; message = nil; editing = entry
            } else { command("open", key: entry.name, dismiss: true) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.frozen ? "snowflake" : entry.watched ? "eye.fill" : current.icon)
                    .foregroundStyle(amber).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !entry.kind.isEmpty {
                        Text(verbatim: entry.value).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: current == .replays ? "play.fill" : "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).frame(minHeight: 48)
                .background(.thinMaterial, in: .rect(cornerRadius: 13)).contentShape(.rect)
        }.buttonStyle(.plain)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Link an on-screen button", systemImage: "hand.tap") { command("link", dismiss: true) }
                .buttonStyle(.glass)
            Text("Keyboard shortcuts").font(.headline)
            HStack {
                ForEach(Array(["M", "F1", "F2", "F3", "F4"].enumerated()), id: \.offset) { index, key in
                    Button(key) {
                        let scan = Int32(index == 0 ? 16 : 57 + index)
                        shortcut(scan, index == 0 ? 109 : (1 << 30) | scan)
                    }.buttonStyle(.glass)
                }
            }
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ entry: ToolEntry) -> some View {
        NavigationStack {
            Form {
                Section(entry.name) {
                    Picker("Type", selection: $valueType) {
                        ForEach(["Original", "Integer", "Decimal", "Boolean", "Text"], id: \.self) { Text($0).tag($0) }
                    }
                    if valueType == "Boolean" || (valueType == "Original" && entry.kind == "bool") {
                        Picker("Value", selection: $draft) { Text("True").tag("True"); Text("False").tag("False") }
                            .pickerStyle(.segmented)
                    } else {
                        TextField("Value", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                    if entry.truncated == true {
                        Text("This long value is shown as a preview.").foregroundStyle(.secondary)
                    } else {
                        Button("Apply change") { command("edit", key: entry.name, draft: draft) }
                    }
                }
                Section {
                    Button(entry.watched ? "Stop watching" : "Watch value", systemImage: "eye") { command("watch", key: entry.name) }
                    Button(entry.frozen ? "Unfreeze value" : "Freeze value", systemImage: "snowflake") { command("freeze", key: entry.name) }
                }
                if let message { Text(message).foregroundStyle(.orange) }
            }.disabled(busy)
            .navigationTitle("Edit value").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { editing = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).tint(amber)
    }

    private func command(_ action: String, key: String = "", draft: String = "", dismiss: Bool = false) {
        Task {
            if await send(action, key: key, draft: draft) {
                editing = nil
                if dismiss { close() }
            }
        }
    }

    @MainActor private func send(_ action: String, key: String = "", draft: String = "") async -> Bool {
        while busy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(60)) }
        guard !Task.isCancelled else { return false }
        busy = true
        defer { busy = false }
        let payload: [String: Any] = ["section": current.rawValue, "action": action, "key": key,
                                      "query": query, "filter": filter, "scope": scope, "valueType": valueType, "draft": draft, "offset": offset]
        do {
            let result = try await Self.exchange(payload, at: request)
            message = result.error
            if result.error == nil { reply = result }
            return result.error == nil
        } catch is CancellationError { return false }
        catch { message = error.localizedDescription; return false }
    }

    @MainActor static func exchange(_ fields: [String: Any], at request: URL) async throws -> ToolReply {
        let id = UUID().uuidString
        var payload = fields
        payload["id"] = id
        let response = URL(fileURLWithPath: request.path + ".reply")
        try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
        for _ in 0..<55 {
            try await Task.sleep(for: .milliseconds(100))
            if let data = try? Data(contentsOf: response),
               let result = try? JSONDecoder().decode(ToolReply.self, from: data), result.id == id {
                try? FileManager.default.removeItem(at: response)
                return result
            }
        }
        throw URLError(.timedOut)
    }

}
