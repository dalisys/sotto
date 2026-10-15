import SwiftUI

enum SottoTheme {
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let muted = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let surface = Color(red: 247 / 255, green: 247 / 255, blue: 248 / 255)
    static let line = Color.black.opacity(0.10)
    static let orange = Color(red: 1, green: 79 / 255, blue: 0)
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .bold || weight == .semibold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size)
    }
}

struct SottoButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SottoTheme.font(13, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(prominent ? .white : SottoTheme.ink)
            .background(prominent ? SottoTheme.orange : Color.white)
            .overlay(Rectangle().strokeBorder(prominent ? Color.clear : SottoTheme.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct RuledSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var content: Content
    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(SottoTheme.font(18, weight: .semibold))
                if let detail { Text(detail).font(SottoTheme.font(13)).foregroundStyle(SottoTheme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).background(Color.white)
        .overlay(Rectangle().strokeBorder(SottoTheme.line))
    }
}

struct SottoEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(SottoTheme.orange)
            Text(title).font(SottoTheme.font(26, weight: .semibold))
            Text(detail).font(SottoTheme.font(15)).foregroundStyle(SottoTheme.muted).lineSpacing(5).frame(maxWidth: 420, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32).background(Color.white)
        .overlay(Rectangle().strokeBorder(SottoTheme.line))
    }
}

func sottoDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
