import SwiftUI
import UniformTypeIdentifiers

/// Preview the card, choose whether the route goes with it, and share.
struct ShareWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @Environment(\.displayScale) private var displayScale

    let workout: Workout
    /// Computed by the detail view, which already has the athlete profile —
    /// rather than recomputing it here from a second copy of the settings.
    var load: TrainingLoad.Score?

    @State private var includeRoute = false
    @State private var rendering = false
    @State private var rendered: URL?
    @State private var failure: String?

    private var snapshot: WorkoutSnapshot { workout.snapshot }

    private var splits: [Split] {
        // A long ride produces fifty bars nobody can read. The chart is meant
        // to show the shape of the session, and past a dozen or so it stops
        // showing anything.
        let all = SplitCalculator.splits(from: snapshot.samples)
        return all.count <= 14 ? all : []
    }

    private var card: ShareCardView {
        ShareCardView(
            workout: snapshot,
            coordinates: workout.coordinates,
            splits: splits,
            units: units,
            load: load?.value,
            source: workout.source,
            includeRoute: includeRoute)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // `scaleEffect` is a visual transform: the card still
                    // claims its full 1080×1350 of layout space, and the
                    // frame below reserves the scaled size. Both have to
                    // shrink about the same point, so the anchor stays at the
                    // default centre — anchoring to `.top` scales about the
                    // top of the *unscaled* bounds and pushes the card almost
                    // entirely out of its slot, leaving a blank preview.
                    card
                        .scaleEffect(previewScale)
                        .frame(width: ShareCardView.size.width * previewScale,
                               height: ShareCardView.size.height * previewScale)
                        .clipShape(.rect(cornerRadius: 18))
                        .shadow(radius: 12, y: 4)

                    if RouteGeometry.isDrawable(workout.coordinates) {
                        Toggle("Include the route", isOn: $includeRoute)
                            .padding(.horizontal, 24)
                    }

                    Text(RouteGeometry.isDrawable(workout.coordinates)
                         ? "The route is drawn from your own recording — no map tiles, no third party. It still traces wherever you started, so it's off unless you turn it on."
                         : "This workout has no GPS track, so the card is stats only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Share")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await render() }
                    } label: {
                        if rendering { ProgressView() } else { Text("Share") }
                    }
                    .disabled(rendering)
                }
            }
            .sheet(item: $rendered) { ShareLinkSheet(url: $0) }
        }
    }

    /// Fit the 1080-wide card into a phone, so the preview is the thing that
    /// gets shared rather than an approximation of it.
    private var previewScale: CGFloat {
        #if os(iOS)
        return 0.31
        #else
        return 0.36
        #endif
    }

    @MainActor
    private func render() async {
        rendering = true
        defer { rendering = false }

        let renderer = ImageRenderer(content: card)
        // 1× of the design size: the card is already 1080×1350, and scaling it
        // by the device's display scale would produce a 3240-pixel image for
        // no visible gain.
        renderer.scale = 1

        guard let data = pngData(from: renderer) else {
            failure = "Couldn't render the card."
            return
        }
        do {
            let name = "\(snapshot.sport.rawValue)-\(Int(snapshot.startedAt.timeIntervalSince1970)).png"
            let url = URL.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            rendered = url
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// PNG bytes from the renderer, on either platform.
    @MainActor
    private func pngData(from renderer: ImageRenderer<ShareCardView>) -> Data? {
        #if canImport(UIKit)
        return renderer.uiImage?.pngData()
        #elseif canImport(AppKit)
        guard let cgImage = renderer.cgImage else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
