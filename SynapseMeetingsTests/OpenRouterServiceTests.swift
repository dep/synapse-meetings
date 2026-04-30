import XCTest
@testable import Synapse_Meetings

final class OpenRouterServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeService(model: String = OpenRouterService.defaultModel) -> OpenRouterService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return OpenRouterService(apiKey: "test-key", model: model, session: session)
    }

    // MARK: - Request shape

    func testRequest_targetsChatCompletionsEndpoint() async throws {
        let exp = expectation(description: "request observed")
        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            exp.fulfill()
            return Self.successResponse(content: "# Untitled\n\nbody")
        }
        _ = try await makeService().summarize(
            transcript: "hello",
            liveNotes: "",
            attendees: [],
            speakerLabeled: false,
            suggestedTitle: nil
        )
        await fulfillment(of: [exp], timeout: 1)
    }

    func testRequest_includesBearerAuthHeader() async throws {
        let exp = expectation(description: "request observed")
        StubURLProtocol.requestHandler = { request in
            // URLSession may move Authorization into "Authorization" or merge headers — read both.
            let auth = request.value(forHTTPHeaderField: "Authorization")
                ?? request.allHTTPHeaderFields?["Authorization"]
            XCTAssertEqual(auth, "Bearer test-key")
            exp.fulfill()
            return Self.successResponse(content: "# Title\n\nbody")
        }
        _ = try await makeService().summarize(
            transcript: "hello",
            liveNotes: "",
            attendees: [],
            speakerLabeled: false,
            suggestedTitle: nil
        )
        await fulfillment(of: [exp], timeout: 1)
    }

    func testRequest_bodyHasSystemMessageAndModel() async throws {
        let exp = expectation(description: "request observed")
        StubURLProtocol.requestHandler = { request in
            let body = Self.readBody(request)
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["model"] as? String, "google/gemma-4-31b-it:free")
            let messages = json?["messages"] as? [[String: Any]] ?? []
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            // The system content should reference the H1 instruction, regardless of overrides.
            let sys = (messages.first?["content"] as? String) ?? ""
            XCTAssertTrue(sys.contains("H1"))
            XCTAssertEqual(messages.last?["role"] as? String, "user")
            let user = (messages.last?["content"] as? String) ?? ""
            XCTAssertTrue(user.contains("transcript-marker-xyz"))
            exp.fulfill()
            return Self.successResponse(content: "# Title\n\nbody")
        }
        _ = try await makeService(model: "google/gemma-4-31b-it:free").summarize(
            transcript: "transcript-marker-xyz",
            liveNotes: "",
            attendees: [],
            speakerLabeled: false,
            suggestedTitle: nil
        )
        await fulfillment(of: [exp], timeout: 1)
    }

    // MARK: - Response parsing

    func testResponse_parsesContentFromFirstChoice() async throws {
        StubURLProtocol.requestHandler = { _ in
            Self.successResponse(content: "# Hello\n\nA real summary.")
        }
        let result = try await makeService().summarize(
            transcript: "x",
            liveNotes: "",
            attendees: [],
            speakerLabeled: false,
            suggestedTitle: nil
        )
        XCTAssertEqual(result, "# Hello\n\nA real summary.")
    }

    // MARK: - Error paths

    func testHTTPError_throwsWithStatusAndBody() async {
        StubURLProtocol.requestHandler = { _ in
            let status = HTTPURLResponse(
                url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (status, Data("{\"error\":\"unauthorized\"}".utf8))
        }
        do {
            _ = try await makeService().summarize(
                transcript: "x",
                liveNotes: "",
                attendees: [],
                speakerLabeled: false,
                suggestedTitle: nil
            )
            XCTFail("expected throw")
        } catch let OpenRouterError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("unauthorized"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyChoices_throwsEmpty() async {
        StubURLProtocol.requestHandler = { _ in
            let status = HTTPURLResponse(
                url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (status, Data("{\"choices\":[]}".utf8))
        }
        do {
            _ = try await makeService().summarize(
                transcript: "x",
                liveNotes: "",
                attendees: [],
                speakerLabeled: false,
                suggestedTitle: nil
            )
            XCTFail("expected throw")
        } catch OpenRouterError.empty {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Static config

    func testCuratedFreeModels_includesDefault() {
        XCTAssertEqual(OpenRouterService.curatedFreeModels.first, OpenRouterService.defaultModel)
        XCTAssertTrue(OpenRouterService.curatedFreeModels.contains("google/gemma-4-31b-it:free"))
    }

    // MARK: - Helpers

    private static func successResponse(content: String) -> (HTTPURLResponse, Data) {
        let status = HTTPURLResponse(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        let payload: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": content]]
            ]
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return (status, body)
    }

    /// URLProtocol receives the body via httpBodyStream rather than httpBody once
    /// URLSession handles it. Read whichever side is populated.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

/// Minimal URLProtocol stub for test injection. Set `requestHandler` to map
/// each incoming URLRequest to a (response, body) pair.
final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
