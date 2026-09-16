import XCTest
import SwiftData
@testable import FitnessTracker

/// Intercepts requests so we can assert exactly what goes on the wire and feed
/// canned responses back — no network, no API key, no cost.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200

    static func reset() {
        capturedRequest = nil
        capturedBody = nil
        responseBody = Data()
        statusCode = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        // httpBody is nil for stream-backed bodies; read the stream instead.
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            var data = Data()
            let size = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            return data
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class AnthropicRequestShapeTests: XCTestCase {

    private let tool = AnthropicClient.Tool(
        name: "record_workouts",
        description: "Record workouts.",
        inputSchema: ["type": "object", "additionalProperties": false, "required": []]
    )

    private func body(content: [AnthropicClient.RequestContent]) -> [String: Any] {
        AnthropicClient.requestBody(
            model: AnthropicClient.defaultModel,
            maxTokens: 16_000,
            content: content,
            system: "You extract training data.",
            tool: tool
        )
    }

    func testUsesOpus5AndAdaptiveThinking() {
        let b = body(content: [.text("hi")])
        XCTAssertEqual(b["model"] as? String, "claude-opus-5")
        XCTAssertEqual((b["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        // budget_tokens is rejected on Opus 5 — it must not be sent.
        XCTAssertNil((b["thinking"] as? [String: Any])?["budget_tokens"])
        XCTAssertEqual((b["output_config"] as? [String: Any])?["effort"] as? String, "high")
    }

    func testForcesStrictToolUse() throws {
        let b = body(content: [.text("hi")])
        let tools = try XCTUnwrap(b["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "record_workouts")
        XCTAssertEqual(tools[0]["strict"] as? Bool, true)

        let choice = try XCTUnwrap(b["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "tool")
        XCTAssertEqual(choice["name"] as? String, "record_workouts")
    }

    func testEnablesServerSideFallbacks() {
        XCTAssertEqual(body(content: [.text("hi")])["fallbacks"] as? String, "default")
    }

    func testPDFBlockPrecedesTextAndIsBase64() throws {
        let pdfBytes = Data("%PDF-1.7 fake".utf8)
        let b = body(content: [.pdf(pdfBytes, filename: "plan.pdf"), .text("Extract workouts")])

        let messages = try XCTUnwrap(b["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "document",
                       "document block must come before the instruction")
        XCTAssertEqual(blocks[1]["type"] as? String, "text")

        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "application/pdf")

        let encoded = try XCTUnwrap(source["data"] as? String)
        XCTAssertFalse(encoded.contains("\n"), "wrapped base64 is rejected by the API")
        XCTAssertEqual(Data(base64Encoded: encoded), pdfBytes)
    }

    func testBodySerializesToValidJSON() throws {
        let b = body(content: [.pdf(Data("%PDF".utf8), filename: nil), .text("go")])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))
    }
}

final class AnthropicResponseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        CredentialStore.set("test-key-not-real", for: .anthropicAPIKey)
    }

    override func tearDown() {
        CredentialStore.remove(.anthropicAPIKey)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> AnthropicClient {
        AnthropicClient(session: StubURLProtocol.makeSession())
    }

    private let tool = AnthropicClient.Tool(
        name: "record_workouts", description: "d",
        inputSchema: ["type": "object"]
    )

    func testDecodesToolUseInput() async throws {
        StubURLProtocol.responseBody = Data("""
        {
          "id": "msg_1",
          "model": "claude-opus-5",
          "stop_reason": "tool_use",
          "content": [
            {"type": "thinking", "thinking": ""},
            {"type": "tool_use", "id": "toolu_1", "name": "record_workouts",
             "input": {
               "workouts": [
                 {"sport": "run", "date": "2026-03-14", "time": "07:30",
                  "durationSeconds": 2700, "distanceMeters": 9000,
                  "avgHeartRate": 149, "maxHeartRate": null,
                  "elevationGainMeters": null, "calories": null,
                  "notes": "Easy", "sourceHint": "page 1, row 2", "confidence": 0.9}
               ],
               "documentSummary": "A weekly plan"
             }}
          ]
        }
        """.utf8)

        let result: ExtractionResult = try await client().callTool(
            content: [.text("go")], system: nil, tool: tool, as: ExtractionResult.self
        )

        XCTAssertEqual(result.documentSummary, "A weekly plan")
        XCTAssertEqual(result.workouts.count, 1)
        let w = result.workouts[0]
        XCTAssertEqual(w.mappedSport, .run)
        XCTAssertEqual(w.distanceMeters, 9000)
        XCTAssertEqual(w.avgHeartRate, 149)
        XCTAssertNil(w.maxHeartRate, "explicit nulls decode as nil")
        XCTAssertEqual(w.sourceHint, "page 1, row 2")
    }

    func testSendsRequiredHeaders() async throws {
        StubURLProtocol.responseBody = Data("""
        {"content":[{"type":"tool_use","name":"record_workouts",
         "input":{"workouts":[],"documentSummary":null}}],"stop_reason":"tool_use"}
        """.utf8)

        _ = try await client().callTool(
            content: [.text("go")], system: nil, tool: tool, as: ExtractionResult.self
        )

        let request = try XCTUnwrap(StubURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key-not-real")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"),
                       "server-side-fallback-2026-07-01")
    }

    /// A refusal is HTTP 200 — it must not be read as a successful extraction.
    func testRefusalStopReasonThrows() async {
        StubURLProtocol.responseBody = Data("""
        {"content": [], "stop_reason": "refusal",
         "stop_details": {"type": "refusal", "category": "other",
                          "explanation": "Declined."}}
        """.utf8)

        do {
            _ = try await client().callTool(
                content: [.text("go")], system: nil, tool: tool, as: ExtractionResult.self
            )
            XCTFail("expected refusal to throw")
        } catch let error as AnthropicClient.ClientError {
            guard case .refused = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testTextOnlyResponseThrows() async {
        StubURLProtocol.responseBody = Data("""
        {"content": [{"type": "text", "text": "I can't find any workouts."}],
         "stop_reason": "end_turn"}
        """.utf8)

        do {
            _ = try await client().callTool(
                content: [.text("go")], system: nil, tool: tool, as: ExtractionResult.self
            )
            XCTFail("expected noToolUse")
        } catch let error as AnthropicClient.ClientError {
            guard case .noToolUse = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testHTTPErrorSurfacesStatus() async {
        StubURLProtocol.statusCode = 429
        StubURLProtocol.responseBody = Data(#"{"error":{"message":"rate limited"}}"#.utf8)

        do {
            _ = try await client().callTool(
                content: [.text("go")], system: nil, tool: tool, as: ExtractionResult.self
            )
            XCTFail("expected httpStatus")
        } catch let error as AnthropicClient.ClientError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testMissingKeyThrowsBeforeAnyRequest() async {
        CredentialStore.remove(.anthropicAPIKey)
        do {
            _ = try await client().callTool(
                content: [.text("go")], system: nil, tool: tool, as: ExtractionResult.self
            )
            XCTFail("expected missingAPIKey")
        } catch let error as AnthropicClient.ClientError {
            guard case .missingAPIKey = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertNil(StubURLProtocol.capturedRequest, "must not hit the network")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}

final class ExtractedWorkoutTests: XCTestCase {

    private func workout(date: String = "2026-03-14", time: String? = nil,
                         distance: Double? = 9000, duration: Double? = 2700)
    -> ExtractedWorkout {
        ExtractedWorkout(
            sport: "run", date: date, time: time,
            durationSeconds: duration, distanceMeters: distance,
            avgHeartRate: nil, maxHeartRate: nil, elevationGainMeters: nil,
            calories: nil, notes: nil, sourceHint: nil, confidence: 0.9
        )
    }

    func testParsesDateAndTime() throws {
        let withTime = workout(time: "07:30")
        let date = try XCTUnwrap(withTime.startedAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                   from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 14)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 30)
    }

    func testDateOnlyStillParses() {
        XCTAssertNotNil(workout().startedAt)
    }

    func testInvalidDateIsNotImportable() {
        let bad = workout(date: "next Tuesday")
        XCTAssertNil(bad.startedAt)
        XCTAssertFalse(bad.isImportable)
    }

    func testNeedsDistanceOrDuration() {
        XCTAssertFalse(workout(distance: nil, duration: nil).isImportable)
        XCTAssertTrue(workout(distance: 5000, duration: nil).isImportable)
        XCTAssertTrue(workout(distance: nil, duration: 1800).isImportable)
        XCTAssertFalse(workout(distance: 0, duration: 0).isImportable)
    }

    func testExternalIDIsStablePerDocument() {
        let pdfA = Data("%PDF one".utf8)
        let pdfB = Data("%PDF two".utf8)
        let w = workout()

        let id1 = PDFWorkoutExtractor.externalID(for: w, documentData: pdfA)
        let id2 = PDFWorkoutExtractor.externalID(for: w, documentData: pdfA)
        let id3 = PDFWorkoutExtractor.externalID(for: w, documentData: pdfB)

        XCTAssertEqual(id1, id2, "same doc + same row must dedupe")
        XCTAssertNotEqual(id1, id3, "different documents stay distinct")
        XCTAssertTrue(id1.hasPrefix("pdf:"))
    }

    func testOversizeAndNonPDFRejectedBeforeAPICall() async {
        let extractor = PDFWorkoutExtractor()

        let huge = Data(repeating: 0x25, count: PDFWorkoutExtractor.maxRawBytes + 1)
        do {
            _ = try await extractor.extract(pdf: huge)
            XCTFail("expected tooLarge")
        } catch let error as PDFWorkoutExtractor.ExtractionError {
            guard case .tooLarge = error else { return XCTFail("wrong case: \(error)") }
        } catch { XCTFail("wrong error: \(error)") }

        do {
            _ = try await extractor.extract(pdf: Data("not a pdf".utf8))
            XCTFail("expected notAPDF")
        } catch let error as PDFWorkoutExtractor.ExtractionError {
            guard case .notAPDF = error else { return XCTFail("wrong case: \(error)") }
        } catch { XCTFail("wrong error: \(error)") }
    }
}

final class CredentialStoreTests: XCTestCase {

    override func tearDown() {
        CredentialStore.remove(.intervalsAPIKey)
        super.tearDown()
    }

    func testRoundTripAndRemoval() {
        CredentialStore.set("abc123", for: .intervalsAPIKey)
        XCTAssertEqual(CredentialStore.get(.intervalsAPIKey), "abc123")
        XCTAssertTrue(CredentialStore.has(.intervalsAPIKey))

        // Overwrite must update, not duplicate.
        CredentialStore.set("def456", for: .intervalsAPIKey)
        XCTAssertEqual(CredentialStore.get(.intervalsAPIKey), "def456")

        CredentialStore.remove(.intervalsAPIKey)
        XCTAssertNil(CredentialStore.get(.intervalsAPIKey))
        XCTAssertFalse(CredentialStore.has(.intervalsAPIKey))
    }

    func testEmptyValueClearsTheEntry() {
        CredentialStore.set("something", for: .intervalsAPIKey)
        CredentialStore.set("", for: .intervalsAPIKey)
        XCTAssertNil(CredentialStore.get(.intervalsAPIKey))
    }
}
