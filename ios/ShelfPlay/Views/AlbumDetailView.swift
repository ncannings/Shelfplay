import SwiftUI

/// Result sheet after a scan (with alternatives) and the library detail page.
struct ResultSheet: View {
    let presentation: ResultPresentation
    var body: some View {
        NavigationStack {
            AlbumDetailView(album: presentation.album, presentation: presentation)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var album: AlbumResult
    var presentation: ResultPresentation?
    var fromLibrary = false

    @State private var tracks: [TrackRow] = []
    @State private var playing = false
    @State private var working: String?
    @State private var confirmDelete = false

    private var preferred: MusicService { model.settings.preferredService }
    private var other: MusicService { preferred == .appleMusic ? .spotify : .appleMusic }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                playControls
                if album.mbid != nil { editionCard }
                if let presentation, !presentation.alternatives.isEmpty { alternatives(presentation) }
                trackList
                if fromLibrary {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Remove from shelf", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !fromLibrary {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .confirmationDialog("Remove \(album.name) from your shelf?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.delete(album)
                dismiss()
            }
        }
        .task(id: album.libraryKey) { await loadTracks() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            CoverArt(url: album.imageLarge ?? album.image, cornerRadius: 14)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name).font(.title2.weight(.bold)).fontDesign(.serif)
                Text(album.artist).font(.headline).foregroundStyle(Theme.amber)
                HStack(spacing: 8) {
                    if !album.year.isEmpty { Text(album.year) }
                    Label(album.source == .cover ? "Cover" : album.source == .barcode ? "Barcode" : "Search",
                          systemImage: album.source == .cover ? "photo" : album.source == .barcode ? "barcode" : "magnifyingglass")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            }
            if let note = presentation?.note {
                Label(note, systemImage: note.contains("Apple Intelligence") ? "apple.intelligence" : "sparkles")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var playControls: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    working = "Starting…"
                    playing = await model.play(album)
                    working = nil
                }
            } label: {
                HStack {
                    if working != nil { ProgressView().tint(.black) }
                    else { Image(systemName: playing ? "waveform" : "play.fill") }
                    Text(playing ? "Playing" : playLabel)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            .disabled(working != nil)

            if preferred == .spotify, model.spotify.isConnected {
                spotifyDeviceMenu
            }

            HStack(spacing: 10) {
                ForEach([preferred, other]) { service in
                    Button { openIn(service) } label: {
                        Label(service.displayName, systemImage: "arrow.up.forward.app")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline.weight(.medium))
        }
    }

    private var playLabel: String {
        if preferred == .spotify, model.spotify.isConnected, !model.settings.spotifyDeviceName.isEmpty {
            return "Play on \(model.settings.spotifyDeviceName)"
        }
        if preferred == .spotify, !(model.spotify.isConnected && !model.settings.spotifyDeviceID.isEmpty) {
            return "Play in Spotify"
        }
        return "Play"
    }

    private var spotifyDeviceMenu: some View {
        Menu {
            ForEach(model.spotifyDevices) { d in
                Button {
                    model.settings.spotifyDeviceID = d.id
                    model.settings.spotifyDeviceName = d.name
                } label: {
                    if d.id == model.settings.spotifyDeviceID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
            Button("Refresh devices", systemImage: "arrow.clockwise") { Task { await model.refreshSpotifyDevices() } }
        } label: {
            Label(model.settings.spotifyDeviceName.isEmpty ? "Choose a speaker" : model.settings.spotifyDeviceName,
                  systemImage: "hifispeaker")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if model.spotifyDevices.isEmpty { await model.refreshSpotifyDevices() } }
    }

    private var editionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mismatch = album.mismatchDescription {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
            }
            Button {
                Task {
                    working = "Building…"
                    if let updated = await model.buildPlaylist(for: album, progress: { working = $0 }) {
                        album = updated
                        playing = true
                    }
                    working = nil
                }
            } label: {
                HStack {
                    Image(systemName: "list.number")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.matchedTracks == nil ? "Play your disc’s exact tracklist" : "Play matched tracklist")
                            .font(.subheadline.weight(.semibold))
                        Text(working ?? trackSummary)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
        }
    }

    private var trackSummary: String {
        if let m = album.matchedTracks {
            return "\(m.filter(\.found).count) of \(m.count) tracks matched"
        }
        return "Matches each track from MusicBrainz — for compilations and regional editions"
    }

    private func alternatives(_ presentation: ResultPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not this one?").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(presentation.alternatives) { alt in
                        Button { model.replace(album, with: alt, in: presentation) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CoverArt(url: alt.image).frame(width: 110)
                                Text(alt.name).font(.caption.weight(.semibold)).lineLimit(2)
                                Text(alt.artist).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .frame(width: 110, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trackList: some View {
        let rows: [TrackRow] = album.matchedTracks.map { m in
            m.enumerated().map { i, t in TrackRow(id: "\(i)", number: t.position ?? i + 1, title: t.title, durationMs: nil) }
        } ?? tracks
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tracks").font(.headline).padding(.bottom, 8)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 12) {
                        Text("\(t.number)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 24, alignment: .trailing)
                        Text(t.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        if let m = album.matchedTracks, i < m.count, !m[i].found {
                            Image(systemName: "xmark.circle").foregroundStyle(Theme.textSecondary).font(.caption)
                        }
                        Text(t.duration).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 9)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func loadTracks() async {
        guard album.matchedTracks == nil else { return }
        if let id = album.appleMusicID {
            tracks = await Catalog.appleMusicTracks(albumID: id)
        }
        if tracks.isEmpty, let uri = album.spotifyURI, model.spotify.isConnected {
            tracks = await model.spotify.albumTracks(uri: uri)
        }
        if tracks.isEmpty, album.appleMusicID == nil, let found = await Catalog.appleMusicAlbum(artist: album.artist, title: album.name),
           TextNormalizer.similarity(found.artist, album.artist) > 0.5 {
            album.merge(found)
            model.save(album)
            tracks = await Catalog.appleMusicTracks(albumID: found.appleMusicID ?? "")
        }
    }

    private func openIn(_ service: MusicService) {
        switch service {
        case .appleMusic: model.appleMusic.openInMusicApp(album)
        case .spotify: Task { await model.openInSpotify(album) }
        }
    }
}

struct EditionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let barcode: String
    let releases: [MBRelease]

    var body: some View {
        NavigationStack {
            List(releases) { rel in
                Button { Task { await model.pickRelease(rel, barcode: barcode) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rel.title).font(.headline)
                        Text(rel.artist).font(.subheadline).foregroundStyle(Theme.amber)
                        Text([rel.year, rel.format, rel.trackCount > 0 ? "\(rel.trackCount) tracks" : "", rel.country, rel.label]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Which edition?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [AlbumResult] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if searching { ProgressView().frame(maxWidth: .infinity) }
                ForEach(results) { album in
                    Button {
                        var a = album
                        a.source = .search
                        model.choose(a)
                    } label: {
                        HStack(spacing: 12) {
                            CoverArt(url: album.image, cornerRadius: 6).frame(width: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text([album.artist, album.year].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if results.isEmpty && !searching {
                    ContentUnavailableView("Find a record", systemImage: "magnifyingglass",
                                           description: Text("Search by artist and album, or type the barcode number."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artist, album or barcode")
            .onSubmit(of: .search) {
                Task {
                    searching = true
                    results = await model.searchCandidates(query)
                    searching = false
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
