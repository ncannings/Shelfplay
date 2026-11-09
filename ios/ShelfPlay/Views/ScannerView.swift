import PhotosUI
import SwiftUI

struct ScannerView: View {
    @Environment(AppModel.self) private var model
    @State private var camera = CameraController()
    @State private var cameraRunning = false
    @State private var cameraChecked = false
    @State private var photoItem: PhotosPickerItem?
    @State private var flash = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.background.ignoresSafeArea()
            if cameraRunning {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else if cameraChecked {
                noCamera
            }
            if cameraRunning { viewfinder }
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomControls
            }
            if let busy = model.busyMessage { BusyOverlay(message: busy) }
            if flash { Color.white.opacity(0.6).ignoresSafeArea().allowsHitTesting(false) }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 170).padding(.horizontal, 16)
                        .multilineTextAlignment(.center)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: model.busyMessage)
        .task {
            camera.onBarcode = { code in
                guard model.mode == .barcode, !model.scannerPaused else { return }
                Task { await model.handleBarcode(code) }
            }
            cameraRunning = await camera.start()
            cameraChecked = true
            #if DEBUG
            // Debug hook for headless testing: -ShelfPlayCoverTest /path/to/cover.jpg
            if let path = UserDefaults.standard.string(forKey: "ShelfPlayCoverTest"), let image = UIImage(contentsOfFile: path) {
                await model.identifyCover(image)
            }
            if let code = UserDefaults.standard.string(forKey: "ShelfPlayBarcodeTest") {
                await model.handleBarcode(code)
            }
            #endif
        }
        .onChange(of: model.mode) { _, mode in
            camera.detectsBarcodes = mode == .barcode
            model.status = mode == .barcode ? "Point at a barcode" : "Fill the square with the cover"
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await model.identifyCover(image)
                }
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .result(let presentation): ResultSheet(presentation: presentation)
            case .editions(let barcode, let releases): EditionsSheet(barcode: barcode, releases: releases)
            case .search: SearchSheet()
            case .library: LibraryView()
            case .settings: SettingsView()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Wordmark()
            Spacer()
            Text(model.status)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            let w = geo.size.width - 64
            let size = model.mode == .cover ? CGSize(width: w, height: w) : CGSize(width: w, height: w * 0.45)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: model.mode == .cover ? [] : [14, 8]))
                .frame(width: size.width, height: size.height)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.45)
                .animation(.spring(duration: 0.35), value: model.mode)
        }
        .allowsHitTesting(false)
    }

    private var bottomControls: some View {
        @Bindable var model = model
        return VStack(spacing: 18) {
            Picker("Mode", selection: $model.mode) {
                ForEach(ScanMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            HStack {
                CircleButton(systemImage: "square.stack", label: "Library") { model.sheet = .library }
                Spacer()
                if model.mode == .cover {
                    Button(action: capture) {
                        ZStack {
                            Circle().fill(Theme.amberGradient).frame(width: 72, height: 72)
                            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).frame(width: 84, height: 84)
                        }
                    }
                    .disabled(!cameraRunning || model.isBusy)
                    .accessibilityLabel("Identify cover")
                } else {
                    CircleButton(systemImage: "magnifyingglass", label: "Search", size: 64) { model.sheet = .search }
                }
                Spacer()
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Identify a cover photo")
            }
            .padding(.horizontal, 32)

            HStack {
                Spacer()
                Button { model.sheet = .settings } label: {
                    Label("Settings", systemImage: "gearshape").font(.footnote.weight(.medium))
                }
                .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
        .padding(.bottom, 12)
        .padding(.top, 16)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var noCamera: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text("Camera unavailable")
                .font(.headline)
            Text("Pick a cover photo or search by name.\nTo scan, allow camera access in iOS Settings.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func capture() {
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            flash = false
        }
        Task {
            if let image = await camera.capturePhoto() { await model.identifyCover(image) }
        }
    }
}

struct CircleButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Theme.amber)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
