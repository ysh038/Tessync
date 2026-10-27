import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private let log = DiagnosticsLog.shared
    private var server: MirrorServer?
    private var pipeline: FramePipeline?
    private var touchLink: TouchLink?
    private var touch: TouchController?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log.write(String(format: "broadcast started (mem %.1fMB)", MemoryMonitor.footprintMB()))
        let server = MirrorServer(log: log)
        let pipeline = FramePipeline(server: server, log: log)
        let touchLink = TouchLink(log: log)
        let touch = TouchController(link: touchLink, log: log)
        pipeline.frameObserver = { [weak touch] buffer, orientation in touch?.observe(frame: buffer, orientation: orientation) }
        server.onTap = { [weak touch] u, v in touch?.tap(u: u, v: v) }
        server.statusProvider = { [weak pipeline, weak touchLink] in
            var status = pipeline?.status() ?? [:]
            status["touch"] = touchLink?.statusCode ?? 0
            return status
        }
        do {
            try server.start()
        } catch {
            log.write("server start failed: \(error)")
            finishBroadcastWithError(error)
            return
        }
        pipeline.start()
        // 터치 장치(ESP32)는 선택 사항이다. 포트를 못 열어도 미러링은 계속한다.
        do {
            try touchLink.start()
        } catch {
            log.write("touch listener start failed: \(error)")
        }
        self.server = server
        self.pipeline = pipeline
        self.touchLink = touchLink
        self.touch = touch
    }

    override func broadcastPaused() {
        log.write("broadcast paused")
    }

    override func broadcastResumed() {
        log.write("broadcast resumed")
    }

    override func broadcastFinished() {
        // 화면 잠금, 제어센터에서 중지, 다른 방송 시작 등으로 불린다.
        log.write(String(format: "broadcast finished (mem %.1fMB)", MemoryMonitor.footprintMB()))
        pipeline?.stop()
        server?.stop(reason: "finished")
        touchLink?.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        pipeline?.submit(sampleBuffer)
    }
}
