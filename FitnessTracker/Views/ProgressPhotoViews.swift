import SwiftUI
import SwiftData
import PhotosUI

/// A SwiftUI `Image` from stored bytes, on either platform.
///
/// `Image(data:)` doesn't exist, and the platform image types differ, so every
/// view that shows a stored photo would otherwise carry its own `#if os`.
func PlatformImage(data: Data) -> Image? {
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else { return nil }
    return Image(uiImage: image)
    #elseif canImport(AppKit)
    guard let image = NSImage(data: data) else { return nil }
    return Image(nsImage: image)
    #else
    return nil
    #endif
}

/// Picks a photo and hands back its bytes.
struct PhotoAddButton: View {
    let label: String
    let onPick: (Data) -> Void

    @State private var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images,
                     photoLibrary: .shared()) {
            Label(label, systemImage: "photo.badge.plus")
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                // Loaded as `Data` rather than as an image: the downscaler
                // reads the file's own bytes so it can honour EXIF orientation
                // and avoid ever decoding the full-size frame.
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { onPick(data) }
                }
                await MainActor.run { selection = nil }
            }
        }
    }
}

/// One photo, full size, with what it's of and when.
struct ProgressPhotoDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var photo: ProgressPhoto

    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let data = photo.imageData, let image = PlatformImage(data: data) {
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    ContentUnavailableView("Image missing", systemImage: "photo")
                }

                Picker("Pose", selection: $photo.pose) {
                    ForEach(ProgressPhoto.Pose.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                DatePicker("Taken", selection: $photo.date, displayedComponents: .date)

                TextField("Notes", text: Binding(
                    get: { photo.notes ?? "" },
                    set: { photo.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
            }
            .padding()
        }
        .navigationTitle(photo.date.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(photo)
                dismiss()
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// Two photos side by side, with a slider to wipe between them.
struct PhotoComparisonView: View {
    let before: ProgressPhoto
    let after: ProgressPhoto

    @State private var mode: Mode = .sideBySide
    @State private var wipe: Double = 0.5

    private enum Mode: String, CaseIterable, Identifiable {
        case sideBySide, wipe
        var id: String { rawValue }
        var label: String { self == .sideBySide ? "Side by side" : "Wipe" }
    }

    private var days: Int {
        Calendar.current.dateComponents([.day], from: before.date, to: after.date).day ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .sideBySide:
                    HStack(alignment: .top, spacing: 8) {
                        captioned(before, caption: "Then")
                        captioned(after, caption: "Now")
                    }
                case .wipe:
                    // Both images drawn at the same size with the top one
                    // clipped, so the comparison is of the same body at the
                    // same scale rather than two differently-cropped photos.
                    ZStack(alignment: .leading) {
                        image(before)
                        image(after)
                            .mask(alignment: .leading) {
                                GeometryReader { geometry in
                                    Rectangle()
                                        .frame(width: geometry.size.width * wipe)
                                }
                            }
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(alignment: .topLeading) { tag("Now") .padding(8) }
                    .overlay(alignment: .topTrailing) { tag("Then").padding(8) }

                    Slider(value: $wipe, in: 0...1)
                }

                Text("\(days) days · \(before.date.formatted(date: .abbreviated, time: .omitted)) → \(after.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("\(before.pose.displayName) comparison")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func captioned(_ photo: ProgressPhoto, caption: String) -> some View {
        VStack(spacing: 4) {
            image(photo).clipShape(.rect(cornerRadius: 10))
            Text(caption).font(.caption.weight(.medium))
            Text(photo.date.formatted(.dateTime.month(.abbreviated).year()))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func image(_ photo: ProgressPhoto) -> some View {
        if let data = photo.imageData, let image = PlatformImage(data: data) {
            image.resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule)
            .foregroundStyle(.white)
    }
}
