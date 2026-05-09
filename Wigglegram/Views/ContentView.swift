import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var exportTask: Task<Void, Never>?
    @State private var isTargeted = false

    var body: some View {
        @Bindable var state = state
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 40)
                    .padding(.top, 40)
                    .padding(.bottom, 12)

                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 12) {
                        previewFrame
                            .frame(width: 520, height: 620)
                        statusStrip
                            .frame(width: 520)
                    }

                    controlsColumn
                        .frame(minWidth: 440, maxWidth: .infinity)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)

                Spacer(minLength: 0)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open Photo…", systemImage: "photo.badge.plus") {
                    pickPhoto()
                }
                .tint(Theme.chrome)
            }
        }
        .onDisappear { exportTask?.cancel() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            Text("SHARP WIGGLES")
                .font(Theme.titleFont(size: 72))
                .foregroundStyle(Theme.chrome)
                .tracking(-1)
            Spacer()
            RainbowChip()
        }
    }

    // MARK: - Preview frame

    @ViewBuilder
    private var previewFrame: some View {
        ZStack {
            Color.black

            if state.frames.isEmpty && state.sourceImage == nil {
                dropZoneContents
            } else {
                FramePlayerView(
                    frames: state.frames,
                    fallback: state.sourceImage,
                    fps: state.wiggle.playbackFps
                )
                .padding(8)
            }

            if isTargeted {
                RoundedRectangle(cornerRadius: Theme.frameCornerRadius)
                    .inset(by: 18)
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.frameCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.frameCornerRadius)
                .strokeBorder(Theme.chrome, lineWidth: Theme.frameStroke)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.frameCornerRadius))
        // Accept fileURL + image + explicit raster UTIs. SwiftUI drops
        // that come from non-file sources (Photos, Safari) surface a
        // data-representation rather than a URL, so we need both.
        .onDrop(
            of: [.fileURL, .image, .png, .jpeg, .heic, .heif, .tiff],
            isTargeted: $isTargeted
        ) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var dropZoneContents: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.and.hand.point.up.left.filled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.label.opacity(0.6))
            Text("DROP A PHOTO")
                .font(Theme.labelFont(size: 22))
                .foregroundStyle(Theme.label)
            Text("OR USE CHOOSE PHOTO…")
                .font(Theme.labelFont(size: 12))
                .foregroundStyle(Theme.label.opacity(0.5))
            Button("CHOOSE PHOTO…") { pickPhoto() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.chrome)
                .foregroundStyle(.black)
                .padding(.top, 8)
            if case .failed = state.stage {
                Button("RETRY MODEL LOAD") {
                    Task { await state.warmUpModel() }
                }
                .buttonStyle(.bordered)
                .tint(Theme.chrome)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.frameCornerRadius)
                .inset(by: 18)
                .strokeBorder(Color.white.opacity(0.25),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
    }

    // MARK: - Status strip (below the frame)

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 10) {
            if state.stage.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.chrome)
            }
            Text(state.stage.label.uppercased())
                .font(Theme.labelFont(size: 12))
                .foregroundStyle(Theme.label.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
    }

    // MARK: - Controls column

    @ViewBuilder
    private var controlsColumn: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                frameDistanceRow

                WiggleSliderRow(
                    "Frame Count",
                    value: $state.wiggle.frameCount,
                    in: 2...15
                )

                WiggleSliderRow(
                    "Wiggle Speed",
                    value: $state.wiggle.cycleHz,
                    in: 0.5...8,
                    formatter: { String(format: "%.1f Hz", $0) }
                )
            }

            styleRow
                .padding(.top, 12)

            Spacer(minLength: 24)

            exportRow

            if case .exporting(let p) = state.stage {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(Theme.exportRed)
            }

            if case .failed(let msg) = state.stage {
                Text(msg)
                    .font(Theme.labelFont(size: 13))
                    .foregroundStyle(Theme.exportRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 40)
    }

    /// Single cm-based slider for `frameDistance`. We expose a
    /// computed binding so the slider value is centimeters (0.5 - 12)
    /// while `WiggleSettings.frameDistance` stays in meters.
    @ViewBuilder
    private var frameDistanceRow: some View {
        @Bindable var state = state
        let cm = Binding<Float>(
            get: { state.wiggle.frameDistance * 100 },
            set: { state.wiggle.frameDistance = $0 / 100 }
        )
        WiggleSliderRow(
            "Frame Distance",
            value: cm,
            in: 0.5...12,
            formatter: { String(format: "%.1f cm", $0) }
        )
    }

    // MARK: - Style row

    @ViewBuilder
    private var styleRow: some View {
        @Bindable var state = state
        HStack(alignment: .center, spacing: 12) {
            Text("STYLE")
                .font(Theme.labelFont(size: 18))
                .foregroundStyle(Theme.label)
                .frame(width: 180, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(WiggleSettings.Style.allCases) { s in
                    styleButton(style: s, selected: state.wiggle.style == s)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func styleButton(style: WiggleSettings.Style, selected: Bool) -> some View {
        Button {
            state.wiggle.style = style
        } label: {
            VStack(spacing: 4) {
                Image(systemName: glyph(for: style))
                    .font(.system(size: 16, weight: .medium))
                Text(style.label.uppercased())
                    .font(Theme.labelFont(size: 10))
            }
            .frame(width: 72, height: 56)
            .foregroundStyle(selected ? Color.black : Theme.label)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Theme.chrome : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Theme.chrome : Color.white.opacity(0.25),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func glyph(for style: WiggleSettings.Style) -> String {
        switch style {
        case .shiftHorizontal: "arrow.left.and.right"
        case .shiftVertical: "arrow.up.and.down"
        case .rotateHorizontal: "arrow.triangle.2.circlepath"
        case .rotateVertical: "arrow.triangle.2.circlepath.camera"
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportRow: some View {
        HStack {
            Spacer()
            exportButton
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        Button {
            exportTapped(format: .mp4)
        } label: {
            Text("EXPORT")
                .font(Theme.exportFont(size: 44))
                .foregroundStyle(Theme.exportLabel)
                .frame(width: 224, height: 75)
                .background(
                    RoundedRectangle(cornerRadius: Theme.exportCornerRadius)
                        .fill(Theme.exportRed)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.exportCornerRadius)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        .blendMode(.overlay)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!canExport)
        .opacity(canExport ? 1 : 0.45)
        .contextMenu {
            Button("Export MP4…") { exportTapped(format: .mp4) }
                .disabled(!canExport)
            Button("Export GIF…") { exportTapped(format: .gif) }
                .disabled(!canExport)
        }
    }

    private var canExport: Bool {
        !state.frames.isEmpty && !state.stage.isBusy
    }

    // MARK: - Drop / pick

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // 1. File URL (Finder / Photos.app when exported to disk).
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { reading, _ in
                if let url = reading as URL? {
                    Task { @MainActor in await state.processImage(at: url) }
                }
            }
            return true
        }

        // 2. File representation — writes a temp file we control.
        for uti in ["public.file-url", "public.jpeg", "public.png",
                    "public.heic", "public.heif", "public.tiff", "public.image"] {
            if provider.hasItemConformingToTypeIdentifier(uti) {
                provider.loadFileRepresentation(forTypeIdentifier: uti) { url, _ in
                    guard let url else { return }
                    if let copied = try? copyToTemp(url: url) {
                        Task { @MainActor in await state.processImage(at: copied) }
                    }
                }
                return true
            }
        }

        // 3. Raw data — write ourselves.
        for uti in ["public.jpeg", "public.png", "public.heic",
                    "public.heif", "public.tiff", "public.image"] {
            if provider.hasItemConformingToTypeIdentifier(uti) {
                provider.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                    guard let data,
                          let ext = extForUTI(uti),
                          let tmp = writeTemp(data: data, ext: ext) else { return }
                    Task { @MainActor in await state.processImage(at: tmp) }
                }
                return true
            }
        }

        return false
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic, .heif, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await state.processImage(at: url)
        }
    }

    // MARK: - Export pipeline

    private func exportTapped(format: WiggleExporter.Format) {
        guard !state.frames.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .mp4 ? [.mpeg4Movie] : [.gif]
        panel.nameFieldStringValue = (state.sourceImageURL?.deletingPathExtension().lastPathComponent ?? "wiggle")
            + (format == .mp4 ? ".mp4" : ".gif")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let frames = state.frames
        let fps = state.wiggle.playbackFps

        exportTask?.cancel()
        exportTask = Task { @MainActor in
            state.stage = .exporting(progress: 0)
            do {
                try await WiggleExporter.export(
                    frames: frames,
                    fps: fps,
                    format: format,
                    to: url
                ) { p in
                    state.stage = .exporting(progress: p)
                }
                state.stage = .displaying
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                state.stage = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Drop helpers (free functions)

private func copyToTemp(url: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WigglegramDrop", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
    let out = dir.appendingPathComponent("\(UUID().uuidString.prefix(6)).\(ext)")
    try FileManager.default.copyItem(at: url, to: out)
    return out
}

private func writeTemp(data: Data, ext: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WigglegramDrop", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("\(UUID().uuidString.prefix(6)).\(ext)")
    do {
        try data.write(to: out)
        return out
    } catch { return nil }
}

private func extForUTI(_ uti: String) -> String? {
    switch uti {
    case "public.jpeg": "jpg"
    case "public.png": "png"
    case "public.heic": "heic"
    case "public.heif": "heif"
    case "public.tiff": "tiff"
    case "public.image": "img"
    default: nil
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 1200, height: 900)
}
