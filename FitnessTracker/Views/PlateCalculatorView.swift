import SwiftUI

/// What to put on the bar.
struct PlateCalculatorView: View {
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss

    /// The weight to make, in kilograms.
    let target: Double

    @AppStorage(AthleteProfile.Key.barWeightKg) private var storedBar: Double = 0

    private var bar: Double {
        storedBar > 0 ? storedBar : PlateMath.bar(metric: units.system == .metric)
    }

    private var loading: PlateMath.Loading {
        PlateMath.load(target: target, bar: bar,
                       inventory: PlateMath.inventory(metric: units.system == .metric))
    }

    /// A plate's own denomination: "35 lb", "1.25 kg". Fixed decimals can't do
    /// both — two of them turns a 35 lb plate into "35.00 lb", and none of them
    /// turns a 1.25 kg plate into "1 kg".
    private func plateName(_ kilograms: Double) -> String {
        let value = units.system == .metric
            ? kilograms
            : kilograms / UnitConversion.kilogramsPerPound
        let rounded = (value * 100).rounded() / 100
        let number = rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%g", rounded)
        return number + " " + units.weightUnit
    }

    private var perSideTotal: Double {
        loading.perSide.reduce(0) { $0 + $1.kilograms * Double($1.count) }
    }

    private var barBinding: Binding<Double> {
        Binding(
            get: { units.displayedWeight(fromKilograms: bar) },
            set: { storedBar = units.kilograms(fromDisplayed: $0) }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Target", value: units.weight(target, decimals: 1))
                    LabeledContent("On the bar", value: units.weight(loading.total, decimals: 1))
                        .foregroundStyle(loading.isExact ? Color.primary : Color.orange)
                } footer: {
                    if !loading.isExact {
                        Text("\(units.weight(loading.shortfall, decimals: 2)) short — that's the closest this plate set can make without going over.")
                    }
                }

                Section("Each side") {
                    if loading.isBarOnly {
                        Text("Bar only.").foregroundStyle(.secondary)
                    } else {
                        BarDiagram(loading: loading, units: units)
                            .frame(height: 70)
                        ForEach(loading.perSide, id: \.kilograms) { stack in
                            LabeledContent(plateName(stack.kilograms),
                                           value: "× \(stack.count)")
                        }
                        LabeledContent("Per side",
                                       value: units.weight(perSideTotal, decimals: 1))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Text("Bar")
                        Spacer()
                        Text(units.weight(bar, decimals: 1)).foregroundStyle(.secondary)
                    }
                    Slider(value: barBinding,
                           in: units.system == .metric ? 5...35 : 10...80,
                           step: units.system == .metric ? 2.5 : 5)
                } footer: {
                    Text("An Olympic bar is \(units.system == .metric ? "20 kg" : "45 lb"); women's bars are \(units.system == .metric ? "15 kg" : "35 lb"), and a training bar can be 10.")
                }
            }
            .navigationTitle("Plates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One end of the bar, drawn to scale.
///
/// The picture is the point: between sets you glance at a shape, you don't read
/// a table. Bar heights follow real plates, so the 25s look like 25s.
private struct BarDiagram: View {
    let loading: PlateMath.Loading
    let units: UnitFormatter

    private var heaviest: Double {
        loading.perSide.map(\.kilograms).max() ?? 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            // The sleeve, so the plates are clearly on something.
            RoundedRectangle(cornerRadius: 1)
                .fill(.secondary)
                .frame(width: 16, height: 7)
                .padding(.bottom, 26)

            ForEach(Array(plateList.enumerated()), id: \.offset) { _, kilograms in
                VStack(spacing: 3) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.tint)
                        // Floor of 40% so a 1.25 next to a 25 is still visible
                        // rather than a sliver.
                        .frame(height: 44 * (0.4 + 0.6 * (kilograms / heaviest)))
                    // Below the plate, horizontal. Rotated text inside an
                    // 11-point-wide plate was clipped to its last characters,
                    // so a 35 read as "5.00".
                    Text(label(for: kilograms))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 26)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleDescription)
    }

    /// Heaviest at the collar outwards, which is loading order.
    private var plateList: [Double] {
        loading.perSide.flatMap { Array(repeating: $0.kilograms, count: $0.count) }
    }

    private func label(for kilograms: Double) -> String {
        let value = units.system == .metric
            ? kilograms
            : kilograms / UnitConversion.kilogramsPerPound
        // Round before asking whether it's whole. A 35 lb plate is stored as
        // 15.87573295 kg and converts back to 35.000000000000004, which is not
        // equal to 35 and so printed as "35.00".
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%g", rounded)
    }

    private var accessibleDescription: String {
        let parts = loading.perSide.map {
            "\($0.count) × \(units.weight($0.kilograms, decimals: 2))"
        }
        return "Each side: " + parts.joined(separator: ", ")
    }
}
