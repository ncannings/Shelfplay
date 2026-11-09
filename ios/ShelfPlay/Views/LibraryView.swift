import SwiftData
import SwiftUI

struct LibraryView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent", artist = "Artist", title = "Title"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ShelfAlbum.scannedAt, order: .reverse) private var albums: [ShelfAlbum]
    @State private var search = ""
    @State private var sort: Sort = .recent
    @State private var syncing = false

    private var filtered: [ShelfAlbum] {
        let q = search.lowercased()
        let list = q.isEmpty ? albums : albums.filter { $0.name.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
        switch sort {
        case .recent: return list
        case .artist: return list.sorted { ($0.artist.lowercased(), $0.year) < ($1.artist.lowercased(), $1.year) }
        case .title: return list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(filtered) { item in
                        NavigationLink(value: item.key) {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverArt(url: item.imageURL)
                                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(item.artist).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .overlay {
                if albums.isEmpty {
                    ContentUnavailableView("Your shelf is empty", systemImage: "opticaldisc",
                                           description: Text("Scan a barcode or a cover to add records."))
                }
            }
            .searchable(text: $search, prompt: "Search your shelf")
            .navigationTitle("Shelf · \(albums.count)")
            .navigationDestination(for: String.self) { key in
                if let item = albums.first(where: { $0.key == key }) {
                    AlbumDetailView(album: item.result, fromLibrary: true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !model.settings.familyCode.isEmpty {
                        Button {
                            Task {
                                syncing = true
                                model.show(await model.syncNow())
                                syncing = false
                            }
                        } label: {
                            if syncing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                        }
                        .accessibilityLabel("Sync family shelf")
                    }
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel("Sort")
                }
            }
        }
    }
}
