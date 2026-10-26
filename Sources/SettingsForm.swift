import AppKit

/// Building blocks shared by the Settings pages, in the style of System Settings: a page title, grey section headers
/// and rounded boxes of rows, each with its label on the left and its control on the right.
@MainActor enum SettingsForm {
    static let width: CGFloat = 440

    /// A page: its title (with an optional icon the page keeps updating) above the blocks, scrolling when it is taller
    /// than the window.
    static func page(_ title: String, icon: NSImageView? = nil, _ blocks: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        var top: [NSView] = [heading]
        if let icon {
            icon.setContentHuggingPriority(.required, for: .horizontal)
            top = [icon, heading]
        }
        let header = NSStackView(views: top)
        header.spacing = 8
        let stack = NSStackView(views: [header] + blocks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 24, right: 28)
        for block in blocks { block.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    /// A grey header above a rounded box of rows, separated by hairlines.
    static func section(_ header: String?, _ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        if let header {
            let label = NSTextField(labelWithString: header.uppercased())
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            views.append(label)
        }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                inner.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -28).isActive = true
            }
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        box.contentView = inner
        views.append(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A row: the label (and an optional grey line under it) on the left, the control on the right.
    static func row(_ label: String, detail: String? = nil, control: NSView? = nil) -> NSView {
        let title = WrappingLabel(wrappingLabelWithString: label)
        var texts: [NSView] = [title]
        if let detail { texts.append(note(detail)) }
        let left = NSStackView(views: texts)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [left] + (control.map { [$0] } ?? []))
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.distribution = .fill
        control?.setContentHuggingPriority(.required, for: .horizontal)
        control?.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return row
    }

    /// Small grey text, wrapping within the page.
    static func note(_ text: String) -> NSTextField {
        let field = WrappingLabel(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// "4 minutes ago" or "now", in English like the rest of Usagi; never in the future.
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateTimeStyle = .named
        let now = Date()
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// A segmented control choosing one of `titles`.
    static func segments(_ titles: [String], selected: Int, target: AnyObject, action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: target, action: action)
        control.selectedSegment = selected
        return control
    }

    /// A small icon: a white SF Symbol on a rounded square of `color`, as System Settings shows its panes.
    static func icon(_ symbol: String, _ color: NSColor, size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let box = glyph.size
                glyph.draw(in: NSRect(x: (size - box.width) / 2, y: (size - box.height) / 2, width: box.width, height: box.height))
            }
            return true
        }
        return image
    }
}

/// A wrapping label that wraps at the width it is given, so a long line next to a control grows a row instead of
/// being cut off.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// Lays a page out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
