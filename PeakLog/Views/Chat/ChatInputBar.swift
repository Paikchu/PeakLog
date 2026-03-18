import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void
    var onAttach: (() -> Void)? = nil
    var onVoice: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Attachment button (V1.5 placeholder)
            Button {
                onAttach?()
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 19))
                    .foregroundColor(.textMuted)
            }
            .padding(.leading, 4)

            // Pill-shaped input field
            HStack(spacing: 8) {
                TextField("Tell me your workout...", text: $text, axis: .vertical)
                    .font(.chatBody)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        if !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSend()
                        }
                    }

                // Voice button
                Button {
                    onVoice?()
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundColor(.textMuted)
                }

                // Send button
                Button {
                    onSend()
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend
                                  ? LinearGradient.accentGradient
                                  : LinearGradient(colors: [Color.accentPurple.opacity(0.45)],
                                                   startPoint: .leading, endPoint: .trailing))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.appSeparator, lineWidth: 0.8)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 0)
        .background(Color.appBackground)
    }

    private var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputBar(text: .constant(""), isSending: false, onSend: {})
    }
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
