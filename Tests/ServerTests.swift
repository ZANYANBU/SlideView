import XCTest
@testable import SlideViewCore

/// The app's UI talks to this local server, so these go over a real socket.
final class ServerTests: XCTestCase {
    private var server: HTTPServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        server = HTTPServer()
        port = try server.start(preferred: [])          // let the OS choose a free port
    }

    override func tearDown() {
        server = nil
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var result: Result<(HTTPURLResponse, Data), Error>?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse { result = .success((http, data ?? Data())) }
            else { result = .failure(error ?? URLError(.badServerResponse)) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success, "no answer from the server")
        return try XCTUnwrap(result).get()
    }

    private func echo() {
        server.handler = { request in
            .json(["method": request.method, "path": request.path, "query": request.query,
                   "bytes": request.body.count, "text": String(request.bodyText.prefix(40))])
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testItBindsToAPortOnThisMachine() {
        XCTAssertNotEqual(port, 0)
        XCTAssertEqual(server.port, port)
    }

    func testPathAndQueryAreDecoded() throws {
        echo()
        let (response, data) = try send("GET", "/api/doc%20one?name=Unit%201&q=a+b&flag&x=1%3D1")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let seen = try object(data)
        XCTAssertEqual(seen["method"] as? String, "GET")
        XCTAssertEqual(seen["path"] as? String, "/api/doc one")
        XCTAssertEqual(seen["query"] as? [String: String], ["name": "Unit 1", "q": "a b", "flag": "", "x": "1=1"])
    }

    func testASmallPostBodyArrives() throws {
        echo()
        let (_, data) = try send("POST", "/api/note", body: Data("OFC = optical fibre cable".utf8))
        let seen = try object(data)
        XCTAssertEqual(seen["method"] as? String, "POST")
        XCTAssertEqual(seen["text"] as? String, "OFC = optical fibre cable")
    }

    func testALargePostBodyArrivesWhole() throws {
        echo()
        let size = 3 * 1024 * 1024                      // a drawing with an embedded image
        let (response, data) = try send("POST", "/api/save", body: Data(repeating: 0x61, count: size))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try object(data)["bytes"] as? Int, size)
    }

    func testStatusAndBodyComeFromTheHandler() throws {
        server.handler = { _ in .text("no such document", status: 404) }
        let (response, data) = try send("GET", "/api/doc")
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "no such document")
    }

    func testResponsesAreNotCachedUnlessTheHandlerSaysSo() throws {
        server.handler = { request in
            var response = HTTPResponse.bytes(Data([1, 2, 3]), type: "application/octet-stream")
            if request.path == "/static" { response.headers["Cache-Control"] = "max-age=3600" }
            return response
        }
        let (fresh, body) = try send("GET", "/api/state")
        XCTAssertEqual(fresh.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(body, Data([1, 2, 3]))

        let (cached, _) = try send("GET", "/static")
        XCTAssertEqual(cached.value(forHTTPHeaderField: "Cache-Control"), "max-age=3600")
    }

    func testWithoutAHandlerEverythingIs404() throws {
        let (response, _) = try send("GET", "/anything")
        XCTAssertEqual(response.statusCode, 404)
    }

    func testAMissingFileIs404() {
        let response = HTTPResponse.file(URL(fileURLWithPath: "/nonexistent/slideview/file.css"), type: "text/css")
        XCTAssertEqual(response.status, 404)
    }
}
