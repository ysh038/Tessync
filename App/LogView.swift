import SwiftUI

/// 방송 익스텐션이 남긴 진단 로그.
/// App Group이 있으면 공유 파일을 읽고, 없으면(무료 계정) 방송 중인 익스텐션 서버에서 받아온다.
struct LogView: View {
    @State private var text = ""
    @State private var loading = false

    private var usesSharedFile: Bool { Tessync.sharedContainer != nil }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                Text(text.isEmpty ? (loading ? "불러오는 중…" : "로그가 없어요.") : text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .card()
                    .padding(20)
            }
            .refreshable { await load() }
        }
        .navigationTitle("진단 로그")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !text.isEmpty {
                    ShareLink(item: text)
                }
                if usesSharedFile {
                    Button("지우기", role: .destructive, action: clear)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if usesSharedFile, let url = Tessync.logURL {
            let previous = (try? String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // 최신 로그가 위로 오게 뒤집는다.
            text = (previous + current).split(separator: "\n").reversed().joined(separator: "\n")
        } else {
            text = await Self.fetchFromBroadcast()
        }
    }

    /// 익스텐션 서버는 이미 최신 로그가 위로 오게 정렬해서 준다.
    private static func fetchFromBroadcast() async -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Tessync.httpPort)/log")!)
        request.timeoutInterval = 2
        guard let result = try? await URLSession.shared.data(for: request) else {
            return "방송이 켜져 있을 때만 로그를 볼 수 있어요.\n화면 방송을 시작한 뒤 아래로 당겨 새로고침하세요."
        }
        return String(decoding: result.0, as: UTF8.self)
    }

    private func clear() {
        guard let url = Tessync.logURL else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        text = ""
    }
}
