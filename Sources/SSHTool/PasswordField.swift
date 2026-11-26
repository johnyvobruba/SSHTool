import AppKit
import SwiftUI

// Pole pro heslo s „okem“: heslo je ve výchozím stavu skryté, kliknutím na oko se zobrazí jako text
// (a zpět). Po zavření dialogu se pole zahodí, takže příště začíná znovu skryté.

/// AppKit – pro dialogy NSAlert. `partner` = navázané pole (Heslo znovu), oko přepíná obě najednou.
@MainActor
final class RevealPasswordField: NSView {
    let secure = NSSecureTextField()
    let plain = NSTextField()
    private let eye = NSButton()
    private(set) var shown = false
    weak var partner: RevealPasswordField?
    /// Volá se při změně textu (např. kontrola shody hesel).
    var onChange: (() -> Void)?

    var stringValue: String {
        get { shown ? plain.stringValue : secure.stringValue }
        set { secure.stringValue = newValue; plain.stringValue = newValue }
    }
    var placeholderString: String? {
        get { secure.placeholderString }
        set { secure.placeholderString = newValue; plain.placeholderString = newValue }
    }
    /// Pole, které je právě vidět (pro initialFirstResponder).
    var field: NSTextField { shown ? plain : secure }

    init(width: CGFloat = 280, placeholder: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        for f in [secure, plain] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.placeholderString = placeholder
            f.lineBreakMode = .byClipping
            f.cell?.isScrollable = true
            addSubview(f)
        }
        plain.isHidden = true
        plain.isAutomaticTextCompletionEnabled = false

        eye.translatesAutoresizingMaskIntoConstraints = false
        eye.isBordered = false
        eye.imagePosition = .imageOnly
        eye.target = self; eye.action = #selector(toggle)
        eye.refusesFirstResponder = true
        addSubview(eye)
        updateEye()

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 24),
            eye.trailingAnchor.constraint(equalTo: trailingAnchor),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 22),
            eye.heightAnchor.constraint(equalToConstant: 22),
        ])
        for f in [secure, plain] {
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: leadingAnchor),
                f.trailingAnchor.constraint(equalTo: eye.leadingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: secure)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) není podporován") }

    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: 24) }

    var isEnabled: Bool {
        get { secure.isEnabled }
        set { secure.isEnabled = newValue; plain.isEnabled = newValue; eye.isEnabled = newValue }
    }

    @objc private func textChanged() { onChange?() }

    @objc func toggle() {
        setShown(!shown)
        partner?.setShown(shown)
    }

    func setShown(_ s: Bool) {
        guard s != shown else { return }
        let editing = (window?.firstResponder as? NSText)?.delegate as? NSTextField === field
        let v = stringValue
        shown = s
        secure.stringValue = v; plain.stringValue = v
        plain.isHidden = !s; secure.isHidden = s
        updateEye()
        if editing {
            window?.makeFirstResponder(field)
            (window?.firstResponder as? NSText)?.selectedRange = NSRange(location: (v as NSString).length, length: 0)
        }
    }

    private func updateEye() {
        let name = shown ? "eye.slash" : "eye"
        let tip = shown ? "Skrýt heslo" : "Zobrazit heslo"
        eye.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
        eye.contentTintColor = .secondaryLabelColor
        eye.toolTip = tip
        eye.setAccessibilityLabel(tip)
    }
}

/// SwiftUI – SecureField s okem pro zobrazení hesla.
final class RevealModel: ObservableObject { @Published var shown = false }

struct RevealSecureField: View {
    let title: String
    @Binding var text: String
    @StateObject private var m = RevealModel()

    init(_ title: String, text: Binding<String>) { self.title = title; self._text = text }

    var body: some View {
        HStack(spacing: 4) {
            if m.shown {
                TextField(title, text: $text).disableAutocorrection(true)
            } else {
                SecureField(title, text: $text)
            }
            Button { m.shown.toggle() } label: {
                Image(systemName: m.shown ? "eye.slash" : "eye").frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(m.shown ? "Skrýt heslo" : "Zobrazit heslo")
            .accessibilityLabel(m.shown ? "Skrýt heslo" : "Zobrazit heslo")
        }
    }
}
