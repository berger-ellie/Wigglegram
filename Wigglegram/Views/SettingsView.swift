import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet that lets the user swap the SHARP model. A drop zone accepts
/// `.mlpackage`, `.mlmodelc`, or `.mlmodel` bundles, which
/// `AppState.installSHARPModel` atomically copies into Application
/// Support and then reloads. Also shows the currently-loaded model's
/// on-disk path and a link out to Apple's Hugging Face release page.
///
/// Intentionally reuses `Theme` so it feels like part of the same app
/// rather than a stock SwiftUI form.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var isTargeted = false

    private static let huggingFaceURL = URL(
        string: "https://huggingface.co/pearsonkyle/Sharp-coreml"
    )!

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                header

                modelSection

                dropZone
                    .frame(height: 180)

                linksSection

                Spacer(minLength: 0)
            }
            .padding(32)
        }
        .frame(width: 560, height: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .tint(Theme.chrome)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETTINGS")
                .font(Theme.titleFont(size: 40))
                .foregroundStyle(Theme.chrome)
                .tracking(-0.5)
            Text("SHARP model, paths, and links.")
                .font(Theme.labelFont(size: 13))
                .foregroundStyle(Theme.label.opacity(0.6))
        }
    }

    // MARK: - Model status

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SHARP MODEL")

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.sharp.isModelLoaded
                      ? "checkmark.circle.fill"
                      : "circle.dashed")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(state.sharp.isModelLoaded
                                     ? Color.green
                                     : Theme.label.opacity(0.5))
                    .frame(width: 22, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelStatusLine)
                        .font(Theme.labelFont(size: 14))
                        .foregroundStyle(Theme.label)
                    if let path = state.sharp.currentModelURL?.path {
                        Text(path)
                            .font(Theme.labelFont(size: 11))
                            .foregroundStyle(Theme.label.opacity(0.6))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )

            if let msg = state.settingsMessage {
                Text(msg)
                    .font(Theme.labelFont(size: 12))
                    .foregroundStyle(Theme.label.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelStatusLine: String {
        if state.isInstallingModel { return "Installing new model…" }
        if case .loadingModel = state.stage { return "Loading model…" }
        if state.sharp.isModelLoaded {
            return "Model loaded."
        } else if case .failed(let m) = state.stage {
            return "Not loaded — \(m)"
        } else {
            return "No model loaded. Drop one below."
        }
    }

    // MARK: - Drop zone

    @ViewBuilder
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(isTargeted ? 0.10 : 0.04))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Theme.chrome : Color.white.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )

            VStack(spacing: 10) {
                if state.isInstallingModel {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.chrome)
                    Text("COPYING MODEL…")
                        .font(Theme.labelFont(size: 13))
                        .foregroundStyle(Theme.label)
                } else {
                    Image(systemName: "cube.box")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Theme.label.opacity(0.7))
                    Text("DROP .mlpackage / .mlmodelc / .mlmodel")
                        .font(Theme.labelFont(size: 13))
                        .foregroundStyle(Theme.label)
                    Button("CHOOSE FILE…") { pickModel() }
                        .buttonStyle(.bordered)
                        .tint(Theme.chrome)
                        .disabled(state.isInstallingModel)
                }
            }
            .padding(16)
        }
        .onDrop(
            of: [.fileURL, .package, .data],
            isTargeted: $isTargeted
        ) { providers in
            handleModelDrop(providers)
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DOWNLOAD")

            Link(destination: Self.huggingFaceURL) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .medium))
                    Text("pearsonkyle/Sharp-coreml on Hugging Face")
                        .font(Theme.labelFont(size: 13))
                    Spacer()
                }
                .foregroundStyle(Theme.chrome)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.labelFont(size: 12))
            .foregroundStyle(Theme.label.opacity(0.55))
            .tracking(1)
    }

    private func pickModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        // `.mlpackage` and `.mlmodelc` are directory bundles; Core ML
        // registers them as package types so passing them through
        // allowedContentTypes below lights them up in the picker. If
        // those UTTypes aren't resolvable at runtime (older SDKs) we
        // fall back to "any file" and validate by extension.
        var types: [UTType] = []
        for id in ["com.apple.coreml.mlpackage", "com.apple.coreml.mlmodelc", "com.apple.coreml.model"] {
            if let t = UTType(id) { types.append(t) }
        }
        panel.allowedContentTypes = types.isEmpty ? [.package, .data] : types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in await state.installSHARPModel(from: url) }
    }

    private func handleModelDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { reading, _ in
                guard let url = reading as URL? else { return }
                Task { @MainActor in await state.installSHARPModel(from: url) }
            }
            return true
        }
        // `.mlpackage` and `.mlmodelc` are directories — the SwiftUI
        // drop layer surfaces them as a file URL via
        // `public.file-url`. Fall through for any other representation
        // just so the drop completes rather than silently dying.
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let maybeURL: URL?
                if let u = item as? URL {
                    maybeURL = u
                } else if let data = item as? Data {
                    maybeURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    maybeURL = nil
                }
                guard let url = maybeURL else { return }
                Task { @MainActor in await state.installSHARPModel(from: url) }
            }
            return true
        }
        return false
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
