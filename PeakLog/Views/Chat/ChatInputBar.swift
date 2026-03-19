import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    var isSending: Bool
    var voiceState: VoiceInputState
    var waveformSamples: [CGFloat]
    var onSend: () -> Void
    var onAttach: (() -> Void)? = nil
    var onVoiceToggle: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    private var submitAction: ChatInputSubmissionAction {
        ChatInputSubmissionAction(sendHandler: onSend)
    }

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
                Group {
                    if voiceState == .idle {
                        TextField(String(localized: "chat.input.placeholder"), text: $text)
                            .font(.chatBody)
                            .foregroundColor(.textPrimary)
                            .focused($isFocused)
                            .submitLabel(.send)
                            .onSubmit {
                                _ = submitAction.submit(text: text, isSending: canSubmit)
                            }
                    } else {
                        VoiceWaveformView(
                            samples: waveformSamples,
                            isTranscribing: voiceState == .transcribing
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Voice button
                Button {
                    onVoiceToggle?()
                } label: {
                    Image(systemName: voiceButtonSymbolName)
                        .font(.system(size: 17))
                        .foregroundColor(voiceButtonColor)
                }
                .disabled(voiceState == .transcribing)

                // Send button
                Button {
                    _ = submitAction.submit(text: text, isSending: canSubmit)
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
        .padding(.bottom, chatInputBarBottomPadding)
        .background(Color.appBackground)
    }

    private var canSend: Bool {
        !isSending && voiceState == .idle && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        isSending || voiceState != .idle
    }

    private var voiceButtonSymbolName: String {
        switch voiceState {
        case .idle:
            return "mic"
        case .recording:
            return "stop.fill"
        case .transcribing:
            return "waveform"
        }
    }

    private var voiceButtonColor: Color {
        switch voiceState {
        case .idle:
            return .textMuted
        case .recording:
            return .accentRed
        case .transcribing:
            return .textMuted
        }
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputBar(
            text: .constant(""),
            isSending: false,
            voiceState: .idle,
            waveformSamples: [],
            onSend: {}
        )
    }
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
