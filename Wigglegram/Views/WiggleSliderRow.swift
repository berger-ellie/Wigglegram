import SwiftUI

/// A single Figma-style labeled slider row:
///
///     FRAME DISTANCE  ─────●────  3
///
/// Label on the left (fixed width, uppercase, monospaced), horizontal
/// track in the middle, value readout on the right.
struct WiggleSliderRow: View {
    let label: String
    let binding: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    /// How to render the numeric readout. Defaults to `%.0f`.
    let formatter: (Double) -> String

    init(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        formatter: @escaping (Double) -> String = { String(format: "%.0f", $0) }
    ) {
        self.label = label
        self.binding = value
        self.range = range
        self.step = step
        self.formatter = formatter
    }

    /// Float convenience — the camera/wiggle state uses `Float`.
    init(
        _ label: String,
        value: Binding<Float>,
        in range: ClosedRange<Float>,
        step: Float? = nil,
        formatter: @escaping (Double) -> String = { String(format: "%.0f", $0) }
    ) {
        self.label = label
        self.binding = Binding(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Float($0) }
        )
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = step.map(Double.init)
        self.formatter = formatter
    }

    /// Int convenience — frame count / fps.
    init(
        _ label: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        formatter: @escaping (Double) -> String = { String(format: "%.0f", $0) }
    ) {
        self.label = label
        self.binding = Binding(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0.rounded()) }
        )
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = 1
        self.formatter = formatter
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(Theme.labelFont(size: 18))
                .foregroundStyle(Theme.label)
                .frame(width: 180, alignment: .leading)
                .fixedSize()

            slider

            Text(formatter(binding.wrappedValue))
                .font(Theme.labelFont(size: 18))
                .foregroundStyle(Theme.label)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: binding, in: range, step: step)
                .tint(Theme.thumb)
        } else {
            Slider(value: binding, in: range)
                .tint(Theme.thumb)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var distance: Float = 3
        @State var frames: Int = 30
        var body: some View {
            VStack(spacing: 8) {
                WiggleSliderRow("FRAME DISTANCE", value: $distance, in: 0.2...8,
                                formatter: { String(format: "%.1f", $0) })
                WiggleSliderRow("FRAME COUNT", value: $frames, in: 6...120)
            }
            .padding(40)
            .frame(width: 520)
            .background(Theme.background)
        }
    }
    return PreviewWrapper()
}
