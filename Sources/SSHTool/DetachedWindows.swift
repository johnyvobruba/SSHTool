import SwiftUI
import AppKit

/// Samostatná okna pro oddělené záložky (⌥⌘N nebo „Otevřít v samostatném okně“ v menu záložky).
/// Relace se nepřepojuje – terminál (NSView) se jen přesune do jiného okna. Záložka dál patří TabManageru
/// (multi-send, broadcast, stav v seznamu serverů); příkazy z menu míří na aktivní okno.
@MainActor
final class DetachedWindows: NSObject, NSWindowDelegate {
    static let shared = DetachedWindows()

    final class Holder: ObservableObject {
        @Published var tab: TerminalTab
        init(_ t: TerminalTab) { tab = t }
    }

    private var entries: [(window: NSWindow, holder: Holder)] = []
    private weak var manager: TabManager?

    private func entry(_ tabID: UUID) -> (window: NSWindow, holder: Holder)? {
        entries.first { $0.holder.tab.id == tabID }
    }

    func open(_ t: TerminalTab, manager: TabManager) {
        self.manager = manager
        guard let store = AppStore.shared else { return }
        let holder = Holder(t)
        let root = DetachedTabView(holder: holder)
            .environmentObject(manager)
            .environmentObject(store)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(manager.displayTitle(t)) – SSHTool"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 480, height: 300)
        w.contentView = NSHostingView(rootView: root)
        w.delegate = self
        if let last = entries.last?.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            w.center()
        }
        entries.append((w, holder))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Zavře okno bez dotazu (záložka už byla vrácena do hlavního okna nebo ukončena).
    func forget(_ tabID: UUID) {
        guard let i = entries.firstIndex(where: { $0.holder.tab.id == tabID }) else { return }
        let w = entries.remove(at: i).window
        w.delegate = nil
        w.close()
    }

    /// Znovu připojeno → nová záložka ve stejném okně.
    func replace(_ tabID: UUID, with t: TerminalTab) {
        guard let e = entry(tabID) else { return }
        e.holder.tab = t
        if let m = manager { e.window.title = "\(m.displayTitle(t)) – SSHTool" }
    }

    func front(_ tabID: UUID) {
        guard let e = entry(tabID) else { return }
        if e.window.isMiniaturized { e.window.deminiaturize(nil) }
        e.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showMainWindow() {
        let detached = Set(shared.entries.map { ObjectIdentifier($0.window) })
        if let main = NSApp.windows.first(where: { $0.title == "SSHTool" && !detached.contains(ObjectIdentifier($0)) }) {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, let e = entries.first(where: { $0.window === w }) else { return }
        manager?.keyDetachedID = e.holder.tab.id
        if let m = manager { w.title = "\(m.displayTitle(e.holder.tab)) – SSHTool" }
    }

    func windowDidResignKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, let e = entries.first(where: { $0.window === w }) else { return }
        if manager?.keyDetachedID == e.holder.tab.id { manager?.keyDetachedID = nil }
    }

    /// Zavření okna (červené tlačítko): běžící relaci nabídnout vrátit do hlavního okna – nic se neztratí omylem.
    func windowShouldClose(_ w: NSWindow) -> Bool {
        guard let e = entries.first(where: { $0.window === w }), let m = manager else { return true }
        let t = e.holder.tab
        guard t.running else { m.close(t.id); return false }      // relace už skončila → jen zavřít
        let a = NSAlert()
        a.messageText = "Zavřít okno „\(m.displayTitle(t))“?"
        a.informativeText = t.kind == .ftp ? "Záložku lze vrátit do hlavního okna, nebo ji zavřít."
                                           : "Relace stále běží. Můžeš ji vrátit do hlavního okna, nebo ukončit."
        a.addButton(withTitle: "Vrátit do hlavního okna")
        a.addButton(withTitle: t.kind == .ftp ? "Zavřít" : "Ukončit relaci")
        a.addButton(withTitle: "Zrušit")
        switch a.runModal() {
        case .alertFirstButtonReturn: m.attachToMain(t.id)
        case .alertSecondButtonReturn: m.close(t.id)
        default: break
        }
        return false
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let i = entries.firstIndex(where: { $0.window === w }) else { return }
        let id = entries[i].holder.tab.id
        entries.remove(at: i)
        if manager?.keyDetachedID == id { manager?.keyDetachedID = nil }
    }
}

struct DetachedTabView: View {
    @ObservedObject var holder: DetachedWindows.Holder
    @EnvironmentObject private var store: AppStore

    var body: some View {
        DetachedTabContent(tab: holder.tab)
            .id(holder.tab.id)
            .tint(UI.accent)
            .preferredColorScheme(store.isDarkUI ? .dark : .light)
    }
}

private struct DetachedTabContent: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon).font(.system(size: 11)).foregroundStyle(UI.textSecondary)
                Text(tabs.displayTitle(tab)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(UI.text)
                EnvBadge(tag: tab.session.envTag)
                Spacer()
                Button { tabs.rename(tab.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Přejmenovat záložku")
                Button { tabs.reconnect(tab.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Znovu připojit (⇧⌘R)")
                Button { tabs.attachToMain(tab.id) } label: {
                    Label("Do hlavního okna", systemImage: "rectangle.stack").font(.system(size: 11))
                }
                .buttonStyle(.plain).help("Vrátit záložku do lišty hlavního okna (⌥⌘N)")
            }
            .foregroundStyle(UI.textSecondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(UI.statusBar)
            Rectangle().fill(UI.border).frame(height: 1)
            TerminalWithOverlay(tab: tab, focus: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(UI.border).frame(height: 1)
            StatusBar(tab: tab)
        }
    }
}
