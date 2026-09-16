import Foundation
import CryptoKit
import PDFKit

/// One workout the model found in a document. Everything past the essentials is
/// optional — a training-plan PDF often states distance but not heart rate.
struct ExtractedWorkout: Codable, Identifiable, Sendable {
    var sport: String
    var date: String                  // ISO 8601 "YYYY-MM-DD"
    var time: String?                 // "HH:mm" if stated
    var durationSeconds: Double?
    var distanceMeters: Double?
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var elevationGainMeters: Double?
    var calories: Double?
    var notes: String?
    /// Where in the document this came from, e.g. "page 2, row 4" — lets you
    /// check the model against the source.
    var sourceHint: String?
    /// 0–1 self-reported confidence. Low values are worth eyeballing.
    var confidence: Double?

    var id: String { "\(date)-\(sport)-\(distanceMeters ?? 0)-\(durationSeconds ?? 0)" }

    var mappedSport: WorkoutSport { SportMapper.map(sport) }

    /// Parsed start date, combining `date` and optional `time`.
    var startedAt: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        if let time, !time.isEmpty {
            f.dateFormat = "yyyy-MM-dd HH:mm"
            if let d = f.date(from: "\(date) \(time)") { return d }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)
    }

    /// Enough signal to be worth importing?
    var isImportable: Bool {
        startedAt != nil && ((distanceMeters ?? 0) > 0 || (durationSeconds ?? 0) > 0)
    }
}

struct ExtractionResult: Codable, Sendable {
    var workouts: [ExtractedWorkout]
    var documentSummary: String?
}

/// Sends a PDF to Claude and gets back structured workouts.
///
/// The model never writes to the database directly — results go to a review
/// screen first. Extraction from arbitrary documents is inherently uncertain, so
/// a human confirms before anything is persisted.
struct PDFWorkoutExtractor {
    var client = AnthropicClient()

    /// Anthropic's limits: 32 MB per request and 600 pages. Base64 inflates by
    /// ~33%, so cap the raw file below the request limit.
    static let maxRawBytes = 20 * 1024 * 1024
    static let maxPages = 600

    enum ExtractionError: LocalizedError {
        case tooLarge(bytes: Int)
        case tooManyPages(Int)
        case notAPDF
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                return String(format: "That PDF is %.1f MB. The limit is 20 MB — split it up.", mb)
            case .tooManyPages(let n):
                return "That PDF has \(n) pages; the limit is \(PDFWorkoutExtractor.maxPages)."
            case .notAPDF:
                return "That file isn't a readable PDF."
            case .nothingFound:
                return "No workouts found in that document."
            }
        }
    }

    private static let systemPrompt = """
        You extract training data from documents into structured records.

        Rules:
        - Only report workouts actually present in the document. Never invent or \
        extrapolate entries, and never fill a field the document does not state.
        - Convert units to metric: distance in meters, duration in seconds, \
        elevation in meters. A time like "1:23:45" is 5025 seconds; "45:30" in a \
        duration column is 45 minutes 30 seconds.
        - If a distance is given in miles, multiply by 1609.34.
        - Dates must be ISO 8601 (YYYY-MM-DD). If the document gives a weekday or \
        relative date and the year is stated elsewhere, resolve it; if the year is \
        genuinely unknowable, omit that workout rather than guessing.
        - Set `sourceHint` to where you found each row (page and table/row) so a \
        human can verify it.
        - Set `confidence` below 0.5 when a value is ambiguous, inferred from \
        context, or hard to read.
        - A planned/prescribed workout that was not performed is still a workout \
        record; note that in `notes`.
        """

    private static var tool: AnthropicClient.Tool {
        // Every property is listed in `required`, with nullable types for the
        // optional ones, so the schema satisfies strict validation either way.
        let workoutSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "sport", "date", "time", "durationSeconds", "distanceMeters",
                "avgHeartRate", "maxHeartRate", "elevationGainMeters", "calories",
                "notes", "sourceHint", "confidence",
            ],
            "properties": [
                "sport": [
                    "type": "string",
                    "description": "run, trailRun, bike, swim, hike, walk, or other",
                ],
                "date": ["type": "string", "description": "ISO 8601 date, YYYY-MM-DD"],
                "time": ["type": ["string", "null"], "description": "24h HH:mm if stated"],
                "durationSeconds": ["type": ["number", "null"]],
                "distanceMeters": ["type": ["number", "null"]],
                "avgHeartRate": ["type": ["integer", "null"]],
                "maxHeartRate": ["type": ["integer", "null"]],
                "elevationGainMeters": ["type": ["number", "null"]],
                "calories": ["type": ["number", "null"]],
                "notes": ["type": ["string", "null"]],
                "sourceHint": [
                    "type": ["string", "null"],
                    "description": "Where in the document this row came from",
                ],
                "confidence": [
                    "type": ["number", "null"],
                    "description": "0-1 confidence in this record",
                ],
            ],
        ]

        return AnthropicClient.Tool(
            name: "record_workouts",
            description: "Record every workout found in the document.",
            inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["workouts", "documentSummary"],
                "properties": [
                    "workouts": ["type": "array", "items": workoutSchema],
                    "documentSummary": [
                        "type": ["string", "null"],
                        "description": "One sentence on what this document is",
                    ],
                ],
            ]
        )
    }

    /// Validate, then extract. Throws rather than returning partial nonsense.
    func extract(pdf data: Data, filename: String? = nil) async throws -> ExtractionResult {
        guard data.count <= Self.maxRawBytes else {
            throw ExtractionError.tooLarge(bytes: data.count)
        }
        guard let document = PDFDocument(data: data) else {
            throw ExtractionError.notAPDF
        }
        guard document.pageCount <= Self.maxPages else {
            throw ExtractionError.tooManyPages(document.pageCount)
        }

        let instruction = """
            Extract every workout recorded in this document. \
            If it contains no training data at all, return an empty workouts array.
            """

        return try await client.callTool(
            content: [.pdf(data, filename: filename), .text(instruction)],
            system: Self.systemPrompt,
            tool: Self.tool,
            as: ExtractionResult.self
        )
    }

    /// Stable per-document ID so re-importing the same PDF dedupes.
    static func externalID(for workout: ExtractedWorkout, documentData: Data) -> String {
        let hash = SHA256.hash(data: documentData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "pdf:\(hash):\(workout.id)"
    }
}
