import CoreMedia
import Foundation
import ReplayKit
import VideoToolbox

/// ReplayKit 프레임 → 다운스케일 → JPEG 인코딩 → 서버 전송.
///
/// 익스텐션 메모리 한도(약 50MB)를 넘지 않는 것이 최우선이다.
/// - 동시에 처리하는 프레임은 1개뿐이다. 바쁘면 새 프레임을 버리고, 버린 것 중 가장 최근 1개만 들고 있다가 나중에 보낸다.
/// - 전송이 밀리면(서버가 .none) 인코딩하지 않는다.
/// - 메모리, 발열, 전송 지연을 보고 화질 단계를 자동으로 바꾼다.
final class FramePipeline {
    struct Profile {
        let maxSide: Int
        let fps: Double
        let quality: Double
    }

    static let profiles = [
        Profile(maxSide: 1280, fps: 30, quality: 0.6),
        Profile(maxSide: 1080, fps: 24, quality: 0.5),
        Profile(maxSide: 960, fps: 20, quality: 0.45),
        Profile(maxSide: 720, fps: 15, quality: 0.4),
    ]

    private let server: MirrorServer
    private let log: DiagnosticsLog
    /// 축소 프레임마다 인코딩 큐에서 불린다. 터치 조작이 포인터를 찾는 데 쓴다.
    var frameObserver: ((CVPixelBuffer, UInt8) -> Void)?
    private let encodeQueue = DispatchQueue(label: "tessync.encode")
    private var monitor: DispatchSourceTimer?

    private struct Frame {
        let pixelBuffer: CVPixelBuffer
        let orientation: UInt8
        let timestamp: CMTime
    }

    // submit()이 ReplayKit 스레드에서 불리므로 아래 값은 lock으로 보호한다.
    private let lock = NSLock()
    private var busy = false
    // 건너뛴 프레임 중 가장 최근 1개. ReplayKit은 화면이 바뀔 때만 프레임을 주므로, 화면이 멈추기 직전 프레임을
    // 건너뛰면 마지막 화면이 영영 안 간다(스크롤이 멈춘 뒤 테슬라에 조금 전 화면이 남는다).
    private var trailing: Frame?
    private var trailingScheduled = false
    private var lastAccepted: TimeInterval = 0
    private var level = 0
    private var encodedInWindow = 0
    private var backpressureInWindow = 0
    private var lastFPS = 0.0
    private var lastMemory = 0.0

    // encodeQueue 전용
    private var scaler: Scaler?
    private var encoder: JPEGEncoder?
    private var encoderFailureLogged = false
    private var lastLevelChange = Date()
    private var lastStatsLog = Date()

    init(server: MirrorServer, log: DiagnosticsLog) {
        self.server = server
        self.log = log
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.evaluate(window: 2) }
        timer.resume()
        monitor = timer
    }

    func stop() {
        monitor?.cancel()
    }

    /// 하트비트에 실어 브라우저 디버그 화면에 보여줄 값.
    func status() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["lvl": level, "fps": (lastFPS * 10).rounded() / 10, "mem": lastMemory.rounded()]
    }

    func submit(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = Frame(pixelBuffer: pixelBuffer,
                          orientation: Self.orientation(of: sampleBuffer),
                          timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        offer(frame, isRetry: false)
    }

    private func offer(_ frame: Frame, isRetry: Bool) {
        let demand = server.frameDemand
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        if demand == .none {
            // 재시도까지 세면 밀림 비율이 부풀어 화질 단계가 괜히 내려간다.
            if !isRetry { backpressureInWindow += 1 }
            holdTrailing(frame, retryAfter: 0.1)
            lock.unlock()
            return
        }
        let profile = Self.profiles[level]
        // 보는 사람이 없을 때는 새 접속 때 바로 보여줄 프레임만 1초에 한 번 갱신한다.
        let minInterval = demand == .idle ? 1.0 : 1.0 / profile.fps
        let wait = lastAccepted + minInterval * 0.9 - now
        if busy || wait > 0 {
            holdTrailing(frame, retryAfter: max(wait, 0.02))
            lock.unlock()
            return
        }
        busy = true
        lastAccepted = now
        trailing = nil
        lock.unlock()

        encodeQueue.async { [self] in
            let packet = encode(frame.pixelBuffer, orientation: frame.orientation, timestamp: frame.timestamp, profile: profile)
            if let packet {
                server.publish(frame: packet)
            }
            finishFrame(encoded: packet != nil)
        }
    }

    /// lock을 잡은 상태에서 부른다. 더 새 프레임이 오면 덮어쓰므로 들고 있는 프레임은 항상 1개다.
    private func holdTrailing(_ frame: Frame, retryAfter delay: Double) {
        trailing = frame
        guard !trailingScheduled else { return }
        trailingScheduled = true
        encodeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushTrailing()
        }
    }

    private func flushTrailing() {
        lock.lock()
        trailingScheduled = false
        let frame = trailing
        trailing = nil
        lock.unlock()
        if let frame {
            offer(frame, isRetry: true)
        }
    }

    private func finishFrame(encoded: Bool) {
        lock.lock()
        busy = false
        if encoded { encodedInWindow += 1 }
        lock.unlock()
    }

    // MARK: - Encoding (encodeQueue)

    private func encode(_ source: CVPixelBuffer, orientation: UInt8, timestamp: CMTime, profile: Profile) -> Data? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let scale = min(1, Double(profile.maxSide) / Double(max(width, height)))
        // YUV 4:2:0은 짝수 크기가 필요하다.
        let targetWidth = Int(Double(width) * scale) & ~1
        let targetHeight = Int(Double(height) * scale) & ~1

        if scaler?.matches(width: targetWidth, height: targetHeight, format: CVPixelBufferGetPixelFormatType(source)) != true {
            scaler = Scaler(width: targetWidth, height: targetHeight, format: CVPixelBufferGetPixelFormatType(source))
            if scaler == nil { log.write("scaler create failed \(targetWidth)x\(targetHeight)") }
        }
        if encoder?.width != targetWidth || encoder?.height != targetHeight {
            encoder = JPEGEncoder(width: targetWidth, height: targetHeight, quality: profile.quality)
            if encoder == nil {
                if !encoderFailureLogged { log.write("jpeg encoder create failed \(targetWidth)x\(targetHeight)") }
                encoderFailureLogged = true
            } else {
                log.write("encoder \(targetWidth)x\(targetHeight) q=\(profile.quality)")
            }
        }
        guard let scaler, let encoder, let scaled = scaler.scale(source) else { return nil }
        frameObserver?(scaled, orientation)
        encoder.quality = profile.quality
        return encoder.encode(scaled, timestamp: timestamp, header: [1, orientation])
    }

    private static func orientation(of sampleBuffer: CMSampleBuffer) -> UInt8 {
        let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber
        return value?.uint8Value ?? 1
    }

    // MARK: - Adaptation (encodeQueue)

    private func evaluate(window: Double) {
        let memory = MemoryMonitor.footprintMB()
        let thermal = ProcessInfo.processInfo.thermalState

        lock.lock()
        let encoded = encodedInWindow
        let backpressure = backpressureInWindow
        encodedInWindow = 0
        backpressureInWindow = 0
        lastFPS = Double(encoded) / window
        lastMemory = memory
        let current = level
        lock.unlock()

        let thermalFloor: Int
        switch thermal {
        case .critical: thermalFloor = 3
        case .serious: thermalFloor = 2
        default: thermalFloor = 0
        }
        let backpressureRatio = encoded + backpressure == 0 ? 0 : Double(backpressure) / Double(encoded + backpressure)

        var target = max(current, thermalFloor)
        var reason = "thermal \(thermal.rawValue)"
        if memory > 38 {
            target = max(target, current + 1)
            reason = "memory \(Int(memory))MB"
        } else if backpressureRatio > 0.5 {
            target = max(target, current + 1)
            reason = "network backlog \(Int(backpressureRatio * 100))%"
        } else if memory < 30, backpressureRatio < 0.1, Date().timeIntervalSince(lastLevelChange) > 20 {
            target = max(thermalFloor, current - 1)
            reason = "recovered"
        }
        target = min(max(target, 0), Self.profiles.count - 1)

        if target != current {
            lock.lock()
            level = target
            lock.unlock()
            lastLevelChange = Date()
            log.write("level \(current) -> \(target) (\(reason))")
        }
        if Date().timeIntervalSince(lastStatsLog) >= 10 {
            lastStatsLog = Date()
            log.write(String(format: "stats lvl=%d fps=%.1f mem=%.1fMB thermal=%d backlog=%.0f%%",
                             target, lastFPS, memory, thermal.rawValue, backpressureRatio * 100))
        }
    }
}

/// 같은 픽셀 포맷 그대로 크기만 줄인다. 버퍼는 풀에서 재사용한다.
private final class Scaler {
    private let width: Int
    private let height: Int
    private let format: OSType
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int, format: OSType) {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 2]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            VTPixelTransferSessionInvalidate(session)
            return nil
        }
        self.width = width
        self.height = height
        self.format = format
        self.session = session
        self.pool = pool
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    func matches(width: Int, height: Int, format: OSType) -> Bool {
        self.width == width && self.height == height && self.format == format
    }

    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else { return nil }
        return output
    }
}

/// VideoToolbox 하드웨어 JPEG 인코더. 한 프레임씩 동기적으로 인코딩한다.
private final class JPEGEncoder {
    let width: Int
    let height: Int
    private let session: VTCompressionSession

    var quality: Double {
        didSet {
            guard quality != oldValue else { return }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        }
    }

    init?(width: Int, height: Int, quality: Double) {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_JPEG,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.width = width
        self.height = height
        self.session = session
        self.quality = quality
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// header 바이트 뒤에 JPEG 데이터를 붙인 패킷을 돌려준다.
    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime, header: [UInt8]) -> Data? {
        var packet: Data?
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: header.count + length)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                raw.copyBytes(from: header)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base + header.count)
            }
            packet = data
        }
        guard status == noErr else { return nil }
        // 출력 콜백이 끝날 때까지 기다린다.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return packet
    }
}
