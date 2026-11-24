import AppKit
import SwiftUI

/// Brand colors. The accent is the violet UPDF-style highlight used for
/// selected tools, the active mode and primary buttons.
enum Brand {
    static let accent = Color(red: 0.42, green: 0.36, blue: 1.0)
    static let accentSoft = Color(red: 0.42, green: 0.36, blue: 1.0).opacity(0.16)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.19, alpha: 1)
            : NSColor.white
    })
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {
    /// Liquid Glass on macOS 26; a translucent material with a hairline edge before that.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            materialSurface(shape, tint: tint)
        }
        #else
        materialSurface(shape, tint: tint)
        #endif
    }

    private func materialSurface<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.22)) }
                }
            }
            .overlay { shape.stroke(Color.white.opacity(0.28), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    /// `.glass` / `.glassProminent` button styles on macOS 26, bordered styles before.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #endif
    }
}

/// Groups glass elements so they blend and morph together on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A colored rounded-square icon, used for tools in the Tools panel and on Home.
struct ToolTileIcon: View {
    let systemImage: String
    let colors: [Color]
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
            }
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: (colors.last ?? .black).opacity(0.3), radius: 4, y: 2)
    }
}

/// An icon-and-label tile button.
struct ToolTile: View {
    let title: String
    let systemImage: String
    let colors: [Color]
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ToolTileIcon(systemImage: systemImage, colors: colors)
                    .scaleEffect(hovering ? 1.08 : 1)
                Text(title)
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 84)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(duration: 0.2)) { self.hovering = hovering }
        }
        .help(title)
    }
}

/// A capsule button inside a glass bar; selected buttons get the accent tint.
struct CapsuleBarButton: View {
    let title: String?
    let systemImage: String
    var isSelected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                if let title {
                    Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                }
            }
            .padding(.horizontal, title == nil ? 9 : 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Brand.accent : Color.primary)
            .background {
                if isSelected {
                    Capsule().fill(Brand.accentSoft)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title ?? "")
    }
}

/// Attaches a callback to the NSWindow hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private weak var configured: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            let callback = onWindow
            DispatchQueue.main.async {
                MainActor.assumeIsolated { callback?(window) }
            }
        }
    }
}
