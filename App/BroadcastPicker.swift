import ReplayKit
import SwiftUI

/// 시스템 방송 선택 창을 우리 버튼으로 띄우기 위한 래퍼.
/// RPSystemBroadcastPickerView 안의 버튼을 대신 눌러준다(널리 쓰이는 방식).
final class BroadcastPicker: ObservableObject {
    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }()

    func present() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .allTouchEvents)
        }
    }
}

/// 피커 뷰가 화면 계층에 있어야 동작하므로 보이지 않게 붙여둔다.
struct BroadcastPickerHost: UIViewRepresentable {
    let picker: BroadcastPicker

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        picker.view.alpha = 0.011
        return picker.view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
