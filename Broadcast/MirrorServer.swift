import Foundation
import Network

/// 테슬라 브라우저가 접속하는 서버.
/// - 8080: 플레이어/점검 페이지를 주는 최소 HTTP 서버
/// - 8081: 영상 프레임과 하트비트를 보내는 WebSocket
///
/// 프레임 패킷: [0]=1(JPEG) [1]=EXIF orientation(1~8) [2...]=JPEG 데이터
/// 텍스트 메시지: {"t":"hb",...} 1초마다, {"t":"bye","reason":...} 종료 시
final class MirrorServer {
    enum FrameDemand {
        /// 접속한 브라우저가 있고 전송 여유가 있음
        case live
        /// 접속한 브라우저가 없음. 새 접속 때 바로 보여줄 프레임만 가끔 갱신
        case idle
        /// 전송이 밀려 있음. 인코딩하지 않고 버림
        case none
    }

    static let maxInFlightFrames = 2

    let queue = DispatchQueue(label: "tessync.server")
    var statusProvider: (() -> [String: Any])?

    private let log: DiagnosticsLog
    private let webRoot: URL?
    private var httpListener: NWListener?
    private var streamListener: NWListener?
    private var client: StreamClient?
    private var heartbeat: DispatchSourceTimer?
    private var heartbeatSeq = 0
    private var lastFrame: Data?
    private var stopped = false

    private let demandLock = NSLock()
    private var _frameDemand = FrameDemand.idle

    init(log: DiagnosticsLog) {
        self.log = log
        webRoot = Bundle(for: MirrorServer.self).url(forResource: "web", withExtension: nil)
    }

    /// ReplayKit 스레드에서 매 프레임 읽는 값이라 잠금으로 보호한다.
    var frameDemand: FrameDemand {
        demandLock.lock()
        defer { demandLock.unlock() }
        return _frameDemand
    }

    func start() throws {
        httpListener = try makeListener(port: Tessync.httpPort, parameters: Self.tcpParameters()) { [weak self] in
            self?.handleHTTP($0)
        }
        let streamParameters = Self.tcpParameters()
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        streamParameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        streamListener = try makeListener(port: Tessync.streamPort, parameters: streamParameters) { [weak self] in
            self?.acceptStream($0)
        }
        startHeartbeat()
    }

    func stop(reason: String) {
        queue.sync {
            stopped = true
            heartbeat?.cancel()
            httpListener?.cancel()
            streamListener?.cancel()
            if let client, client.isReady {
                // 브라우저가 "방송 종료"를 바로 표시할 수 있게 알린 뒤 닫는다.
                let connection = client.connection
                sendText(["t": "bye", "reason": reason], to: client) { connection.cancel() }
            } else {
                client?.connection.cancel()
            }
            client = nil
        }
    }

    /// 인코딩된 프레임을 넘겨받아 현재 클라이언트에 보낸다.
    func publish(frame: Data) {
        queue.async { [self] in
            lastFrame = frame
            guard let client, client.isReady, client.inFlight < Self.maxInFlightFrames else { return }
            send(frame: frame, to: client)
        }
    }

    // MARK: - Listener

    private static func tcpParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func makeListener(port: UInt16, parameters: NWParameters, onConnection: @escaping (NWConnection) -> Void) throws -> NWListener {
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = onConnection
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log.write("listener :\(port) ready")
            case .failed(let error):
                log.write("listener :\(port) failed: \(error), retrying")
                listener.cancel()
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.restartListener(port: port, parameters: parameters, onConnection: onConnection)
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func restartListener(port: UInt16, parameters: NWParameters, onConnection: @escaping (NWConnection) -> Void) {
        guard !stopped else { return }
        do {
            let listener = try makeListener(port: port, parameters: parameters, onConnection: onConnection)
            if port == Tessync.httpPort { httpListener = listener } else { streamListener = listener }
        } catch {
            log.write("listener :\(port) restart failed: \(error)")
        }
    }

    // MARK: - HTTP

    private func handleHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTP(connection, buffer: Data())
    }

    private func receiveHTTP(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(parsing: buffer) {
                respond(to: request, on: connection)
            } else if isComplete || error != nil || buffer.count > 256 * 1024 {
                connection.cancel()
            } else {
                receiveHTTP(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            serveFile("index.html", type: "text/html; charset=utf-8", on: connection)
        case ("GET", "/player.js"):
            serveFile("player.js", type: "text/javascript; charset=utf-8", on: connection)
        case ("GET", "/probe"), ("GET", "/probe.html"):
            serveFile("probe.html", type: "text/html; charset=utf-8", on: connection)
        case ("GET", "/log"):
            sendHTTP(connection, status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data(log.read().utf8))
        case ("POST", "/report"):
            log.write("probe report: \(String(decoding: request.body.prefix(16 * 1024), as: UTF8.self))")
            sendHTTP(connection, status: "204 No Content", contentType: nil, body: Data())
        default:
            sendHTTP(connection, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    private func serveFile(_ name: String, type: String, on connection: NWConnection) {
        guard let url = webRoot?.appendingPathComponent(name), let body = try? Data(contentsOf: url) else {
            sendHTTP(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data("missing \(name)".utf8))
            return
        }
        sendHTTP(connection, status: "200 OK", contentType: type, body: body)
    }

    private func sendHTTP(_ connection: NWConnection, status: String, contentType: String?, body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Stream

    private func acceptStream(_ connection: NWConnection) {
        let newClient = StreamClient(connection: connection)
        if let old = client {
            // 테슬라 브라우저가 재접속하면 이전 연결은 이미 죽어 있는 경우가 많다. 최신 접속만 유지한다.
            log.write("client \(old.id) replaced by \(newClient.id)")
            old.connection.cancel()
        }
        client = newClient
        updateDemand()

        connection.stateUpdateHandler = { [weak self, weak newClient] state in
            guard let self, let newClient else { return }
            switch state {
            case .ready:
                newClient.isReady = true
                log.write("client \(newClient.id) connected from \(connection.endpoint)")
                if client === newClient, let lastFrame {
                    send(frame: lastFrame, to: newClient)
                }
                updateDemand()
            case .failed(let error):
                log.write("client \(newClient.id) failed: \(error)")
                drop(newClient)
            case .cancelled:
                drop(newClient)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMessages(from: newClient)
    }

    private func drop(_ dropped: StreamClient) {
        dropped.isReady = false
        if client === dropped {
            log.write("client \(dropped.id) disconnected")
            client = nil
        }
        updateDemand()
    }

    private func receiveMessages(from client: StreamClient) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                client.connection.cancel()
                return
            }
            if metadata?.opcode == .text, let data {
                log.write("client \(client.id): \(String(decoding: data.prefix(1024), as: UTF8.self))")
            }
            if error == nil {
                receiveMessages(from: client)
            }
        }
    }

    private func send(frame: Data, to client: StreamClient) {
        client.inFlight += 1
        updateDemand()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        client.connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            client.inFlight -= 1
            updateDemand()
        })
    }

    private func sendText(_ object: [String: Any], to client: StreamClient, then completion: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in completion?() })
    }

    private func updateDemand() {
        let demand: FrameDemand
        if let client, client.isReady {
            demand = client.inFlight < Self.maxInFlightFrames ? .live : .none
        } else {
            demand = .idle
        }
        demandLock.lock()
        _frameDemand = demand
        demandLock.unlock()
    }

    // MARK: - Heartbeat

    /// 화면 변화가 없으면 프레임이 오지 않으므로, 브라우저는 이 하트비트로 연결 상태를 판단한다.
    /// 핫스팟은 90초 무통신 기기를 끊기 때문에 이 트래픽이 연결 유지 역할도 한다.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let client, client.isReady else { return }
            heartbeatSeq += 1
            var payload: [String: Any] = ["t": "hb", "seq": heartbeatSeq]
            if let status = statusProvider?() {
                payload.merge(status) { $1 }
            }
            sendText(payload, to: client)
        }
        timer.resume()
        heartbeat = timer
    }
}

private final class StreamClient {
    private static var nextID = 0

    let id: Int
    let connection: NWConnection
    var isReady = false
    var inFlight = 0

    init(connection: NWConnection) {
        Self.nextID += 1
        id = Self.nextID
        self.connection = connection
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// 요청 전체(헤더 + Content-Length 만큼의 본문)가 도착했을 때만 성공한다.
    init?(parsing buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= contentLength else { return nil }

        method = String(requestLine[0])
        path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "/")
        body = buffer[bodyStart..<(bodyStart + contentLength)]
    }
}
