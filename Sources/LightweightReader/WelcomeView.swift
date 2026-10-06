import AppKit

@MainActor
final class WelcomeView: NSView {
    var onOpen: (() -> Void)?
    var onOpenPDF: (() -> Void)?
    var onOpenMarkdown: (() -> Void)?
    var onOpenJSON: (() -> Void)?
    private let card = NSView()
    private let primaryButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        primaryButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    private func buildView() {
        card.wantsLayer = true
        card.layer?.cornerRadius = 20
        card.layer?.borderWidth = 1
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "books.vertical.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 42, weight: .medium))
        symbol.contentTintColor = .controlAccentColor
        symbol.imageScaling = .scaleProportionallyDown
        symbol.setAccessibilityHidden(true)

        let heading = NSTextField(labelWithString: String(localized: "welcome.title"))
        heading.font = .preferredFont(forTextStyle: .title1)
        heading.alignment = .center
        heading.maximumNumberOfLines = 1

        let subtitle = NSTextField(labelWithString: String(localized: "welcome.subtitle"))
        subtitle.font = .preferredFont(forTextStyle: .body)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2

        primaryButton.target = self
        primaryButton.action = #selector(openAll)
        primaryButton.isBordered = false
        primaryButton.wantsLayer = true
        primaryButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        primaryButton.layer?.cornerRadius = 10
        primaryButton.attributedTitle = NSAttributedString(
            string: String(localized: "welcome.openButton"),
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .semibold)]
        )
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("welcome.open")

        let chooseLabel = NSTextField(labelWithString: String(localized: "welcome.chooseFormat"))
        chooseLabel.font = .preferredFont(forTextStyle: .subheadline)
        chooseLabel.textColor = .secondaryLabelColor
        chooseLabel.alignment = .center

        let formats = NSStackView()
        formats.orientation = .horizontal
        formats.distribution = .fillEqually
        formats.spacing = 10
        formats.addArrangedSubview(formatButton("welcome.pdf", symbol: "doc.richtext", action: #selector(openPDF)))
        formats.addArrangedSubview(formatButton("welcome.markdown", symbol: "text.alignleft", action: #selector(openMarkdown)))
        formats.addArrangedSubview(formatButton("welcome.json", symbol: "curlybraces", action: #selector(openJSON)))

        let dropHint = NSTextField(labelWithString: String(localized: "welcome.dropHint"))
        dropHint.font = .preferredFont(forTextStyle: .footnote)
        dropHint.textColor = .tertiaryLabelColor
        dropHint.alignment = .center

        let stack = NSStackView(views: [symbol, heading, subtitle, primaryButton, chooseLabel, formats, dropHint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: symbol)
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(14, after: primaryButton)
        stack.setCustomSpacing(10, after: formats)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let preferredWidth = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferredWidth,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            card.heightAnchor.constraint(equalToConstant: 348),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            symbol.widthAnchor.constraint(equalToConstant: 48),
            symbol.heightAnchor.constraint(equalToConstant: 48),
            primaryButton.widthAnchor.constraint(equalToConstant: 230),
            primaryButton.heightAnchor.constraint(equalToConstant: 44),
            formats.widthAnchor.constraint(equalToConstant: 474),
            formats.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    private func formatButton(_ title: String.LocalizationValue, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: String(localized: title), target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func openAll() { onOpen?() }
    @objc private func openPDF() { onOpenPDF?() }
    @objc private func openMarkdown() { onOpenMarkdown?() }
    @objc private func openJSON() { onOpenJSON?() }
}
