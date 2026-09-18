import XCTest
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FitnessTracker

/// Tape measurements and their trends.
@MainActor
final class BodyMeasurementTests: XCTestCase {

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func date(_ daysAfterStart: Int) -> Date {
        day0.addingTimeInterval(Double(daysAfterStart) * 86_400)
    }

    // MARK: - The subscript, which everything else is built on

    func testSubscriptRoundTripsEverySite() {
        let measurement = BodyMeasurement(date: day0)
        for (index, site) in BodyMeasurement.Site.allCases.enumerated() {
            measurement[site] = Double(index) + 30
        }
        for (index, site) in BodyMeasurement.Site.allCases.enumerated() {
            XCTAssertEqual(measurement[site] ?? -1, Double(index) + 30, accuracy: 0.001,
                           "\(site.rawValue) didn't round-trip")
        }
    }

    /// A site missing from the subscript would silently read and write nil,
    /// which no other test would notice.
    func testEverySiteIsReachable() {
        let measurement = BodyMeasurement(date: day0)
        for site in BodyMeasurement.Site.allCases {
            measurement[site] = 42
            XCTAssertEqual(measurement[site], 42, "\(site.rawValue) is not wired up")
            measurement[site] = nil
            XCTAssertNil(measurement[site])
        }
    }

    func testRecordedSitesFollowsTapeOrderNotEntryOrder() {
        let measurement = BodyMeasurement(date: day0)
        measurement[.calfLeft] = 38
        measurement[.waist] = 82
        measurement[.neck] = 39

        XCTAssertEqual(measurement.recordedSites, [.neck, .waist, .calfLeft])
        XCTAssertFalse(measurement.isEmpty)
        XCTAssertTrue(BodyMeasurement(date: day0).isEmpty)
    }

    func testDateIsNormalisedToTheStartOfTheDay() {
        let noon = day0.addingTimeInterval(43_200)
        XCTAssertEqual(BodyMeasurement(date: noon).date,
                       Calendar.current.startOfDay(for: noon))
    }

    func testWaistToHipNeedsBoth() {
        let measurement = BodyMeasurement(date: day0)
        XCTAssertNil(measurement.waistToHip)
        measurement.waist = 84
        XCTAssertNil(measurement.waistToHip)
        measurement.hips = 100
        XCTAssertEqual(measurement.waistToHip ?? 0, 0.84, accuracy: 0.001)
    }

    func testOnlyBodyFatHasADirection() {
        XCTAssertEqual(BodyMeasurement.Site.bodyFat.lowerIsBetter, true)
        for site in BodyMeasurement.Site.allCases where site != .bodyFat {
            XCTAssertNil(site.lowerIsBetter,
                         "\(site.rawValue) claims a direction it can't know")
        }
    }

    func testPlausibleRangesContainRealisticValues() {
        XCTAssertTrue(BodyMeasurement.Site.waist.range.contains(82))
        XCTAssertTrue(BodyMeasurement.Site.armLeft.range.contains(35))
        XCTAssertTrue(BodyMeasurement.Site.bodyFat.range.contains(14))
        // And exclude a slipped decimal point.
        XCTAssertFalse(BodyMeasurement.Site.waist.range.contains(8.2))
        XCTAssertFalse(BodyMeasurement.Site.bodyFat.range.contains(140))
    }

    // MARK: - Trends

    func testChangesNeedTwoReadingsAtTheSameSite() {
        let one = BodyMeasurement(date: day0)
        one.waist = 88
        XCTAssertTrue(MeasurementTrend.changes(in: [one]).isEmpty,
                      "one reading is a record, not a trend")

        let two = BodyMeasurement(date: date(28))
        two.waist = 85
        let changes = MeasurementTrend.changes(in: [one, two])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].site, .waist)
        XCTAssertEqual(changes[0].delta, -3, accuracy: 0.001)
        XCTAssertEqual(changes[0].days, 28)
    }

    /// Sites are paired independently, because people measure their waist
    /// weekly and their calves twice a year.
    func testEachSiteUsesItsOwnFirstAndLastReading() throws {
        let a = BodyMeasurement(date: day0)
        a.waist = 90
        a.calfLeft = 37
        let b = BodyMeasurement(date: date(30))
        b.waist = 87
        let c = BodyMeasurement(date: date(60))
        c.waist = 85
        c.calfLeft = 38

        let changes = MeasurementTrend.changes(in: [a, b, c])
        let waist = try XCTUnwrap(changes.first { $0.site == .waist })
        let calf = try XCTUnwrap(changes.first { $0.site == .calfLeft })

        // The waist has three readings and uses the outer two.
        XCTAssertEqual(waist.days, 60)
        XCTAssertEqual(waist.delta, -5, accuracy: 0.001)
        // The calf only has the two, and is paired on its own readings.
        XCTAssertEqual(calf.days, 60)
        XCTAssertEqual(calf.delta, 1, accuracy: 0.001)
    }

    func testChangesAreOrderedIndependentOfInputOrder() {
        let late = BodyMeasurement(date: date(60))
        late.waist = 85
        let early = BodyMeasurement(date: day0)
        early.waist = 90

        let changes = MeasurementTrend.changes(in: [late, early])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].first, 90, "earliest reading must be `first`")
        XCTAssertEqual(changes[0].last, 85)
        XCTAssertLessThan(changes[0].delta, 0)
    }

    func testWindowExcludesOlderReadings() {
        let old = BodyMeasurement(date: day0)
        old.waist = 100
        let recent = BodyMeasurement(date: date(50))
        recent.waist = 90
        let newest = BodyMeasurement(date: date(60))
        newest.waist = 88

        let windowed = MeasurementTrend.changes(in: [old, recent, newest],
                                                since: date(40))
        XCTAssertEqual(windowed.count, 1)
        XCTAssertEqual(windowed[0].first, 90, "the 100 is outside the window")
        XCTAssertEqual(windowed[0].delta, -2, accuracy: 0.001)
    }

    func testWindowLeavingOneReadingYieldsNoTrend() {
        let old = BodyMeasurement(date: day0)
        old.waist = 100
        let recent = BodyMeasurement(date: date(60))
        recent.waist = 90
        XCTAssertTrue(MeasurementTrend.changes(in: [old, recent], since: date(50)).isEmpty)
    }

    func testPercentChangeScalesBySite() {
        let a = BodyMeasurement(date: day0)
        a.waist = 100
        a.armLeft = 30
        let b = BodyMeasurement(date: date(30))
        b.waist = 98
        b.armLeft = 32

        let changes = MeasurementTrend.changes(in: [a, b])
        let waist = changes.first { $0.site == .waist }
        let arm = changes.first { $0.site == .armLeft }
        // Both moved 2 cm; only one of them is a big deal.
        XCTAssertEqual(waist?.percentChange ?? 0, -2, accuracy: 0.01)
        XCTAssertEqual(arm?.percentChange ?? 0, 6.667, accuracy: 0.01)
    }

    func testImprovementIsOnlyClaimedForBodyFat() {
        let a = BodyMeasurement(date: day0)
        a.bodyFatPercent = 18
        a.waist = 90
        let b = BodyMeasurement(date: date(30))
        b.bodyFatPercent = 15
        b.waist = 95

        let changes = MeasurementTrend.changes(in: [a, b])
        XCTAssertEqual(changes.first { $0.site == .bodyFat }?.isImprovement, true)
        XCTAssertNil(changes.first { $0.site == .waist }?.isImprovement,
                     "a bigger waist is a goal for some people and not others")
    }

    func testNoChangeIsNotAnImprovement() {
        let a = BodyMeasurement(date: day0)
        a.bodyFatPercent = 15
        let b = BodyMeasurement(date: date(30))
        b.bodyFatPercent = 15
        XCTAssertNil(MeasurementTrend.changes(in: [a, b]).first?.isImprovement)
    }

    func testSeriesIsChronologicalAndSkipsBlanks() {
        let a = BodyMeasurement(date: date(60)); a.waist = 85
        let b = BodyMeasurement(date: day0);     b.waist = 90
        let c = BodyMeasurement(date: date(30))  // no waist reading

        let series = MeasurementTrend.series(for: .waist, in: [a, b, c])
        XCTAssertEqual(series.map(\.value), [90, 85])
        XCTAssertEqual(series.map(\.date), [day0, date(60)].map {
            Calendar.current.startOfDay(for: $0)
        })
    }

    func testEmptyInputIsHandled() {
        XCTAssertTrue(MeasurementTrend.changes(in: []).isEmpty)
        XCTAssertTrue(MeasurementTrend.series(for: .waist, in: []).isEmpty)
    }

    // MARK: - Persistence

    func testMeasurementSurvivesAFetch() throws {
        let context = try makeContext()
        let measurement = BodyMeasurement(date: day0)
        measurement.waist = 82.5
        measurement.bodyFatPercent = 13.4
        measurement.notes = "Morning, fasted"
        context.insert(measurement)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BodyMeasurement>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.waist ?? 0, 82.5, accuracy: 0.001)
        XCTAssertEqual(fetched.first?.notes, "Morning, fasted")
    }
}

/// Progress photos, and the downscaling that makes storing them viable.
@MainActor
final class ProgressPhotoTests: XCTestCase {

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A real JPEG of the given pixel size, so the downscaler is exercised
    /// rather than mocked.
    private func jpeg(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Something with detail, so JPEG can't compress it to nothing.
        for band in 0..<8 {
            context.setFillColor(red: Double(band) / 8, green: 0.4, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: height / 8 * band,
                                width: width, height: height / 8))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    // MARK: - Downscaling

    func testLargePhotoIsBroughtUnderTheLimit() throws {
        let original = try jpeg(width: 4032, height: 3024)
        let result = try ImageDownscaler.prepare(original)

        let image = try pixelSize(of: result.image)
        XCTAssertEqual(max(image.width, image.height), ImageDownscaler.maxDimension)
        // Aspect ratio preserved.
        XCTAssertEqual(Double(image.width) / Double(image.height),
                       4032.0 / 3024.0, accuracy: 0.01)

        let thumbnail = try pixelSize(of: result.thumbnail)
        XCTAssertEqual(max(thumbnail.width, thumbnail.height),
                       ImageDownscaler.thumbnailDimension)
    }

    /// The whole reason this exists: what goes into the store has to be a
    /// fraction of what came off the camera.
    func testDownscalingCutsTheStoredSizeSubstantially() throws {
        let original = try jpeg(width: 4032, height: 3024)
        let result = try ImageDownscaler.prepare(original)
        XCTAssertLessThan(result.image.count, original.count / 3,
                          "stored \(result.image.count) of \(original.count) bytes")
        XCTAssertLessThan(result.thumbnail.count, result.image.count)
    }

    func testPortraitOrientationIsPreserved() throws {
        let original = try jpeg(width: 1080, height: 1920)
        let image = try pixelSize(of: try ImageDownscaler.prepare(original).image)
        XCTAssertLessThan(image.width, image.height, "a portrait photo came back landscape")
        XCTAssertEqual(image.height, ImageDownscaler.maxDimension)
    }

    /// A photo already smaller than the limit must not be blown up.
    func testSmallPhotoIsNotEnlarged() throws {
        let original = try jpeg(width: 600, height: 800)
        let image = try pixelSize(of: try ImageDownscaler.prepare(original).image)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 800)
    }

    func testNonImageDataThrowsRatherThanCrashing() {
        let junk = Data("this is not an image".utf8)
        XCTAssertThrowsError(try ImageDownscaler.prepare(junk))
        XCTAssertThrowsError(try ImageDownscaler.prepare(Data()))
    }

    // MARK: - Comparison pairing

    func testComparisonPairsOldestAndNewestOfTheSamePose() {
        let photos = [
            photo(daysAfter: 0, pose: .front),
            photo(daysAfter: 30, pose: .front),
            photo(daysAfter: 60, pose: .front),
            photo(daysAfter: 90, pose: .side),
        ]
        let pair = photos.defaultComparison(pose: .front)
        XCTAssertEqual(pair?.before.date, day0)
        XCTAssertEqual(pair?.after.date, day0.addingTimeInterval(60 * 86_400))
    }

    /// Never pairs across poses: a front shot beside a side shot compares
    /// nothing, and showing it as a comparison would be a lie.
    func testComparisonRefusesToPairAcrossPoses() {
        let photos = [photo(daysAfter: 0, pose: .front),
                      photo(daysAfter: 60, pose: .back)]
        XCTAssertNil(photos.defaultComparison(pose: .front))
        XCTAssertNil(photos.defaultComparison(pose: .back))
    }

    func testOnePhotoIsNotAComparison() {
        XCTAssertNil([photo(daysAfter: 0, pose: .front)].defaultComparison(pose: .front))
        XCTAssertNil([ProgressPhoto]().defaultComparison(pose: .front))
    }

    func testAvailablePosesFollowsTheModelsOrder() {
        let photos = [photo(daysAfter: 0, pose: .back),
                      photo(daysAfter: 1, pose: .front)]
        XCTAssertEqual(photos.availablePoses, [.front, .back])
    }

    func testSortedNewestFirst() {
        let photos = [photo(daysAfter: 0, pose: .front),
                      photo(daysAfter: 60, pose: .front),
                      photo(daysAfter: 30, pose: .front)]
        XCTAssertEqual(photos.byDateDescending.map(\.date),
                       [60, 30, 0].map { day0.addingTimeInterval(Double($0) * 86_400) })
    }

    // MARK: - Persistence

    func testPhotoAndThumbnailSurviveAFetch() throws {
        let context = try makeContext()
        let result = try ImageDownscaler.prepare(try jpeg(width: 2000, height: 1500))
        let stored = ProgressPhoto(date: day0, pose: .side)
        stored.imageData = result.image
        stored.thumbnailData = result.thumbnail
        context.insert(stored)
        try context.save()

        let fetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProgressPhoto>()).first)
        XCTAssertEqual(fetched.pose, .side)
        XCTAssertEqual(fetched.imageData?.count, result.image.count)
        XCTAssertEqual(fetched.thumbnailData?.count, result.thumbnail.count)
    }

    private func photo(daysAfter days: Int, pose: ProgressPhoto.Pose) -> ProgressPhoto {
        ProgressPhoto(date: day0.addingTimeInterval(Double(days) * 86_400), pose: pose)
    }
}

// MARK: - Backup

@MainActor
final class BodyCompositionArchiveTests: XCTestCase {

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: FitnessTrackerApp.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func jpeg() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func populated() throws -> ModelContext {
        let context = try makeContext()
        let measurement = BodyMeasurement(date: day0)
        measurement.waist = 84.5
        measurement.armLeft = 35
        measurement.armRight = 35.5
        measurement.bodyFatPercent = 13.2
        measurement.notes = "Fasted"
        context.insert(measurement)

        let prepared = try ImageDownscaler.prepare(try jpeg())
        let photo = ProgressPhoto(date: day0, pose: .back)
        photo.imageData = prepared.image
        photo.thumbnailData = prepared.thumbnail
        photo.notes = "Week 1"
        context.insert(photo)
        try context.save()
        return context
    }

    func testMeasurementsAndPhotosSurviveAFullRoundTrip() throws {
        let source = try populated()
        let data = try DataArchive.exportData(from: source)

        let restored = try makeContext()
        let report = try DataArchive.restore(try DataArchive.read(data), into: restored)
        try restored.save()

        XCTAssertEqual(report.bodyMeasurements, 1)
        XCTAssertEqual(report.progressPhotos, 1)

        let measurement = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<BodyMeasurement>()).first)
        XCTAssertEqual(measurement.waist ?? 0, 84.5, accuracy: 0.001)
        XCTAssertEqual(measurement.armRight ?? 0, 35.5, accuracy: 0.001)
        XCTAssertEqual(measurement.bodyFatPercent ?? 0, 13.2, accuracy: 0.001)
        XCTAssertEqual(measurement.notes, "Fasted")

        let photo = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<ProgressPhoto>()).first)
        XCTAssertEqual(photo.pose, .back)
        XCTAssertEqual(photo.notes, "Week 1")
        XCTAssertNotNil(photo.imageData)
        XCTAssertNotNil(PlatformImage(data: try XCTUnwrap(photo.imageData)),
                        "the restored bytes are still a decodable image")
    }

    /// Every measured site has to survive, not just the ones a test remembered.
    func testEverySiteSurvivesTheRoundTrip() throws {
        let source = try makeContext()
        let measurement = BodyMeasurement(date: day0)
        for (index, site) in BodyMeasurement.Site.allCases.enumerated() {
            measurement[site] = Double(index) + 30
        }
        source.insert(measurement)
        try source.save()

        let restored = try makeContext()
        _ = try DataArchive.restore(
            try DataArchive.read(try DataArchive.exportData(from: source)), into: restored)
        try restored.save()

        let copy = try XCTUnwrap(
            try restored.fetch(FetchDescriptor<BodyMeasurement>()).first)
        for (index, site) in BodyMeasurement.Site.allCases.enumerated() {
            XCTAssertEqual(copy[site] ?? -1, Double(index) + 30, accuracy: 0.001,
                           "\(site.rawValue) was lost in the backup")
        }
    }

    /// A streamless export is for sharing a training log, not a photo album.
    func testStreamlessExportOmitsPhotoBytesButKeepsMeasurements() throws {
        let source = try populated()
        let full = try DataArchive.exportData(from: source, includeStreams: true)
        let light = try DataArchive.exportData(from: source, includeStreams: false)

        XCTAssertLessThan(light.count, full.count)
        let archive = try DataArchive.read(light)
        XCTAssertEqual(archive.bodyMeasurements.count, 1)
        XCTAssertEqual(archive.progressPhotos.count, 1)
        XCTAssertNil(archive.progressPhotos.first?.imageData)

        // And restoring it doesn't create a dated blank frame.
        let restored = try makeContext()
        let report = try DataArchive.restore(archive, into: restored)
        XCTAssertEqual(report.progressPhotos, 0)
        XCTAssertEqual(report.bodyMeasurements, 1)
    }

    /// Restoring twice must not double the history.
    func testRestoringTwiceIsIdempotent() throws {
        let source = try populated()
        let data = try DataArchive.exportData(from: source)
        let restored = try makeContext()

        _ = try DataArchive.restore(try DataArchive.read(data), into: restored)
        try restored.save()
        let second = try DataArchive.restore(try DataArchive.read(data), into: restored)
        try restored.save()

        XCTAssertEqual(second.bodyMeasurements, 0)
        XCTAssertEqual(second.progressPhotos, 0)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<BodyMeasurement>()).count, 1)
        XCTAssertEqual(try restored.fetch(FetchDescriptor<ProgressPhoto>()).count, 1)
    }

    /// Two devices can write different ids for the same day's measurements;
    /// merging them must not put two points on one date.
    func testMeasurementsAreMergedByDayNotById() throws {
        let source = try populated()
        let data = try DataArchive.exportData(from: source)

        let target = try makeContext()
        let mine = BodyMeasurement(date: day0)   // same day, different id
        mine.waist = 90
        target.insert(mine)
        try target.save()

        let report = try DataArchive.restore(try DataArchive.read(data), into: target)
        try target.save()

        XCTAssertEqual(report.bodyMeasurements, 0)
        XCTAssertEqual(try target.fetch(FetchDescriptor<BodyMeasurement>()).count, 1)
        XCTAssertEqual(mine.waist ?? 0, 90, accuracy: 0.001, "the local row wins")
    }
}
