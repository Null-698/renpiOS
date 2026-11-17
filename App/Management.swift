import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SaveManager: View {
    let novel: Novel
    @State private var slots: [LibraryStore.SaveSlot] = []
    @State private var selected: LibraryStore.SaveSlot?
    @State private var naming: LibraryStore.SaveSlot?
    @State private var name = ""
    @State private var labels: [String: String] = [:]
    @State private var message: String?

    private var labelsFile: URL { novel.saves.appending(path: ".renios-slot-labels.json") }

    var body: some View {
        ScrollView {
            if slots.isEmpty {
                ManagementPanel("No save slots yet", icon: "square.stack") {
                    Text("Slots appear here after you save in the game.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 11)], spacing: 11) {
                    ForEach(slots) { slot in
                        SaveSlotRow(slot: slot, title: labels[slot.id] ?? slot.url.deletingPathExtension().lastPathComponent) {
                            Menu {
                                Button("Rename", systemImage: "pencil") {
                                    name = labels[slot.id] ?? ""
                                    naming = slot
                                }
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    perform { try LibraryStore.duplicate(slot) }
                                }
                                ShareLink(item: slot.url) { Label("Export Slot", systemImage: "square.and.arrow.up") }
                                Button("Delete Slot", systemImage: "trash", role: .destructive) { selected = slot }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.68), in: .circle)
                            }
                            .accessibilityLabel("Options for \(labels[slot.id] ?? slot.id)")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Delete this save slot?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Slot", role: .destructive) {
                if let selected {
                    perform {
                        try FileManager.default.removeItem(at: selected.url)
                        labels[selected.id] = nil
                        try writeLabels()
                    }
                }
            }
        }
        .alert("Rename Save", isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } }
        )) {
            TextField("Slot name", text: $name)
            Button("Save") {
                if let naming {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    perform {
                        labels[naming.id] = title.isEmpty ? nil : title
                        try writeLabels()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Saves", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .onAppear {
            slots = LibraryStore.slots(for: novel)
            if let data = try? Data(contentsOf: labelsFile),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) { labels = decoded }
        }
    }

    private func writeLabels() throws {
        try JSONEncoder().encode(labels).write(to: labelsFile, options: .atomic)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { message = error.localizedDescription }
        slots = LibraryStore.slots(for: novel)
    }
}

private struct SaveSlotRow<Actions: View>: View {
    let slot: LibraryStore.SaveSlot
    let title: String
    @ViewBuilder let actions: () -> Actions
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1.6, contentMode: .fit)
                .overlay {
                    if let image {
                        GeometryReader { geometry in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .background(amber.opacity(0.08))
                .clipped()
                .overlay(alignment: .topTrailing) { actions().padding(4) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(slot.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
        .clipShape(.rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
        .task(id: slot.date) {
            let current = slot
            let data = await Task.detached(priority: .utility) {
                LibraryStore.thumbnail(for: current)
            }.value
            if !Task.isCancelled { image = data.flatMap { UIImage(data: $0) } }
        }
    }
}

struct ModManager: View {
    let novel: Novel
    @Binding var working: Bool
    @State private var mods: [LibraryStore.InstalledMod] = []
    @State private var importing = false
    @State private var replacing: UUID?
    @State private var pending: URL?
    @State private var conflicts = 0
    @State private var removing: LibraryStore.InstalledMod?
    @State private var message: String?

    var body: some View {
        ManagementCollection(isEmpty: mods.isEmpty, emptyTitle: "No mods installed", emptyIcon: "puzzlepiece.extension",
                             actionTitle: "Add Mod ZIP", actionIcon: "plus", working: working, message: message,
                             action: { chooseZIP() }) {
            ForEach(mods) { mod in
                HStack(spacing: 12) {
                    managementIcon("puzzlepiece.extension")
                    Toggle(isOn: Binding(get: { mod.enabled }, set: { enabled in
                        run { try LibraryStore.setMod(mod.id, enabled: enabled, on: novel) }
                    })) {
                        Text(mod.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(cream)
                            .lineLimit(2)
                    }
                    .tint(amber)
                    Menu {
                        Button("Replace ZIP", systemImage: "arrow.triangle.2.circlepath") {
                            chooseZIP(replacing: mod.id)
                        }
                        Button("Remove Mod", systemImage: "trash", role: .destructive) { removing = mod }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 44)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Options for \(mod.name)")
                }
                .managementRow()
                .disabled(working)
                .swipeActions(allowsFullSwipe: false) {
                    Button("Remove Mod", systemImage: "trash", role: .destructive) { removing = mod }
                        .disabled(working)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                working = true
                Task {
                    defer { working = false }
                    do {
                        let game = novel
                        conflicts = try await Task.detached(priority: .userInitiated) {
                            try LibraryStore.modConflicts(url, on: game)
                        }.value
                        pending = url
                    } catch { message = error.localizedDescription }
                }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog(replacing == nil ? "Install this mod?" : "Replace this mod?",
                            isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button(replacing == nil ? "Install" : "Replace") {
                guard let pending else { return }
                let previous = replacing
                run { _ = try LibraryStore.installMod(pending, on: novel, replacing: previous) }
            }
        } message: {
            if let replacing, mods.first(where: { $0.id == replacing })?.enabled == false {
                Text("The replacement will stay disabled.")
            } else if conflicts > 0 {
                Text("This mod overrides \(conflicts) existing files while enabled.")
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "mod")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Mod", role: .destructive) {
                guard let removing else { return }
                run { try LibraryStore.removeMod(removing.id, from: novel) }
            }
        }
        .onAppear { mods = LibraryStore.installedMods(for: novel) }
    }

    private func chooseZIP(replacing id: UUID? = nil) {
        replacing = id
        importing = true
    }

    private func run(_ action: @escaping @Sendable () throws -> Void) {
        working = true
        message = nil
        Task {
            defer { working = false; mods = LibraryStore.installedMods(for: novel) }
            do { try await Task.detached(priority: .userInitiated, operation: action).value }
            catch { message = error.localizedDescription }
        }
    }
}

struct BackupManager: View {
    let novel: Novel
    let session: Session
    @State private var entries: [Entry] = []
    @State private var choosing = false
    @State private var actions = false
    @State private var restoring: LibraryStore.SaveArchive?
    @State private var message: String?

    private struct Entry: Identifiable {
        let archive: LibraryStore.SaveArchive
        let imported: Bool
        var id: URL { archive.id }
        var kind: LibraryStore.SaveArchiveKind { imported ? .restore : .exported }
    }

    var body: some View {
        ManagementCollection(isEmpty: entries.isEmpty, emptyTitle: "No backups yet", emptyIcon: "archivebox",
                             actionTitle: "Backup Actions", actionIcon: "plus", working: session.isImporting,
                             message: message, action: { actions = true }) {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Button {
                        restoring = entry.archive
                    } label: {
                        archiveRow(entry.imported ? entry.archive.url.lastPathComponent : "Save Backup",
                                   icon: entry.imported ? "doc.zipper" : "archivebox",
                                   archive: entry.archive, action: "arrow.down.to.line")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Restore saves from this backup")
                    ShareLink(item: entry.archive.url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 40, height: 44)
                    }
                    .accessibilityLabel("Share Backup")
                }
                .managementRow()
                .disabled(session.isImporting)
                .swipeActions(allowsFullSwipe: false) {
                    Button("Delete Backup", systemImage: "trash", role: .destructive) {
                        do {
                            try LibraryStore.removeArchive(entry.archive, from: novel, kind: entry.kind)
                            refresh()
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(session.isImporting)
                }
            }
        }
        .onAppear { refresh() }
        .confirmationDialog("Backups", isPresented: $actions, titleVisibility: .visible) {
            Button("Create Backup") { create() }
            Button("Import Backup ZIP") { choosing = true }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): keep(files)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog("Restore saves?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } }
        ), titleVisibility: .visible, presenting: restoring) { archive in
            Button("Keep Existing Saves") { restore(archive, replacing: false) }
            Button("Replace Matching Saves", role: .destructive) { restore(archive, replacing: true) }
        } message: { archive in
            Text(archive.date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func refresh() {
        entries = LibraryStore.saveArchives(for: novel, kind: .exported).map { Entry(archive: $0, imported: false) }
            + LibraryStore.saveArchives(for: novel, kind: .restore).map { Entry(archive: $0, imported: true) }
        entries.sort { ($0.archive.date, $0.id.path) > ($1.archive.date, $1.id.path) }
    }

    private func create() {
        session.isImporting = true
        message = nil
        let game = novel
        Task {
            defer { session.isImporting = false; refresh() }
            do {
                try await Task.detached(priority: .userInitiated) { try LibraryStore.backup(game) }.value
            } catch { message = error.localizedDescription }
        }
    }

    private func keep(_ files: [URL]) {
        session.isImporting = true
        message = nil
        let game = novel
        Task {
            defer { session.isImporting = false; refresh() }
            do {
                try await Task.detached(priority: .userInitiated) {
                    for file in files { try LibraryStore.keepRestoreArchive(file, for: game) }
                }.value
            } catch { message = error.localizedDescription }
        }
    }

    private func restore(_ archive: LibraryStore.SaveArchive, replacing: Bool) {
        restoring = nil
        message = nil
        Task {
            do {
                let count = try await session.restore(archive.url, to: novel, replacing: replacing)
                message = count == 0 ? "All matching saves were kept." : "Restored \(count) save file(s)."
            } catch { message = error.localizedDescription }
        }
    }
}

private struct ManagementCollection<Rows: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isEmpty: Bool
    let emptyTitle: String
    let emptyIcon: String
    let actionTitle: String
    let actionIcon: String
    let working: Bool
    let message: String?
    let action: () -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: emptyIcon)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(amber)
                        .accessibilityHidden(true)
                    Text(emptyTitle)
                        .font(.system(.title3, design: .serif).weight(.medium))
                        .foregroundStyle(cream)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                List { rows() }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaPadding(.bottom, 72)
                    .transition(.opacity)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .padding(.trailing, 76)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: action) {
                Group {
                    if working { ProgressView().tint(amber) }
                    else { Image(systemName: actionIcon).font(.system(size: 23, weight: .semibold)) }
                }
                .foregroundStyle(cream)
                .frame(width: 58, height: 58)
                .glassEffect(.regular.tint(amber.opacity(0.32)).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionTitle)
            .accessibilityHint(working ? "In progress" : "")
            .disabled(working)
            .padding([.trailing, .bottom], 10)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isEmpty)
    }
}

private extension View {
    func managementRow() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 62)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
            .contentShape(.rect(cornerRadius: 17))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(.init(top: 5, leading: 2, bottom: 5, trailing: 2))
    }
}

@MainActor
private func managementIcon(_ icon: String) -> some View {
    Image(systemName: icon)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(amber)
        .frame(width: 38, height: 38)
        .background(amber.opacity(0.10), in: .rect(cornerRadius: 11))
        .accessibilityHidden(true)
}

@MainActor
private func archiveRow(_ title: String, icon: String, archive: LibraryStore.SaveArchive, action: String) -> some View {
    HStack(spacing: 12) {
        managementIcon(icon)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(cream).lineLimit(2)
            Text(archive.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: action).foregroundStyle(amber).accessibilityHidden(true)
    }
}

private struct ManagementPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(amber)
                .frame(width: 48, height: 48)
                .background(amber.opacity(0.13), in: .rect(cornerRadius: 13))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(cream)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 17).fill(panel)
            RoundedRectangle(cornerRadius: 17).fill(
                LinearGradient(colors: [amber.opacity(0.095), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            )
        }
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
    }
}

