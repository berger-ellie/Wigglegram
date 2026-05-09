import SwiftUI
import AppKit

/// Plays a sequence of prerendered CGImages at a given fps using
/// ping-pong traversal: 0, 1, 2, …, N-1, N-2, …, 1, then repeats.
/// Falls back to `fallback` (the dropped source photo) when frames
/// is empty — so the user sees their photo immediately while SHARP /
/// the baker is working.
struct FramePlayerView: View {
    let frames: [CGImage]
    let fallback: NSImage?
    let fps: Int

    @State private var tick: Int = 0
    @State private var timerTask: Task<Void, Never>?

    private var displayedIndex: Int {
        let n = frames.count
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1)
        let t = ((tick % period) + period) % period
        return t < n ? t : period - t
    }

    var body: some View {
        ZStack {
            if frames.isEmpty {
                if let fallback {
                    Image(nsImage: fallback)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            } else {
                let i = min(displayedIndex, frames.count - 1)
                Image(decorative: frames[i], scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: frames.count) { _, _ in
            tick = 0
            restartTimer()
        }
        .onChange(of: fps) { _, _ in restartTimer() }
    }

    // MARK: - Playback timer

    private func startTimer() {
        stopTimer()
        let f = max(1, fps)
        timerTask = Task { @MainActor in
            let nanos = UInt64(1_000_000_000 / f)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                tick &+= 1
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func restartTimer() {
        stopTimer()
        startTimer()
    }
}
