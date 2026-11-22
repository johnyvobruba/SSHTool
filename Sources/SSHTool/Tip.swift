import SwiftUI
import AppKit

// Bublina s popisem po najetí myší (místo systémového .help, které se u ikon v liště
// ukazuje pozdě nebo vůbec). Zobrazí se po 0,4 s u kurzoru, zmizí při odjetí, kliknutí či psaní.

@MainActor
final class TipWindow {
    static let shared = TipWindow()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var current: String?
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { e in
            MainActor.assumeIsolated { TipWindow.shared.hide() }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TipWindow.shared.hide() }
        }
    }

    func schedule(_ text: String) {
        guard !text.isEmpty else { return }
        pending?.cancel()
        current = text
        let w = DispatchWorkItem { MainActor.assumeIsolated { TipWindow.shared.show(text) } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Skryje bublinu; s textem jen tehdy, když patří tomuto prvku (přejezd z ikony na ikonu).
    func hide(_ text: String? = nil) {
        if let text, text != current { return }
        pending?.cancel(); pending = nil
        current = nil
        panel?.orderOut(nil)
    }

    private func show(_ text: String) {
        pending = nil
        guard current == text, NSApp.isActive else { return }
        let p = panel ?? make()
        let host = NSHostingView(rootView: TipBubble(text: text))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        let m = NSEvent.mouseLocation
        var origin = NSPoint(x: m.x + 4, y: m.y - size.height - 22)
        if let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) })?.visibleFrame {
            origin.x = min(max(origin.x, s.minX + 4), s.maxX - size.width - 4)
            if origin.y < s.minY + 4 { origin.y = m.y + 16 }
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel = p
        return p
    }
}

private struct TipBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Color(nsColor: .labelColor))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            )
            .padding(1)
    }
}

extension View {
    /// Popis prvku: bublina po najetí myší + text pro VoiceOver.
    func tip(_ text: String) -> some View {
        self
            .accessibilityHint(Text(text))
            .onHover { inside in
                MainActor.assumeIsolated {
                    if inside { TipWindow.shared.schedule(text) } else { TipWindow.shared.hide(text) }
                }
            }
    }
}
