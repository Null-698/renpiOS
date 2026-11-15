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
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.08)).allowsHitTesting(false) }
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
    @State private var installed: String?
    @State private var importing = false
    @State private var pending: URL?
    @State private var conflicts = 0
    @State private var removing = false
    @Binding var working: Bool
    @State private var message: String?

    var body: some View {
        ScrollView {
            ManagementPanel(installed ?? "Install a mod", icon: "puzzlepiece.extension") {
                if installed != nil {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(amber)
                    Button("Remove Mod", systemImage: "trash", role: .destructive) { removing = true }
                        .buttonStyle(.glass)
                        .disabled(working)
                } else {
                    Text("Choose a ZIP from Files.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Choose Mod ZIP", systemImage: "folder") { importing = true }
                        .buttonStyle(.glassProminent)
                        .disabled(working)
                }
                if working { ProgressView().accessibilityLabel("Working on mod") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .confirmationDialog("Install this mod?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("Install") {
                if let pending {
                    run {
                        let replaced = try LibraryStore.installMod(pending, on: novel)
                        return replaced == 0 ? "Mod installed." : "Mod installed. Replaced \(replaced) files."
                    }
                }
            }
        } message: {
            Text(conflicts == 0 ? "No existing files will be replaced." : "\(conflicts) existing files will be replaced. You can restore the original files from Mods.")
        }
        .confirmationDialog("Restore original files?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Mod", role: .destructive) {
                run { try LibraryStore.removeMod(from: novel); return "Original files restored." }
            }
        }
        .onAppear { installed = LibraryStore.installedMod(for: novel) }
    }

    private func run(_ action: @escaping @Sendable () throws -> String) {
        working = true
        Task {
            defer { working = false; installed = LibraryStore.installedMod(for: novel) }
            do { message = try await Task.detached(priority: .userInitiated, operation: action).value }
            catch { message = error.localizedDescription }
        }
    }
}

struct SaveExportTab: View {
    let novel: Novel
    @Binding var working: Bool
    @State private var backup: URL?
    @State private var message: String?

    var body: some View {
        ScrollView {
            ManagementPanel("Export saves", icon: "square.and.arrow.up") {
                Text("Package this game’s saves into a ZIP.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let backup {
                    ShareLink(item: backup) { Label("Share ZIP", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Create Backup", systemImage: "archivebox") { export() }
                        .buttonStyle(.glassProminent)
                        .disabled(working)
                }
                if working { ProgressView().accessibilityLabel("Creating backup") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export() {
        working = true
        message = nil
        let game = novel
        Task {
            defer { working = false }
            do {
                backup = try await Task.detached(priority: .userInitiated) { try LibraryStore.backup(game) }.value
            } catch { message = error.localizedDescription }
        }
    }
}

struct SaveRestoreTab: View {
    let novel: Novel
    let session: Session
    @State private var choosing = false
    @State private var pending: URL?
    @State private var confirming = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            ManagementPanel("Restore saves", icon: "arrow.down.to.line") {
                Text("Choose a save backup ZIP from Files.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Choose Backup ZIP", systemImage: "folder") { choosing = true }
                    .buttonStyle(.glassProminent)
                    .disabled(session.isImporting)
                if session.isImporting { ProgressView().accessibilityLabel("Restoring saves") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let file):
                pending = file
                confirming = true
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog("Restore saves?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Keep Existing Saves") { restore(replacing: false) }
            Button("Replace Matching Saves", role: .destructive) { restore(replacing: true) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let pending { Text(pending.lastPathComponent) }
        }
    }

    private func restore(replacing: Bool) {
        guard let archive = pending else { return }
        pending = nil
        message = nil
        Task {
            do {
                let count = try await session.restore(archive, to: novel, replacing: replacing)
                message = count == 0 ? "All matching saves were kept." : "Restored \(count) save file(s)."
            } catch { message = error.localizedDescription }
        }
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
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.09)).allowsHitTesting(false) }
    }
}
