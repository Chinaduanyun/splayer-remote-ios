import SwiftUI

// MARK: - 液体玻璃支持
//
// iOS 26 提供真正的 `.glassEffect` / `.buttonStyle(.glass)`；
// iOS 17–25 退回 `Material` + 描边，保持相同的视觉层级。

extension View {
    /// 玻璃面板。iOS 26 使用真实 Liquid Glass，旧系统退回超薄材质。
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
    }
}

/// 交通控制按钮：iOS 26 使用 `.glass`，旧系统使用 bordered 系列。
/// 所有按钮命中区 ≥44pt；主控制可设为 `large` 以突出层级。
struct GlassTransportButton: View {
    let systemImage: String
    let label: String
    var prominent: Bool = false
    var enabled: Bool = true
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                button.buttonStyle(.glass)
            } else {
                if prominent {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
                }
            }
        }
    }

    private var side: CGFloat { large ? 72 : 44 }
    private var iconSize: CGFloat { large ? 34 : 22 }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(minWidth: side, minHeight: side)
                .contentShape(Rectangle())
        }
        .tint(prominent ? Theme.accent : Theme.accent.opacity(0.9))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - 主题

enum Theme {
    /// 克制的橙色强调。
    static let accent = Color(red: 0.98, green: 0.55, blue: 0.20)
    /// 温暖的深色背景起点 / 终点。
    static let backgroundTop = Color(red: 0.10, green: 0.09, blue: 0.10)
    static let backgroundBottom = Color(red: 0.04, green: 0.04, blue: 0.05)
}

/// 温暖深色背景，随系统深浅模式保持深色。
struct WarmBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.backgroundTop, Theme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            RadialGradient(
                colors: [Theme.accent.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
        )
        .ignoresSafeArea()
    }
}
