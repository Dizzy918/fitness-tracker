import Foundation
import SwiftData

/// A dated photo, for comparing shape against shape rather than number
/// against number.
///
/// The measurement that people actually trust, and the one a tape and a scale
/// both miss. Twelve weeks of 0.4 kg a month is invisible in the mirror day to
/// day and obvious side by side.
///
/// Stays on the device. There's no account and no backend here, and a set of
/// progress photos is about as private as data gets — it goes in the local
/// store, into an encrypted backup if the athlete makes one, and nowhere else.
@Model
final class ProgressPhoto {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var poseRaw: String = Pose.front.rawValue
    var notes: String?

    /// JPEG bytes, downscaled on the way in. See `ImageDownscaler`.
    ///
    /// External storage is not optional here: a phone photo is several
    /// megabytes, `@Query` hydrates every row it returns, and a year of weekly
    /// photos inline would drag half a gigabyte through memory to draw a grid
    /// of thumbnails.
    @Attribute(.externalStorage) var imageData: Data?

    /// A small square rendered once at import, so the grid doesn't decode
    /// full-size JPEGs to draw 100-point tiles.
    @Attribute(.externalStorage) var thumbnailData: Data?

    init(id: UUID = UUID(), date: Date = .now, pose: Pose = .front) {
        self.id = id
        self.date = date
        self.poseRaw = pose.rawValue
    }

    var pose: Pose {
        get { Pose(rawValue: poseRaw) ?? .front }
        set { poseRaw = newValue.rawValue }
    }

    enum Pose: String, CaseIterable, Identifiable, Sendable {
        case front, side, back

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .front: return String(localized: "Front")
            case .side:  return String(localized: "Side")
            case .back:  return String(localized: "Back")
            }
        }
        var symbol: String {
            switch self {
            case .front: return "person.fill"
            case .side:  return "person.fill.turn.right"
            case .back:  return "person.fill.turn.down"
            }
        }
    }
}

extension Array where Element == ProgressPhoto {

    /// Newest first, which is the order a grid should show them.
    var byDateDescending: [ProgressPhoto] {
        sorted { $0.date > $1.date }
    }

    /// The two photos a comparison should default to: the oldest and newest of
    /// the same pose.
    ///
    /// Same pose, because a front shot next to a side shot compares nothing.
    /// Returns nil rather than pairing across poses, so a comparison is either
    /// honest or absent.
    func defaultComparison(pose: ProgressPhoto.Pose) -> (before: ProgressPhoto,
                                                         after: ProgressPhoto)? {
        let matching = filter { $0.pose == pose }.sorted { $0.date < $1.date }
        guard let first = matching.first, let last = matching.last,
              first.id != last.id else { return nil }
        return (first, last)
    }

    /// Poses that have at least one photo, in the model's own order.
    var availablePoses: [ProgressPhoto.Pose] {
        ProgressPhoto.Pose.allCases.filter { pose in contains { $0.pose == pose } }
    }
}
