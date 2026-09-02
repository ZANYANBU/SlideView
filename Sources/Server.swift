import Foundation
import Network

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
    }
    static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(s.utf8))
    }
    static func file(_ url: URL, type: String) -> HTTPResponse {
        guard let d = try? Data(contentsOf: url) else { return .text("not found", status: 404) }
        return HTTPResponse(status: 200, headers: ["Content-Type": type], body: d)
    }
    static func bytes(_ d: Data, type: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": type], body: d)
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
}

final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "slideview.http", attributes: .concurrent)
    private(set) var port: UInt16 = 0
    var handler: ((HTTPRequest) -> HTTPResponse)?

    /// Bind a stable port when we can. The web UI keeps reading position, stars
    /// and appearance in localStorage, which the browser keys by origin — a
    /// random port every launch would silently wipe all of it.
    func start(preferred: [UInt16] = [47823, 47824, 47825, 47826, 47827]) throws -> UInt16 {
        for p in preferred {
            if let got = try? bind(p) { port = got; return got }
        }
        let got = try bind(0)      // last resort: let the OS choose
        port = got
        return got
    }

    private func bind(_ requested: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                                 port: NWEndpoint.Port(rawValue: requested) ?? .any)
        let l = try NWListener(using: params)

        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: sem.signal()
            case .failed(let e), .waiting(let e): failure = e; sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.read(conn, buffer: Data())
        }
        l.start(queue: queue)

        if sem.wait(timeout: .now() + 3) == .timedOut { l.cancel(); throw Self.err("timed out binding port \(requested)") }
        if let failure { l.cancel(); throw failure }
        guard let got = l.port?.rawValue, got != 0 else { l.cancel(); throw Self.err("no port assigned") }
        listener?.cancel()
        listener = l
        return got
    }

    private static func err(_ m: String) -> Error {
        NSError(domain: "SlideView", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                self.respond(conn, head: head)
                return
            }
            if error != nil || isComplete || buf.count > 128 * 1024 { conn.cancel(); return }
            self.read(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        var res = HTTPResponse.text("bad request", status: 400)

        if parts.count >= 2 {
            let method = String(parts[0])
            let raw = String(parts[1])
            var path = raw
            var query: [String: String] = [:]
            if let qi = raw.firstIndex(of: "?") {
                path = String(raw[raw.startIndex..<qi])
                let qs = String(raw[raw.index(after: qi)...])
                for pair in qs.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let v = kv.count > 1
                        ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                        : ""
                    query[k] = v
                }
            }
            path = path.removingPercentEncoding ?? path
            let req = HTTPRequest(method: method, path: path, query: query)
            res = handler?(req) ?? .text("not found", status: 404)
        }

        var out = "HTTP/1.1 \(res.status) \(Self.reason(res.status))\r\n"
        var headers = res.headers
        headers["Content-Length"] = String(res.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"

        var payload = Data(out.utf8)
        payload.append(res.body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
