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

/// Průběh připojování RDP: malý panel nahoře uprostřed monitoru – fáze, uplynulý čas, číslo pokusu, Zrušit.
/// Zmizí po přihlášení do Windows, po ukončení FreeRDP nebo zrušení.
@MainActor
final class RDPProgress: NSObject {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let started = Date()
    private var phase = "Spouštění"
    private(set) var attempt = 1
    private(set) var closed = false
    var onCancel: (() -> Void)?

    init(name: String, screen: NSScreen?) {
        let size = NSSize(width: 400, height: 62)
        let f = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel = NSPanel(contentRect: NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 28,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        fx.appearance = NSAppearance(named: .darkAqua)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        title.stringValue = "RDP · \(name)"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = NSColor(white: 0.8, alpha: 1)
        detail.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let cancel = NSButton(title: "Zrušit", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let row = NSStackView(views: [spinner, texts, cancel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fx.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor), row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            row.topAnchor.constraint(equalTo: fx.topAnchor), row.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
        refresh()
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        // pojistka – panel nesmí zůstat viset
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.close() }
    }

    private var pid: Int32 = 0
    private var windowTicks = 0

    /// Konec průběhu podle okna relace: výpis FreeRDP jde přes rouru s bufferem a přichází se zpožděním
    /// (klidně minuty), na značky v logu se proto spolehnout nedá. Velké viditelné okno procesu = relace běží.
    func attach(pid: Int32) { self.pid = pid; windowTicks = 0 }

    private func sessionWindowVisible() -> Bool {
        guard pid > 0, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in info {
            // bez filtru na vrstvu: okno FreeRDP v celé obrazovce má vyšší vrstvu než běžná okna
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if r.width >= 640 && r.height >= 400 { return true }     // připojovací/chybový dialog FreeRDP je menší
        }
        return false
    }

    func setPhase(_ p: String) { guard !closed, p != phase else { return }; phase = p; refresh() }

    func nextAttempt(_ note: String) { attempt += 1; phase = note; refresh() }

    private func refresh() {
        if !closed, pid > 0 {
            windowTicks = sessionWindowVisible() ? windowTicks + 1 : 0
            if windowTicks >= 2 { close(); return }                 // okno relace je vidět ≥ ~1 s
        }
        let s = Int(Date().timeIntervalSince(started))
        detail.stringValue = "\(phase)… · \(s / 60):\(String(format: "%02d", s % 60))" + (attempt > 1 ? " · pokus \(attempt)" : "")
    }

    @objc private func cancelTapped() { onCancel?(); close() }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.invalidate(); timer = nil
        let p = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

/// Lišta relace RDP (jako „connection bar“ ve Windows): objeví se po najetí myší k hornímu okraji
/// celé obrazovky, u okna nad titulkem. Rozlišení, měřítko, celá obrazovka / okno, odpojení.
/// Je to neaktivující panel SSHTool nad oknem FreeRDP (poloha přes CGWindowList, myš přes NSEvent.mouseLocation –
/// bez zvláštních oprávnění); vidět jen, když je FreeRDP aktivní aplikace.
@MainActor
final class RDPSessionBar: NSObject {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "SSHTool.rdpToolbar") as? Bool ?? true }

    let pid: Int32
    private let session: SSHSession
    private let panel: NSPanel
    private var timer: Timer?
    private var shown = false
    private var lastInside = Date.distantPast
    private var fullscreen = false
    private var screenName: String?
    private var toggle: NSButton!
    var onFullscreen: ((String?) -> Void)?
    var onWindowed: ((String) -> Void)?
    var onScale: ((Int) -> Void)?
    var onDisconnect: (() -> Void)?
    private static let size = NSSize(width: 530, height: 32)
    static let positionKey = "SSHTool.rdpBarPosition"      // "left" | "center" | "right"; nic = podle displeje
    private static let titlebar: CGFloat = 28

    init(pid: Int32, session: SSHSession) {
        self.pid = pid
        self.session = session
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .popUpMenu                     // nad oknem FreeRDP i v celé obrazovce
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 9
        fx.layer?.masksToBounds = true
        fx.appearance = NSAppearance(named: .darkAqua)

        let name = NSTextField(labelWithString: session.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let res = Self.button("Rozlišení", "aspectratio", self, #selector(resolutionMenu(_:)))
        let scale = Self.button("Měřítko", "textformat.size", self, #selector(scaleMenu(_:)))
        toggle = Self.button("Celá obrazovka", "arrow.up.left.and.arrow.down.right", self, #selector(toggleTapped))
        let eject = Self.button("Odpojit", "eject", self, #selector(ejectTapped))
        let more = Self.button("", "ellipsis.circle", self, #selector(positionMenu(_:)))
        more.imagePosition = .imageOnly
        more.toolTip = "Umístění lišty (vlevo / uprostřed / vpravo)"
        res.toolTip = "Změnit rozlišení relace (přepojí, Windows aplikace zůstanou)"
        scale.toolTip = "Měřítko (DPI) ve Windows – uloží se k serveru a relace se přepojí"
        eject.toolTip = "Odpojit relaci (aplikace ve Windows běží dál)"
        let row = NSStackView(views: [name, res, scale, toggle, eject, more])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor), row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
        ])
        panel.contentView = fx
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    private static func button(_ title: String, _ symbol: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.isBordered = false
        b.font = .systemFont(ofSize: 11.5, weight: .medium)
        b.contentTintColor = NSColor(white: 0.92, alpha: 1)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    // MARK: Akce

    // Živě (bez přepojení) jde jen u relace s dynamickým rozlišením a s oprávněním Zpřístupnění; jinak přepojení.
    private var liveCapable: Bool { ["", "dynamic", "fullscreen"].contains(session.rdpSize) && !Self.keyToggleBroken }
    private static var keyToggleBroken = false

    private func canLive() -> Bool { liveCapable && RDPLive.ensureTrusted() }

    /// Celá obrazovka ↔ okno zkratkou FreeRDP; po chvíli ověří výsledek, jinak přepojení.
    private func liveToggle(expectFullscreen: Bool, then: (() -> Void)? = nil, fallback: @escaping () -> Void) {
        RDPLive.toggleFullscreen(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.refreshState()
            if self.fullscreen == expectFullscreen { then?(); return }
            Self.keyToggleBroken = true            // zkratka nezabrala → dál přepojovat
            fallback()
        }
    }

    @objc private func toggleTapped() {
        hide()
        let fb: () -> Void = { [weak self] in
            guard let self else { return }
            if self.fullscreen { self.onWindowed?("dynamic") } else { self.onFullscreen?(self.screenName) }
        }
        guard canLive() else { fb(); return }
        liveToggle(expectFullscreen: !fullscreen, fallback: fb)
    }

    @objc private func ejectTapped() { hide(); onDisconnect?() }

    @objc private func resolutionMenu(_ sender: NSButton) {
        let m = NSMenu()
        let cur = fullscreen ? "fullscreen" : session.rdpSize
        func add(_ title: String, _ value: String) {
            let it = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = value
            it.state = value == cur || (value == "dynamic" && cur.isEmpty) ? .on : .off
            m.addItem(it)
        }
        add("Podle velikosti okna (dynamické)", "dynamic")
        m.addItem(.separator())
        for r in ["1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440"] {
            add(r.replacingOccurrences(of: "x", with: " × ") + " (okno)", r)
        }
        m.addItem(.separator())
        let screens = NSScreen.screens.map(\.localizedName)
        for sc in screens {
            let it = NSMenuItem(title: screens.count > 1 ? "Celá obrazovka – \(sc)" : "Celá obrazovka",
                                action: #selector(pickScreen(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = sc
            it.state = fullscreen && sc == screenName ? .on : .off
            m.addItem(it)
        }
        popUp(m, from: sender)
    }

    @objc private func positionMenu(_ sender: NSButton) {
        let m = NSMenu()
        let cur = UserDefaults.standard.string(forKey: Self.positionKey) ?? ""
        for (title, v) in [("Automaticky (u displeje s výřezem vpravo)", ""), ("Vlevo", "left"), ("Uprostřed", "center"), ("Vpravo", "right")] {
            let it = NSMenuItem(title: title, action: #selector(pickPosition(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = v
            it.state = cur == v ? .on : .off
            m.addItem(it)
        }
        popUp(m, from: sender)
    }

    @objc private func pickPosition(_ it: NSMenuItem) {
        let v = it.representedObject as? String ?? ""
        if v.isEmpty { UserDefaults.standard.removeObject(forKey: Self.positionKey) }
        else { UserDefaults.standard.set(v, forKey: Self.positionKey) }
        lastInside = Date()
    }

    @objc private func scaleMenu(_ sender: NSButton) {
        let m = NSMenu()
        for v in [0, 100, 125, 150, 175, 200] {
            let it = NSMenuItem(title: (v == 0 ? "Automaticky" : "\(v) %") + "  (přepojí)", action: #selector(pickScale(_:)), keyEquivalent: "")
            it.target = self; it.tag = v
            it.state = session.rdpScale == v ? .on : .off
            m.addItem(it)
        }
        popUp(m, from: sender)
    }

    private func popUp(_ m: NSMenu, from sender: NSButton) {
        lastInside = Date()
        // menu pod lištou; u horního okraje (výřez / skrytý řádek nabídek) víc místa, jinak macOS menu „odroluje“
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + (fullscreen ? 16 : 6)), in: sender)
        lastInside = Date()                          // po zavření menu lištu hned neschovávat
    }

    @objc private func pickSize(_ it: NSMenuItem) {
        guard let v = it.representedObject as? String else { return }
        hide()
        let fb: () -> Void = { [weak self] in self?.onWindowed?(v) }
        guard canLive() else { fb(); return }
        let screen = NSScreen.screens.first { $0.localizedName == screenName }
        let resize: () -> Void = { [weak self] in
            guard let self else { return }
            let p = v.split(separator: "x").compactMap { Double($0) }
            guard p.count == 2 else { return }                       // „dynamic“ = jen přepnout do okna
            if !RDPLive.resize(pid: self.pid, width: p[0], height: p[1], on: screen) { fb() }
        }
        if fullscreen { liveToggle(expectFullscreen: false, then: resize, fallback: fb) } else { resize() }
    }

    @objc private func pickScreen(_ it: NSMenuItem) {
        guard let v = it.representedObject as? String else { return }
        hide()
        let fb: () -> Void = { [weak self] in self?.onFullscreen?(v) }
        guard canLive(), let target = NSScreen.screens.first(where: { $0.localizedName == v }) else { fb(); return }
        if fullscreen && v == screenName { return }
        let goFull: () -> Void = { [weak self] in
            guard let self else { return }
            if v != self.screenName { RDPLive.move(pid: self.pid, to: target) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.liveToggle(expectFullscreen: true, fallback: fb)
            }
        }
        if fullscreen { liveToggle(expectFullscreen: false, then: goFull, fallback: fb) } else { goFull() }
    }
    @objc private func pickScale(_ it: NSMenuItem) { hide(); onScale?(it.tag) }

    // MARK: Zobrazení po najetí myší

    /// Poloha okna relace, monitor a zda je celá obrazovka. nil = okno teď není vidět.
    @discardableResult
    private func refreshState() -> NSRect? {
        guard let r = Self.mainWindow(pid: pid), let primary = NSScreen.screens.first else { return nil }
        let frame = NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)  // CG → AppKit
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        screenName = screen?.localizedName
        fullscreen = screen.map { frame.width >= $0.frame.width - 2 && frame.height >= $0.frame.height * 0.9 } ?? false
        return frame
    }

    private func update() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let frame = refreshState() else { hide(); return }
        toggle.title = fullscreen ? "Okno" : "Celá obrazovka"
        toggle.image = NSImage(systemSymbolName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               accessibilityDescription: toggle.title)

        // celá obrazovka: lišta visí z horního okraje; okno: pod titulkem, spouští se najetím na titulek
        // displej s výřezem (notch): v celé obrazovce lištu dát vedle výřezu (vlevo/vpravo),
        // uprostřed pak až pod něj – jinak by část lišty zakryl
        let screen = NSScreen.screens.first { $0.localizedName == screenName }
        let notch = fullscreen ? (screen?.safeAreaInsets.top ?? 0) : 0
        let pos = UserDefaults.standard.string(forKey: Self.positionKey) ?? (notch > 0 ? "right" : "center")
        var top = fullscreen ? frame.maxY : frame.maxY - Self.titlebar
        let width = min(Self.size.width, frame.width - 20)
        let x: CGFloat
        switch pos {
        case "left":
            x = frame.minX + 12
            if let l = screen?.auxiliaryTopLeftArea, notch > 0, l.width < width + 24 { top -= notch }   // vedle výřezu se nevejde
        case "right":
            x = frame.maxX - width - 12
            if let r = screen?.auxiliaryTopRightArea, notch > 0, r.width < width + 24 { top -= notch }
        default:
            x = frame.midX - width / 2
            top -= notch
        }
        let barFrame = NSRect(x: x, y: top - Self.size.height - (fullscreen ? 2 : 4),
                              width: width, height: Self.size.height)
        let mouse = NSEvent.mouseLocation
        let trigger = fullscreen
            ? NSRect(x: frame.minX, y: frame.maxY - 4, width: frame.width, height: 6)
            : NSRect(x: frame.minX, y: frame.maxY - Self.titlebar, width: frame.width, height: Self.titlebar + 2)
        if trigger.contains(mouse) || (shown && barFrame.insetBy(dx: -16, dy: -16).contains(mouse)) { lastInside = Date() }
        guard Date().timeIntervalSince(lastInside) < 0.8 else { hide(); return }
        panel.setFrame(barFrame, display: true)
        if !shown { panel.alphaValue = 1; panel.orderFrontRegardless(); shown = true }
    }

    private func hide() { if shown { panel.orderOut(nil); shown = false } }

    /// Největší běžné okno procesu (v CG souřadnicích).
    static func mainWindow(pid: Int32) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: CGRect?
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width >= 400, r.height >= 300 else { continue }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }
}
