import LinksKit
import SwiftUI
import UIKit

/// Quick picks and the current custom reaction. Picking the current one again removes it.
struct ReactionBar: View {
    let current: String?
    let pick: (String) -> Void
    @State private var choosingEmoji = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { buttons }
                    .fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], spacing: 0) { buttons }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 26))
            if let current, !reactionEmojis.contains(current) {
                Button {
                    pick(current)
                } label: {
                    Text(current)
                        .font(.system(size: 28))
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.22), in: .circle)
                }
                .buttonStyle(PopButtonStyle())
                .accessibilityLabel("Remove your reaction, \(current)")
                .accessibilityIdentifier("reaction.currentCustom")
                .padding(.leading, 8)
            }
        }
        .customReactionPicker(isPresented: $choosingEmoji, pick: pick)
    }

    @ViewBuilder private var buttons: some View {
        ForEach(reactionEmojis, id: \.self) { emoji in
            Button {
                pick(emoji)
            } label: {
                Text(emoji)
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .background(emoji == current ? Color.accentColor.opacity(0.22) : .clear, in: .circle)
                    .contentShape(.rect)
            }
            .buttonStyle(PopButtonStyle())
            .accessibilityAddTraits(emoji == current ? .isSelected : [])
            .accessibilityHint(emoji == current ? "Removes your reaction" : "")
            .accessibilityIdentifier("reaction.\(emoji)")
        }
        Button {
            choosingEmoji = true
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PopButtonStyle())
        .accessibilityLabel("Choose Emoji")
        .accessibilityIdentifier("reaction.custom")
    }
}

/// Grows a little under the finger, like Messages' tapbacks.
private struct PopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.25 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.5), value: configuration.isPressed)
    }
}

extension View {
    func customReactionPicker(isPresented: Binding<Bool>, pick: @escaping (String) -> Void) -> some View {
        modifier(CustomReactionPresentation(isPresented: isPresented, pick: pick))
    }
}

private struct CustomReactionPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let pick: (String) -> Void
    @State private var selected: String?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            if let emoji = selected {
                selected = nil
                pick(emoji)
            }
        }) {
            CustomReactionPicker { emoji in
                selected = emoji
                isPresented = false
            }
        }
    }
}

private struct CustomReactionPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""
    let pick: (String) -> Void

    // Only the server has the full standard emoji sequence table.
    private var canReact: Bool {
        guard emoji.utf8.count <= 64, emoji.count == 1,
              let first = emoji.unicodeScalars.first, first.properties.isEmoji else { return false }
        return !first.isASCII || emoji.unicodeScalars.last == "\u{20E3}"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EmojiKeyboardField(text: $emoji)
                        .frame(minHeight: 44)
                } footer: {
                    Text("Choose or paste one emoji.")
                }
            }
            .navigationTitle("Choose Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("React") { pick(emoji) }
                        .disabled(!canReact)
                        .accessibilityIdentifier("reaction.confirm")
                }
            }
        }
    }
}

private struct EmojiKeyboardField: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiTextField()
        field.font = .systemFont(ofSize: 28)
        field.placeholder = "Emoji"
        field.accessibilityLabel = "Emoji"
        field.accessibilityIdentifier = "reaction.emoji"
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.addAction(UIAction { [weak field] _ in text = field?.text ?? "" }, for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
    }
}

private final class EmojiTextField: UITextField {
    private var didFocus = false

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    override var textInputContextIdentifier: String? { "link-reaction" }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = becomeFirstResponder()
    }
}
