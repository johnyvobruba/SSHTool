import AppKit
import ApplicationServices

/// Živé změny běžící RDP relace bez přepojení (vyžaduje oprávnění macOS „Zpřístupnění“):
///  • velikost okna → FreeRDP s /dynamic-resolution pošle Windows nové rozlišení (Display Control kanál),
///  • celá obrazovka ↔ okno → klávesová zkratka FreeRDP pravý ⇧ + Enter poslaná přímo procesu FreeRDP.
/// Měřítko (DPI) za běhu FreeRDP změnit neumí → dál přes přepojení.
@MainActor
enum RDPLive {
    static let declinedKey = "SSHTool.rdpLiveDeclined"

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Před prvním živým zásahem: je oprávnění? Když ne, vysvětlit a nabídnout povolení / přepojení.
    /// true = lze měnit živě, false = použít přepojení.
    static func ensureTrusted() -> Bool {
        if trusted { return true }
        if UserDefaults.standard.bool(forKey: declinedKey) { return false }
        let a = NSAlert()
        a.messageText = "Měnit relaci bez přepojení?"
        a.informativeText = """
        Aby SSHTool mohl měnit velikost okna RDP a přepínat celou obrazovku přímo v běžící relaci, potřebuje oprávnění „Zpřístupnění“ (Nastavení systému → Soukromí a zabezpečení → Zpřístupnění).

        Oprávnění umožňuje ovládat okna a klávesnici i jiných aplikací – SSHTool ho používá jen pro okno FreeRDP. Po aktualizaci SSHTool (ad-hoc podpis) ho macOS může zrušit a bude potřeba ho povolit znovu.

        Bez oprávnění se změna provede přepojením relace (Windows aplikace zůstanou).
        """
        a.addButton(withTitle: "Povolit…")
        a.addButton(withTitle: "Teď přepojit")
        a.addButton(withTitle: "Vždy přepojovat")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(u)
            }
            return false          // povolení se projeví až příště; teď přepojit
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: declinedKey)
            return false
        default:
            return false
        }
    }

    /// Hlavní (největší) okno procesu přes Accessibility API.
    private static func window(pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGFloat)?
        for w in wins {
            let s = size(w) ?? .zero
            if best == nil || s.width * s.height > best!.1 { best = (w, s.width * s.height) }
        }
        return best?.0
    }

    private static func size(_ w: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &s)
        return s
    }

    /// Okno relace na danou velikost plochy (body; jako /size) – vejde se na monitor, kde okno je.
    /// FreeRDP pak sám pošle Windows nové rozlišení.
    @discardableResult
    static func resize(pid: Int32, width: CGFloat, height: CGFloat, on screen: NSScreen?) -> Bool {
        guard let w = window(pid: pid) else { return false }
        let titlebar: CGFloat = 28
        var size = CGSize(width: width, height: height + titlebar)
        if let vf = screen?.visibleFrame {
            size.width = min(size.width, vf.width)
            size.height = min(size.height, vf.height)
            // poloha v souřadnicích AX (vlevo nahoře od primárního monitoru), okno vycentrovat
            if let primary = NSScreen.screens.first {
                var origin = CGPoint(x: vf.midX - size.width / 2, y: primary.frame.maxY - vf.maxY + (vf.height - size.height) / 2)
                if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
            }
        }
        guard let v = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
    }

    /// Přesune okno na jiný monitor (do středu jeho plochy).
    static func move(pid: Int32, to screen: NSScreen) {
        guard let w = window(pid: pid), let primary = NSScreen.screens.first else { return }
        let s = size(w) ?? CGSize(width: 1200, height: 800)
        let vf = screen.visibleFrame
        var origin = CGPoint(x: vf.midX - min(s.width, vf.width) / 2,
                             y: primary.frame.maxY - vf.maxY + max(0, (vf.height - s.height) / 2))
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
    }

    /// Zkratka FreeRDP „pravý ⇧ + Enter“ (celá obrazovka ↔ okno) poslaná přímo procesu FreeRDP.
    static func toggleFullscreen(pid: Int32) {
        let src = CGEventSource(stateID: .privateState)
        let rShift: CGKeyCode = 0x3C, ret: CGKeyCode = 0x24
        let rShiftFlags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04)   // NX_DEVICERSHIFTKEYMASK
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, flagsChanged: Bool = false) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
            if flagsChanged { e.type = .flagsChanged }
            e.flags = flags
            e.postToPid(pid)
        }
        post(rShift, down: true, flags: rShiftFlags, flagsChanged: true)
        post(ret, down: true, flags: rShiftFlags)
        post(ret, down: false, flags: rShiftFlags)
        post(rShift, down: false, flags: [], flagsChanged: true)
    }
}
