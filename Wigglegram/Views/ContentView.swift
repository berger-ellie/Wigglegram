import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var coordinator: SplatViewer.Coordinator?
    @State private var liveCamera: CameraPose = .default
    @State private var animationTimer: Timer?
    @State private var exportTask: Task<Void, Never>?
    @State private var isTargeted = false

    var body: some View {
        @Bindable var state = state
        HSplitView {
            viewer
                .frame(minWidth: 500)
                .layoutPriority(1)
            controls
                .frame(minWidth: 280, idealWidth: 320)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if case .displaying = state.stage {
                    Button("Open New Photo…", systemImage: "photo.badge.plus") {
                        pickPhoto()
                    }
                }
            }
        }
        .onAppear { startAnimationTimer() }
        .onDisappear {
            animationTimer?.invalidate()
            animationTimer = nil
            exportTask?.cancel()
        }
    }

    // MARK: - Viewer

    @ViewBuilder
    private var viewer: some View {
        ZStack {
            if let url = state.splatURL {
                SplatViewer(plyURL: url, camera: .constant(liveCamera)) { coord in
                    self.coordinator = coord
                }
                .ignoresSafeArea()
            } else {
                dropZone
            }

            if state.stage.isBusy {
                busyOverlay
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left.filled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop a photo")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(state.stage.label)
                .font(.callout)
                .foregroundStyle(.tertiary)
            if case .ready = state.stage {
                Button("Choose Photo…") { pickPhoto() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            } else if case .failed = state.stage {
                Button("Retry Model Load") {
                    Task { await state.warmUpModel() }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .padding(32)
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(state.stage.label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Wiggle")
                    .font(.headline)

                Picker("Style", selection: $state.wiggle.style) {
                    ForEach(WiggleSettings.Style.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                slider(
                    "Amplitude",
                    value: $state.wiggle.amplitudeDegrees,
                    in: 0.5...15,
                    suffix: "°"
                )
                stepper(
                    "Frames",
                    value: $state.wiggle.frameCount,
                    in: 6...120,
                    suffix: ""
                )
                stepper(
                    "FPS",
                    value: $state.wiggle.fps,
                    in: 10...60,
                    suffix: " fps"
                )

                Divider()

                Text("Camera")
                    .font(.headline)
                slider("Distance", value: $state.camera.distance, in: 0.2...8, suffix: "")
                slider("Pitch", value: bindingFromRadians($state.camera.pitch),
                       in: -45...45, suffix: "°")
                slider("FoV", value: bindingFromRadians($state.camera.fovY),
                       in: 20...90, suffix: "°")

                Divider()

                Text("Export")
                    .font(.headline)
                HStack {
                    Button("Export MP4…") { exportTapped(format: .mp4) }
                        .disabled(!canExport)
                    Button("Export GIF…") { exportTapped(format: .gif) }
                        .disabled(!canExport)
                }

                if case .exporting(let p) = state.stage {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                }

                if case .failed(let msg) = state.stage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var canExport: Bool {
        state.splatURL != nil && coordinator != nil && !state.stage.isBusy
    }

    // MARK: - Slider helpers

    private func slider(
        _ title: String,
        value: Binding<Float>,
        in range: ClosedRange<Float>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: "%.2f\(suffix)", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func stepper(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Stepper("\(value.wrappedValue)\(suffix)",
                    value: value, in: range)
                .labelsHidden()
            Text("\(value.wrappedValue)\(suffix)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
    }

    private func bindingFromRadians(_ source: Binding<Float>) -> Binding<Float> {
        Binding(
            get: { source.wrappedValue * 180.0 / .pi },
            set: { source.wrappedValue = $0 * .pi / 180.0 }
        )
    }

    // MARK: - Drop / pick

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { reading, _ in
            if let url = reading as URL? {
                Task { @MainActor in
                    await state.processImage(at: url)
                }
            }
        }
        return true
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

    // MARK: - Animation timer (drives the live wiggle)

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                tick()
            }
        }
    }

    @MainActor
    private func tick() {
        guard case .displaying = state.stage else {
            liveCamera = state.camera
            return
        }
        let elapsed = Float(Date().timeIntervalSince(state.animationStart))
        // One full loop takes frameCount / fps seconds.
        let period = Float(state.wiggle.frameCount) / Float(max(state.wiggle.fps, 1))
        let t = elapsed.truncatingRemainder(dividingBy: period) / period
        liveCamera = state.wiggle.pose(at: t, base: state.camera)
    }

    // MARK: - Export

    private func exportTapped(format: WiggleExporter.Format) {
        guard let coord = coordinator else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .mp4 ? [.mpeg4Movie] : [.gif]
        panel.nameFieldStringValue = (state.sourceImageURL?.deletingPathExtension().lastPathComponent ?? "wiggle")
            + (format == .mp4 ? ".mp4" : ".gif")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exportTask?.cancel()
        exportTask = Task { @MainActor in
            state.stage = .exporting(progress: 0)
            do {
                try await WiggleExporter.export(
                    settings: state.wiggle,
                    base: state.camera,
                    coordinator: coord,
                    to: url,
                    config: .init(width: 1024, height: 1024, format: format)
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

#Preview {
    ContentView()
        .environment(AppState())
}
