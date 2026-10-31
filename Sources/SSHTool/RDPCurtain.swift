import AppKit

/// Černá „opona“ na monitoru RDP relace v celé obrazovce.
///
/// Proč: FreeRDP (SDL) při startu na celé obrazovce nejdřív vytvoří okno a pak ho roztáhne – mezitím je krátce
/// vidět plocha / okna pod ním (bliknutí). Totéž při přepojení na jiný monitor (stará relace skončí, nová ještě
/// není). Opona je obyčejné okno SSHTool na běžné úrovni, otevřené PŘED spuštěním FreeRDP → okna FreeRDP
/// (připojovací dialog, certifikát, přihlášení i samotná relace) jsou vždy nad ní, přechod probíhá na černém pozadí.
/// Zmizí, jakmile okno relace stabilně pokrývá monitor, po přihlášení, po ukončení FreeRDP, kliknutím, nebo po 45 s.
@MainActor
final class RDPCurtain {
    private let panel: NSPanel
    private let screen: NSScreen
    private var timer: Timer?
    private var pid: Int32 = 0
    private var stableTicks = 0
    private let started = Date()
    private var closed = false

    var ownerPID: Int32 { pid }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "SSHTool.rdpCurtain") as? Bool ?? true }

    init(screen: NSScreen, title: String) {
        self.screen = screen
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false, screen: screen)
        p.isFloatingPanel = false
        p.level = .normal
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .black
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let v = CurtainView(frame: NSRect(origin: .zero, size: screen.frame.size), title: title)
        p.contentView = v
        panel = p
        v.onClick = { [weak self] in self?.close(animated: false) }
        p.setFrame(screen.frame, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        // pojistka: když se FreeRDP vůbec nespustí (zrušené heslo, chyba), opona nesmí zůstat
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.close() }
    }

    /// Po spuštění FreeRDP: hlídat jeho okna (CGWindowList – bez zvláštních oprávnění).
    func attach(pid: Int32, loggedOn: Box<Bool>) {
        self.pid = pid
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick(loggedOn: loggedOn.value) }
        }
    }

    private func tick(loggedOn: Bool) {
        guard !closed else { return }
        if Date().timeIntervalSince(started) > 45 { close(); return }
        stableTicks = coversScreen() ? stableTicks + 1 : 0
        // okno relace pokrývá monitor ~0,6 s (dokončený přechod) – nebo přihlášení proběhlo a okno je vidět
        if stableTicks >= 4 || (loggedOn && stableTicks >= 1) { close() }
    }

    /// Má FreeRDP okno, které pokrývá celý monitor (u MacBooku s výřezem stačí ≥ 90 % výšky)?
    private func coversScreen() -> Bool {
        guard pid > 0, let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let f = screen.frame
        let cg = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)   // AppKit → CG
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if abs(r.minX - cg.minX) <= 2, abs(r.width - cg.width) <= 2,
               r.height >= cg.height * 0.9, r.minY >= cg.minY - 2, r.maxY <= cg.maxY + 2 { return true }
        }
        return false
    }

    func close(animated: Bool = true) {
        guard !closed else { return }
        closed = true
        timer?.invalidate(); timer = nil
        let p = panel
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

private final class CurtainView: NSView {
    var onClick: (() -> Void)?

    init(frame: NSRect, title: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: title)
        label.textColor = NSColor(white: 0.85, alpha: 1)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        let hint = NSTextField(labelWithString: "Kliknutím skrýt")
        hint.textColor = NSColor(white: 0.45, alpha: 1)
        hint.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [spinner, label, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
