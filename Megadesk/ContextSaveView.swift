import SwiftUI
import AppKit

// MARK: - NSViewRepresentable for text input with Enter→save, Shift+Enter→newline

private struct ContextTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String?
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = CenteringTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 18, weight: .medium)
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.alignment = .center
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholderText = placeholder
        textView.delegate = context.coordinator

        scrollView.documentView = textView

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CenteringTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.alignment = .center
            textView.updatePlaceholderVisibility()
            textView.centerVertically()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ContextTextEditor
        init(_ parent: ContextTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? CenteringTextView else { return }
            parent.text = tv.string
            tv.updatePlaceholderVisibility()
            tv.centerVertically()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    // Shift+Enter → newline, only if it fits
                    if !wouldOverflow(textView, inserting: "\n") {
                        textView.insertText("\n", replacementRange: textView.selectedRange())
                    }
                    return true
                }
                parent.onCommit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, !text.isEmpty else { return true } // allow deletions
            return !wouldOverflow(textView, inserting: text, in: range)
        }

        private func wouldOverflow(_ textView: NSTextView, inserting newText: String, in range: NSRange? = nil) -> Bool {
            guard let tc = textView.textContainer else { return false }
            let replaceRange = range ?? textView.selectedRange()
            let proposed = (textView.string as NSString).replacingCharacters(in: replaceRange, with: newText)
            let storage = NSTextStorage(string: proposed, attributes: [.font: textView.font ?? .systemFont(ofSize: 18)])
            let tempLM = NSLayoutManager()
            let tempTC = NSTextContainer(size: NSSize(width: tc.size.width, height: .greatestFiniteMagnitude))
            tempTC.lineFragmentPadding = tc.lineFragmentPadding
            tempLM.addTextContainer(tempTC)
            storage.addLayoutManager(tempLM)
            tempLM.ensureLayout(for: tempTC)
            let textHeight = tempLM.usedRect(for: tempTC).height
            let available = textView.enclosingScrollView?.contentView.bounds.height ?? textView.bounds.height
            return textHeight > available - 32  // leave margin for vertical centering
        }
    }
}

// NSTextView subclass that vertically centers its content and shows a placeholder
private final class CenteringTextView: NSTextView {
    var placeholderText: String? {
        didSet { setupPlaceholder() }
    }
    private var placeholderLabel: NSTextField?

    override func layout() {
        super.layout()
        centerVertically()
        layoutPlaceholder()
    }

    func centerVertically() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        let viewHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        let insetX = textContainerInset.width
        let topInset = max(16, (viewHeight - textHeight) / 2)
        textContainerInset = NSSize(width: insetX, height: topInset)
    }

    func updatePlaceholderVisibility() {
        placeholderLabel?.isHidden = !string.isEmpty
    }

    private func setupPlaceholder() {
        placeholderLabel?.removeFromSuperview()
        guard let text = placeholderText, !text.isEmpty else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.10)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
        placeholderLabel = label
        updatePlaceholderVisibility()
    }

    private func layoutPlaceholder() {
        guard let label = placeholderLabel else { return }
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        let availableWidth = bounds.width - inset.width * 2 - padding * 2
        label.preferredMaxLayoutWidth = availableWidth
        label.sizeToFit()
        label.frame = NSRect(
            x: (bounds.width - label.frame.width) / 2,
            y: inset.height,
            width: label.frame.width,
            height: label.frame.height
        )
    }
}

// MARK: - Main View

struct ContextSaveView: View {
    let existingNote: String?
    let startInReminder: Bool
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    @State private var phase: Phase
    @State private var inputText = ""

    private enum Phase { case input, reminder }

    init(existingNote: String?, startInReminder: Bool,
         onDismiss: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        self.existingNote = existingNote
        self.startInReminder = startInReminder
        self.onDismiss = onDismiss
        self.onSnooze = onSnooze
        _phase = State(initialValue: startInReminder ? .reminder : .input)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            switch phase {
            case .input:  inputPhase
            case .reminder: reminderPhase
            }
        }
        .frame(width: 380)
        .background(Color(white: 0.12))
    }

    private var titleBar: some View {
        Text("context save")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    // MARK: - Input Phase

    private var inputPhase: some View {
        VStack(spacing: 0) {
            ContextTextEditor(text: $inputText, placeholder: existingNote, onCommit: save, onCancel: onDismiss)
                .frame(height: 180)

            buttonBar {
                buttonCell(icon: "xmark", label: "Cancel") { onDismiss() }
                divider
                let empty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                buttonCell(icon: "square.and.arrow.down", label: "Save", dimmed: empty) { save() }
                    .disabled(empty)
            }
        }
    }

    // MARK: - Reminder Phase

    private var reminderPhase: some View {
        VStack(spacing: 0) {
            Text(AppSettings.shared.contextNote ?? "")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ZStack(alignment: .top) {
                buttonBar {
                    buttonCell(icon: "bell.badge", label: "Snooze") { onSnooze() }
                    divider
                    buttonCell(icon: "checkmark", label: "Resume", bold: true) { onDismiss() }
                }

                HoverButton(action: editNote) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(x: -1, y: -1)
                }
                .frame(width: 40, height: 40)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
                .overlay(
                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        .mask(VStack(spacing: 0) {
                            Color.clear.frame(height: 1)
                            Color.white
                        })
                )
            }
        }
    }

    // MARK: - Shared Components

    private func buttonBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity)
    }

    private func buttonCell(icon: String, label: String, bold: Bool = false, dimmed: Bool = false,
                            action: @escaping () -> Void) -> some View {
        HoverButton(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: bold ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(dimmed ? Color.white.opacity(0.3) : .white)
        }
    }

    private struct HoverButton<Label: View>: View {
        let action: () -> Void
        @ViewBuilder let label: () -> Label
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                label()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isHovered ? Color(white: 0.22) : Color(white: 0.18))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
    }

    private var divider: some View {
        Color.white.opacity(0.1)
            .frame(width: 1)
    }

    // MARK: - Actions

    private func editNote() {
        inputText = AppSettings.shared.contextNote ?? ""
        phase = .input
    }

    private func save() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppSettings.shared.contextNote = trimmed
        AppSettings.shared.save()
        phase = .reminder
    }
}
