import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ChatInputBar: View {
    @Binding var text: String
    var isSending: Bool
    var voiceState: VoiceInputState
    var waveformSamples: [CGFloat]
    var onSend: () -> Void
    var onAttach: (() -> Void)? = nil
    var onVoiceToggle: (() -> Void)? = nil

    @State private var isFocused: Bool = false
    @State private var textViewHeight: CGFloat = 0

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

            // Multiline input field
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if voiceState == .idle {
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(String(localized: "chat.input.placeholder"))
                                    .font(.chatBody)
                                    .foregroundColor(.textMuted)
                                    .padding(.top, 1)
                            }

                            multilineInput
                                .frame(height: max(textViewHeight, minimumTextViewHeight))
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
            .padding(.vertical, chatInputBarTextVerticalPadding)
            .background(Color.appSurface)
            .clipShape(
                RoundedRectangle(cornerRadius: chatInputBarTextCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: chatInputBarTextCornerRadius, style: .continuous)
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

    @ViewBuilder
    private var multilineInput: some View {
        #if canImport(UIKit)
        MultilineChatTextView(
            text: $text,
            calculatedHeight: $textViewHeight,
            isFocused: $isFocused,
            placeholder: String(localized: "chat.input.placeholder")
        )
        #else
        Text(String(localized: "chat.input.placeholder"))
            .font(.chatBody)
            .foregroundColor(.textPrimary)
        #endif
    }

    private var minimumTextViewHeight: CGFloat {
        #if canImport(UIKit)
        UIFont.systemFont(ofSize: 14.5, weight: .regular).lineHeight
            * CGFloat(chatInputBarMinimumVisibleLineCount)
        #else
        20
        #endif
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
