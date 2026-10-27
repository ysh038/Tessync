import SwiftUI

/// 앱 전체 색과 공용 스타일. 아이콘 색(짙은 남색 #1E292D, 오프화이트 #EEEFEA, 세이지 #829C9E)을 기준으로 한다.
enum Theme {
    static let background = Color(light: 0xF2F4F6, dark: 0x0F1416)
    static let card = Color(light: 0xFFFFFF, dark: 0x1A2125)
    static let textPrimary = Color(light: 0x191F28, dark: 0xEEEFEA)
    static let textSecondary = Color(light: 0x6B7684, dark: 0x9AA6AC)
    static let textTertiary = Color(light: 0xB0B8C1, dark: 0x5C6870)
    static let divider = Color(light: 0xF2F4F6, dark: 0x262F34)
    static let brand = Color(light: 0x1E292D, dark: 0xEEEFEA)
    static let onBrand = Color(light: 0xFFFFFF, dark: 0x1E292D)
    static let sage = Color(light: 0x6F8B8E, dark: 0x829C9E)
    static let positive = Color(light: 0x12A66A, dark: 0x3DD68C)
    static let warning = Color(light: 0xE08A00, dark: 0xFFB84D)
    static let warningBackground = Color(light: 0xFFF4E0, dark: 0x33291A)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 흰 카드: 넉넉한 안쪽 여백, 큰 둥근 모서리.
struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    func card() -> some View {
        modifier(CardModifier())
    }
}

/// 하단 고정 큰 버튼.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.onBrand)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.brand)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 카드 안의 작은 알약 버튼(복사 등).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.divider)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 목록 행을 누를 때 살짝 어두워지는 효과.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Theme.divider : Color.clear)
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
