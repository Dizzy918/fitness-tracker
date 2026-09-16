import SwiftUI
import SwiftData
import MapKit

/// Tap the map to drop waypoints; the route builds as you go.
///
/// "Snap to paths" asks MapKit for walking directions between consecutive
/// waypoints so the line follows real streets and trails instead of cutting
/// across blocks. It falls back to a straight segment whenever MapKit can't
/// route (remote terrain, throttling), so a snap failure never loses your work.
struct RouteBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Editing an existing route, or nil when creating one.
    var existing: Route?

    @State private var waypoints: [CLLocationCoordinate2D] = []
    /// The drawn line: identical to `waypoints` unless snapping expanded it.
    @State private var pathPoints: [CLLocationCoordinate2D] = []
    @State private var snapToPaths = true
    @State private var snapping = false
    @State private var name = ""
    @State private var sport: WorkoutSport = .run
    @State private var camera: MapCameraPosition = .automatic
    @State private var snapFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $camera) {
                        if pathPoints.count >= 2 {
                            MapPolyline(coordinates: pathPoints)
                                .stroke(.blue, lineWidth: 4)
                        }
                        ForEach(Array(waypoints.enumerated()), id: \.offset) { index, point in
                            Annotation("\(index + 1)", coordinate: point) {
                                Circle()
                                    .fill(index == 0 ? .green : (index == waypoints.count - 1 ? .red : .blue))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                    }
                    .onTapGesture { screenPoint in
                        guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                        addWaypoint(coordinate)
                    }
                }
                .frame(minHeight: 300)

                controls
            }
            .navigationTitle(existing == nil ? "Plan Route" : "Edit Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(waypoints.count < 2 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { loadExisting() }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.km(distance))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("\(waypoints.count) waypoints\(GeoMath.isLoop(pathPoints) ? " · loop" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapping { ProgressView() }
                Button {
                    undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(waypoints.isEmpty || snapping)

                Button(role: .destructive) {
                    waypoints = []; pathPoints = []
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(waypoints.isEmpty || snapping)
            }

            if snapFailed {
                Text("Couldn't snap that segment to a path — using a straight line.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Form {
                TextField("Route name", text: $name)
                Picker("Sport", selection: $sport) {
                    ForEach([WorkoutSport.run, .trailRun, .bike, .walk, .hike], id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Snap to paths", isOn: $snapToPaths)
                if waypoints.count >= 2 {
                    Button("Close the loop") { closeLoop() }
                        .disabled(snapping || GeoMath.isLoop(pathPoints))
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var distance: Double {
        GeoMath.pathDistance(pathPoints.isEmpty ? waypoints : pathPoints)
    }

    // MARK: - Editing

    private func addWaypoint(_ coordinate: CLLocationCoordinate2D) {
        let previous = waypoints.last
        waypoints.append(coordinate)

        guard snapToPaths, let previous else {
            rebuildStraightPath()
            return
        }
        Task { await appendSnappedSegment(from: previous, to: coordinate) }
    }

    private func undo() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        // Rebuilding by re-snapping every segment would hammer MapKit; straight
        // lines are the honest fallback until the next tap re-snaps.
        rebuildStraightPath()
    }

    private func closeLoop() {
        guard let first = waypoints.first else { return }
        addWaypoint(first)
    }

    private func rebuildStraightPath() {
        pathPoints = waypoints
    }

    private func appendSnappedSegment(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async {
        snapping = true
        snapFailed = false
        defer { snapping = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = sport == .bike ? .any : .walking

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                snapFailed = true
                rebuildStraightPath()
                return
            }
            let snapped = route.polyline.coordinates
            // Drop the first point: it duplicates the previous segment's end.
            let addition = pathPoints.isEmpty ? snapped : Array(snapped.dropFirst())
            pathPoints.append(contentsOf: addition)
        } catch {
            snapFailed = true
            if pathPoints.isEmpty { pathPoints = waypoints } else { pathPoints.append(end) }
        }
    }

    // MARK: - Persistence

    private func loadExisting() {
        guard let existing else { return }
        name = existing.name
        sport = existing.sport
        let coordinates = existing.coordinates
        waypoints = coordinates
        pathPoints = coordinates
        if let region = GeoMath.boundingRegion(coordinates) {
            camera = .region(MKCoordinateRegion(
                center: region.center,
                span: MKCoordinateSpan(latitudeDelta: region.span.lat,
                                       longitudeDelta: region.span.lon)
            ))
        }
    }

    private func save() {
        let route = existing ?? Route(name: name, sport: sport)
        route.name = name.trimmingCharacters(in: .whitespaces)
        route.sport = sport
        route.setGeometry(coordinates: pathPoints.isEmpty ? waypoints : pathPoints)
        if existing == nil { context.insert(route) }
        dismiss()
    }
}

extension MKPolyline {
    /// MapKit gives points as a C array; this is the Swift-friendly view.
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: pointCount
        )
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}
