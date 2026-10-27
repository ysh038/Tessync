import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private let log = DiagnosticsLog.shared
    private var server: MirrorServer?
    private var pipeline: FramePipeline?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log.write(String(format: "broadcast started (mem %.1fMB)", MemoryMonitor.footprintMB()))
        let server = MirrorServer(log: log)
        let pipeline = FramePipeline(server: server, log: log)
        server.statusProvider = { [weak pipeline] in pipeline?.status() ?? [:] }
        do {
            try server.start()
        } catch {
            log.write("server start failed: \(error)")
            finishBroadcastWithError(error)
            return
        }
        pipeline.start()
        self.server = server
        self.pipeline = pipeline
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
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        pipeline?.submit(sampleBuffer)
    }
}
