import SwiftUI

/// 방송 익스텐션이 App Group에 남긴 로그를 보여준다.
struct LogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "로그가 없습니다." : text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("진단 로그")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let url = Tessync.logURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url)
                }
                Button("새로고침", action: load)
                Button("지우기", role: .destructive, action: clear)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let url = Tessync.logURL else {
            text = "App Group 컨테이너에 접근할 수 없습니다. 서명 설정을 확인하세요."
            return
        }
        let previous = (try? String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // 최신 로그가 위로 오게 뒤집는다.
        text = (previous + current)
            .split(separator: "\n")
            .reversed()
            .joined(separator: "\n")
    }

    private func clear() {
        guard let url = Tessync.logURL else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        load()
    }
}
