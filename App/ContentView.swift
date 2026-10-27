import SwiftUI

struct ContentView: View {
    @StateObject private var status = StatusModel()
    @StateObject private var picker = BroadcastPicker()
    @State private var toast: String?
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                // 시스템 방송 선택 창을 띄우려면 피커 뷰가 화면 계층에 있어야 한다.
                BroadcastPickerHost(picker: picker).frame(width: 1, height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        if status.lowPowerMode {
                            lowPowerBanner
                        }
                        stepsCard
                        addressCard
                        if status.isBroadcasting {
                            liveCard
                        }
                        tipsCard
                        toolsCard
                        networkCard
                        Text("운전 중 영상 시청은 도로교통법 위반입니다. 내비게이션 용도로만 사용하세요.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 128)
                }

                bottomBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showLog) { LogView() }
            .overlay(alignment: .top) { toastView }
        }
        .onAppear { status.start() }
        .onDisappear { status.stop() }
        .animation(.easeInOut(duration: 0.25), value: status.stage)
        .animation(.easeInOut(duration: 0.25), value: status.isBroadcasting)
    }

    // MARK: - 헤더

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tessync")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.sage)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var title: String {
        switch status.stage {
        case .connectHotspot: return "테슬라를 iPhone 핫스팟에\n연결해 주세요"
        case .startBroadcast: return "연결됐어요\n화면 방송을 시작할까요?"
        case .openBrowser: return "테슬라 브라우저에서\n주소를 열어 주세요"
        case .mirroring: return "테슬라에\n화면을 보여주고 있어요"
        }
    }

    private var subtitle: String {
        switch status.stage {
        case .connectHotspot: return "개인용 핫스팟을 켜고, 테슬라 Wi-Fi 목록에서 이 iPhone을 고르면 돼요."
        case .startBroadcast: return "아래 버튼을 누르고 Tessync를 선택하세요."
        case .openBrowser: return "주소를 한 번 열어두면 다음부터는 자동으로 다시 연결돼요."
        case .mirroring: return "iPhone 화면을 잠그지 마세요. 잠그면 방송이 꺼져요."
        }
    }

    // MARK: - 카드

    private var lowPowerBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("저전력 모드가 켜져 있어요")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("화면이 끊길 수 있어요. 제어 센터에서 꺼주세요.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepRow(number: 1, title: "핫스팟 연결", detail: "테슬라 Wi-Fi → 이 iPhone", state: stepState(.connectHotspot))
            StepRow(number: 2, title: "화면 방송 시작", detail: "아래 버튼 → Tessync 선택", state: stepState(.startBroadcast))
            StepRow(number: 3, title: "테슬라 브라우저에서 열기", detail: status.playerAddress, state: stepState(.openBrowser))
        }
        .card()
    }

    private func stepState(_ step: StatusModel.Stage) -> StepRow.Progress {
        if status.isDone(step) { return .done }
        if status.stage == step { return .current }
        return .todo
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("테슬라 브라우저 주소")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                Text(status.playerAddress)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("복사") { copy(status.playerURL, message: "주소를 복사했어요") }
                    .buttonStyle(PillButtonStyle())
            }
            if status.hotspotAddress == nil, status.wifiAddress != nil {
                Text("지금은 집 Wi-Fi 주소예요. 같은 Wi-Fi의 컴퓨터 브라우저로 테스트할 수 있어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            } else if let computer = status.computerAddress {
                Text("핫스팟에 연결한 컴퓨터로 테스트할 때는 \(computer)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .card()
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.positive)
                    .frame(width: 8, height: 8)
                Text("방송 중")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            HStack(spacing: 0) {
                Metric(title: "보는 화면", value: "\(status.viewerCount)")
                Metric(title: "초당 프레임", value: status.server?.fps.map { String(format: "%.0f", $0) } ?? "-")
                Metric(title: "메모리", value: status.server?.mem.map { String(format: "%.0fMB", $0) } ?? "-")
            }
        }
        .card()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("끊김 없이 쓰려면")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 10)
            TipRow(icon: "car.fill", title: "테슬라 주행 중 Wi-Fi 끄기 해제", detail: "켜져 있으면 출발할 때 화면이 끊겨요")
            TipRow(icon: "lock.open.fill", title: "자동 잠금 끄기", detail: "설정 → 디스플레이 및 밝기 → 자동 잠금: 안 함")
            TipRow(icon: "personalhotspot", title: "핫스팟과 셀룰러 켜두기", detail: "인터넷이 없으면 테슬라가 Wi-Fi를 끊을 수 있어요")
            TipRow(icon: "wifi", title: "호환성 최대화 끄기", detail: "5GHz로 연결돼 더 부드러워요. ESP32를 쓸 때만 켜세요")
            TipRow(icon: "trash.fill", title: "테슬라에 저장된 다른 Wi-Fi 지우기", detail: "집 Wi-Fi로 자동 전환되는 걸 막아요")
            TipRow(icon: "speaker.wave.2.fill", title: "소리는 블루투스로", detail: "영상만 보내요. 소리는 평소처럼 나와요")
        }
        .card()
    }

    private var toolsCard: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.tap()
                showLog = true
            } label: {
                ToolRow(icon: "doc.text.magnifyingglass", title: "진단 로그", detail: "끊긴 시각과 이유를 확인해요")
            }
            .buttonStyle(RowButtonStyle())
            Divider().overlay(Theme.divider).padding(.leading, 56)
            Button {
                copy("\(status.playerURL)/probe", message: "점검 페이지 주소를 복사했어요")
            } label: {
                ToolRow(icon: "checklist", title: "테슬라 브라우저 점검", detail: "\(status.playerAddress)/probe")
            }
            .buttonStyle(RowButtonStyle())
        }
        .padding(.vertical, 8)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 차에서 연결이 안 될 때 원인을 찾기 위한 진단 정보. 테슬라 브라우저는 사설 IP(172.16~31.x 등)를 막는다는 보고가 있다.
    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("네트워크 정보")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("테슬라에서 안 열릴 때 캡처해 주세요. 테슬라 브라우저는 사설 주소를 막아서, '테슬라' 표시가 붙은 셀룰러 주소로 열어요.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            if status.interfaceAddresses.isEmpty {
                Text("표시할 주소가 없어요")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(status.interfaceAddresses, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.interface)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.sage)
                        .frame(width: 64, alignment: .leading)
                    Text(item.address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(addressTag(item))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.isPrivateIPv4 ? Theme.textTertiary : Theme.positive)
                }
            }
        }
        .card()
    }

    private func addressTag(_ item: HotspotAddress.InterfaceAddress) -> String {
        if item.isIPv6 { return "IPv6" }
        if item.address == status.cellularAddress { return "테슬라" }
        return item.isPrivateIPv4 ? "사설" : "시도"
    }

    // MARK: - 하단 버튼

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if status.isBroadcasting {
                Text("방송을 끄려면 버튼을 누르고 '방송 중단'을 선택하세요")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button {
                Haptics.tap()
                picker.present()
            } label: {
                Text(status.isBroadcasting ? "방송 관리" : "화면 방송 시작")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background, Theme.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: - 토스트

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.onBrand)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.brand.opacity(0.92))
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        Haptics.success()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.25)) {
                if toast == message { toast = nil }
            }
        }
    }
}

// MARK: - 구성 요소

private struct StepRow: View {
    enum Progress {
        case done, current, todo
    }

    let number: Int
    let title: String
    let detail: String
    let state: Progress

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 30, height: 30)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(state == .current ? Theme.onBrand : Theme.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state == .todo ? Theme.textTertiary : Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var circleColor: Color {
        switch state {
        case .done: return Theme.positive
        case .current: return Theme.brand
        case .todo: return Theme.divider
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TipRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.sage)
                .frame(width: 36, height: 36)
                .background(Theme.divider)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

private struct ToolRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.sage)
                .frame(width: 36, height: 36)
                .background(Theme.divider)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
