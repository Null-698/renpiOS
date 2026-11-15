import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SaveManager: View {
    @Environment(\.dismiss) private var dismiss
    let novel: Novel
    @State private var slots: [LibraryStore.SaveSlot] = []
    @State private var selected: LibraryStore.SaveSlot?
    @State private var naming: LibraryStore.SaveSlot?
    @State private var name = ""
    @State private var labels: [String: String] = [:]
    @State private var message: String?

    private var labelsFile: URL { novel.saves.appending(path: ".renios-slot-labels.json") }

    var body: some View {
        NavigationStack {
            List {
                ForEach(slots) { slot in
                    SaveSlotRow(slot: slot, title: labels[slot.id] ?? slot.url.deletingPathExtension().lastPathComponent)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                name = labels[slot.id] ?? ""
                                naming = slot
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                perform { try LibraryStore.duplicate(slot) }
                            }
                            ShareLink(item: slot.url) { Label("Export Slot", systemImage: "square.and.arrow.up") }
                            Button("Delete Slot", systemImage: "trash", role: .destructive) { selected = slot }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { selected = slot }
                        }
                }
            }
            .overlay {
                if slots.isEmpty { ContentUnavailableView("No Save Slots", systemImage: "archivebox") }
            }
            .navigationTitle("Save Manager")
            .toolbar { Button("Done") { dismiss() } }
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

private struct SaveSlotRow: View {
    let slot: LibraryStore.SaveSlot
    let title: String
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 86, height: 54)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(slot.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: slot.date) {
            image = LibraryStore.thumbnail(for: slot).flatMap { UIImage(data: $0) }
        }
    }
}

struct ModManager: View {
    @Environment(\.dismiss) private var dismiss
    let novel: Novel
    @State private var installed: String?
    @State private var importing = false
    @State private var pending: URL?
    @State private var conflicts = 0
    @State private var removing = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let installed {
                    Label(installed, systemImage: "puzzlepiece.extension")
                    Button("Remove and Restore Original Files", role: .destructive) { removing = true }
                        .disabled(working)
                } else {
                    Button("Install Mod ZIP", systemImage: "plus") { importing = true }.disabled(working)
                }
                if working { ProgressView() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("Mods")
            .toolbar { Button("Done") { dismiss() }.disabled(working) }
            .interactiveDismissDisabled(working)
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
