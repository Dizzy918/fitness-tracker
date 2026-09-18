import SwiftUI
import SwiftData
import Charts
import PhotosUI

/// Tape measurements and progress photos.
struct BodyCompositionView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context

    @Query(sort: \BodyMeasurement.date, order: .reverse)
    private var measurements: [BodyMeasurement]
    @Query(sort: \ProgressPhoto.date, order: .reverse)
    private var photos: [ProgressPhoto]

    @State private var editing: BodyMeasurement?
    @State private var chartSite: BodyMeasurement.Site = .waist
    @State private var windowDays = 90
    @State private var photoError: String?

    private static let windows = [(30, "30d"), (90, "90d"), (365, "1y"), (0, "All")]

    private var windowStart: Date? {
        guard windowDays > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)
    }

    private var changes: [MeasurementTrend.Change] {
        MeasurementTrend.changes(in: measurements, since: windowStart)
    }

    /// Sites with enough history to chart, so the picker can't offer a blank.
    private var chartableSites: [BodyMeasurement.Site] {
        BodyMeasurement.Site.allCases.filter {
            MeasurementTrend.series(for: $0, in: measurements).count >= 2
        }
    }

    var body: some View {
        List {
            if measurements.isEmpty && photos.isEmpty {
                emptyState
            } else {
                if !changes.isEmpty { trendSection }
                if !chartableSites.isEmpty { chartSection }
                photoSection
                if !measurements.isEmpty { historySection }
            }
        }
        .navigationTitle("Body")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addMeasurement() } label: {
                    Label("Add measurements", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { BodyMeasurementEditor(measurement: $0) }
        .alert("Couldn't add that photo", isPresented: Binding(
            get: { photoError != nil }, set: { if !$0 { photoError = nil } }
        )) {
            Button("OK") { photoError = nil }
        } message: {
            Text(photoError ?? "")
        }
        .onAppear {
            if !chartableSites.contains(chartSite), let first = chartableSites.first {
                chartSite = first
            }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("Nothing measured yet", systemImage: "figure.arms.open")
            } description: {
                Text("Weight moves several kilos on water and can't tell muscle from anything else. A waist and an arm can, and a photo every few weeks answers it outright.")
            } actions: {
                VStack(spacing: 10) {
                    Button("Add measurements") { addMeasurement() }
                        .buttonStyle(.borderedProminent)
                    PhotoAddButton(label: "Add a photo") { data in
                        add(photoData: data, pose: .front)
                    }
                }
            }
        }
    }

    private var trendSection: some View {
        Section {
            Picker("Window", selection: $windowDays) {
                ForEach(Self.windows, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)

            ForEach(changes) { change in
                ChangeRow(change: change, units: units)
            }
        } header: {
            Text("Change")
        } footer: {
            Text("Each site is compared between its own first and last reading in the window — you probably measure your waist more often than your calves.")
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        let series = MeasurementTrend.series(for: chartSite, in: measurements)
        Section {
            Picker("Site", selection: $chartSite) {
                ForEach(chartableSites) { Text($0.displayName).tag($0) }
            }
            Chart(series, id: \.date) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value(chartSite.displayName, display(point.value)))
                    .foregroundStyle(.tint)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", point.date),
                          y: .value(chartSite.displayName, display(point.value)))
                    .foregroundStyle(.tint)
            }
            .chartYAxisLabel(unitLabel(for: chartSite))
            // Circumferences live in a narrow band, so a zero-based axis
            // flattens every real change into a straight line.
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 190)
        }
    }

    private var photoSection: some View {
        Section {
            if photos.isEmpty {
                PhotoAddButton(label: "Add a photo") { add(photoData: $0, pose: .front) }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos.byDateDescending) { photo in
                            NavigationLink {
                                ProgressPhotoDetailView(photo: photo)
                            } label: {
                                PhotoThumbnail(photo: photo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                ForEach(photos.availablePoses) { pose in
                    if let pair = photos.defaultComparison(pose: pose) {
                        NavigationLink {
                            PhotoComparisonView(before: pair.before, after: pair.after)
                        } label: {
                            Label("Compare \(pose.displayName.lowercased()) — \(span(pair))",
                                  systemImage: "rectangle.split.2x1")
                        }
                    }
                }

                Menu {
                    ForEach(ProgressPhoto.Pose.allCases) { pose in
                        PhotoAddButton(label: pose.displayName) {
                            add(photoData: $0, pose: pose)
                        }
                    }
                } label: {
                    Label("Add a photo", systemImage: "camera")
                }
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Stored on this device only — they go into an encrypted backup if you make one, and nowhere else.")
        }
    }

    private var historySection: some View {
        Section("History") {
            ForEach(measurements) { measurement in
                Button {
                    editing = measurement
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(measurement.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.headline)
                        Text(summary(of: measurement))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    // Fill the row and claim it. Without these the tappable
                    // area was only as wide as the text, so most of the row
                    // did nothing when pressed.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(measurements[index]) }
            }
        }
    }

    // MARK: - Helpers

    /// Centimetres as stored; inches where the athlete works in imperial.
    private func display(_ centimetres: Double) -> Double {
        chartSite.isPercentage || units.system == .metric
            ? centimetres
            : centimetres / UnitConversion.centimetresPerInch
    }

    private func unitLabel(for site: BodyMeasurement.Site) -> String {
        site.isPercentage ? "%" : (units.system == .metric ? "cm" : "in")
    }

    private func summary(of measurement: BodyMeasurement) -> String {
        let parts = measurement.recordedSites.prefix(5).map { site in
            "\(site.displayName) \(units.bodyMeasurement(measurement[site], site: site))"
        }
        return parts.isEmpty ? "Nothing recorded" : parts.joined(separator: " · ")
    }

    private func span(_ pair: (before: ProgressPhoto, after: ProgressPhoto)) -> String {
        let days = Calendar.current.dateComponents(
            [.day], from: pair.before.date, to: pair.after.date).day ?? 0
        if days >= 365 { return String(localized: "\(days / 365) yr") }
        if days >= 60 { return String(localized: "\(days / 30) mo") }
        return String(localized: "\(days) days")
    }

    private func addMeasurement() {
        // One row per day, so re-opening today's edits it rather than making a
        // second one that silently wins the chart.
        let today = Calendar.current.startOfDay(for: .now)
        if let existing = measurements.first(where: { $0.date == today }) {
            editing = existing
            return
        }
        let measurement = BodyMeasurement(date: .now)
        context.insert(measurement)
        editing = measurement
    }

    private func add(photoData: Data, pose: ProgressPhoto.Pose) {
        do {
            let prepared = try ImageDownscaler.prepare(photoData)
            let photo = ProgressPhoto(date: .now, pose: pose)
            photo.imageData = prepared.image
            photo.thumbnailData = prepared.thumbnail
            context.insert(photo)
        } catch {
            photoError = error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct ChangeRow: View {
    let change: MeasurementTrend.Change
    let units: UnitFormatter

    private var tint: Color {
        switch change.isImprovement {
        case true?:  return .green
        case false?: return .orange
        case nil:    return .secondary
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(change.site.displayName)
                Text("\(units.bodyMeasurement(change.first, site: change.site)) → \(units.bodyMeasurement(change.last, site: change.site)) · \(change.days)d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(units.bodyMeasurementDelta(change.delta, site: change.site))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tint)
                if let percent = change.percentChange, abs(percent) >= 0.1 {
                    Text(Fmt.signed(percent, decimals: 1) + "%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct PhotoThumbnail: View {
    let photo: ProgressPhoto

    var body: some View {
        VStack(spacing: 4) {
            if let data = photo.thumbnailData ?? photo.imageData,
               let image = PlatformImage(data: data) {
                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 112)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 84, height: 112)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            Text(photo.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image(systemName: photo.pose.symbol)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Editing

struct BodyMeasurementEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context

    @Bindable var measurement: BodyMeasurement

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $measurement.date,
                               displayedComponents: .date)
                } footer: {
                    Text(units.system == .metric
                         ? "Circumferences in centimetres."
                         : "Circumferences in inches.")
                }

                ForEach(BodyMeasurement.Site.allCases) { site in
                    SiteField(site: site, measurement: measurement, units: units)
                }

                Section("Notes") {
                    TextField("Time of day, conditions…", text: Binding(
                        get: { measurement.notes ?? "" },
                        set: { measurement.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                }
            }
            .navigationTitle("Measurements")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { dismiss() }
                }
            }
        }
    }

    /// Cancelling a brand-new row should leave nothing behind, rather than an
    /// empty measurement in the history.
    private func cancel() {
        if measurement.isEmpty && measurement.notes == nil {
            context.delete(measurement)
        }
        dismiss()
    }
}

private struct SiteField: View {
    let site: BodyMeasurement.Site
    let measurement: BodyMeasurement
    let units: UnitFormatter

    @State private var text = ""
    @State private var loaded = false

    private var unitSuffix: String {
        site.isPercentage ? "%" : (units.system == .metric ? "cm" : "in")
    }

    /// The range in the unit being typed, so the warning matches the number
    /// on screen rather than the one in the database.
    private var displayRange: ClosedRange<Double> {
        guard !site.isPercentage, units.system != .metric else { return site.range }
        let low = site.range.lowerBound / UnitConversion.centimetresPerInch
        let high = site.range.upperBound / UnitConversion.centimetresPerInch
        return low...high
    }

    private var entered: Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }

    private var rangeText: String {
        String(format: "%.0f–%.0f", displayRange.lowerBound, displayRange.upperBound)
    }
    private var isOutOfRange: Bool {
        guard let entered, entered > 0 else { return false }
        return !displayRange.contains(entered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(site.displayName)
                Spacer()
                TextField("—", text: $text)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(unitSuffix)
                    .foregroundStyle(isOutOfRange ? Color.orange : Color.secondary)
                    .frame(width: 26, alignment: .leading)
            }
            // Said in words, not in colour. `foregroundStyle` on a `TextField`
            // inside a `Form` is ignored, so the tinted-number version of this
            // warning silently never appeared — and a colour alone would have
            // been a poor signal even if it had.
            if isOutOfRange {
                Label("Expected \(rangeText) \(unitSuffix) — check the decimal point",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            text = measurement[site].map { formatted(stored: $0) } ?? ""
        }
        .onChange(of: text) { _, new in
            guard let value = Double(new.replacingOccurrences(of: ",", with: ".")),
                  value > 0 else {
                measurement[site] = nil
                return
            }
            measurement[site] = stored(from: value)
        }
    }

    private func formatted(stored value: Double) -> String {
        let shown = site.isPercentage || units.system == .metric
            ? value
            : value / UnitConversion.centimetresPerInch
        return String(format: "%g", (shown * 10).rounded() / 10)
    }

    private func stored(from entered: Double) -> Double {
        site.isPercentage || units.system == .metric
            ? entered
            : entered * UnitConversion.centimetresPerInch
    }
}
