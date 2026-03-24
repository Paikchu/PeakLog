import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ChatScreen: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var didRunDebugAutoSend = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var hasUserInitiatedHistoryScroll = false
    var onShowHistory: (() -> Void)?
    var onShowProfile: (() -> Void)?

    private let keyboardAwareChatScrollAction = KeyboardAwareChatScrollAction()
    private let chatScrollKeyboardDismissBehavior = ChatScrollKeyboardDismissBehavior()

    init(
        conversationId: String,
        onShowHistory: (() -> Void)? = nil,
        onShowProfile: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: ChatViewModel(conversationId: conversationId)
        )
        self.onShowHistory = onShowHistory
        self.onShowProfile = onShowProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            ChatInputBar(
                text: $viewModel.inputText,
                isSending: viewModel.isSending,
                voiceState: viewModel.voiceInputState
            ) {
                Task { await viewModel.sendMessage() }
            } onVoiceToggle: {
                Task { await viewModel.toggleVoiceInput() }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .task { await viewModel.onAppear() }
        .task {
            await runDebugAutoSendIfNeeded()
        }
        .onDisappear { Task { await viewModel.onDisappear() } }
        .alert("common.error_title", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @MainActor
    private func runDebugAutoSendIfNeeded() async {
        #if DEBUG
        guard !didRunDebugAutoSend else { return }
        guard let message = ProcessInfo.processInfo.environment["PEAKLOG_DEBUG_AUTOSEND_MESSAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return }

        didRunDebugAutoSend = true
        viewModel.inputText = message

        // Give the initial history/realtime setup a moment to settle before sending.
        try? await Task.sleep(nanoseconds: 800_000_000)
        await viewModel.sendMessage()
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                onShowHistory?()
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 20))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
            }

            Spacer()

            Text("content.chat_title")
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .tracking(-0.4)

            Spacer()

            Button {
                onShowProfile?()
            } label: {
                Image(systemName: "person.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .dismissKeyboardOnTap()
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        historyLoadSentinel
                        ForEach(viewModel.messageGroups) { group in
                            dateSection(group: group)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .dismissKeyboardOnTap()
            .chatScrollDismissesKeyboard(chatScrollKeyboardDismissBehavior)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { value in
                    guard value.translation.height > 0 else { return }
                    hasUserInitiatedHistoryScroll = true
                }
            )
            .onChange(of: viewModel.shouldScrollToBottomOnce) { _, shouldScroll in
                guard shouldScroll else { return }
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                viewModel.consumeScrollToBottomRequest()
            }
            .onChange(of: viewModel.pendingTopAnchorMessageID) { _, anchorID in
                guard let anchorID else { return }
                proxy.scrollTo(anchorID, anchor: .top)
                viewModel.consumePendingTopAnchorMessageID()
            }
            .onReceive(keyboardFrameDidChangePublisher) { notification in
                let nextKeyboardHeight = keyboardHeight(from: notification)
                let shouldScroll = keyboardAwareChatScrollAction.shouldScrollToLatestMessage(
                    previousKeyboardHeight: keyboardHeight,
                    currentKeyboardHeight: nextKeyboardHeight
                )

                keyboardHeight = nextKeyboardHeight

                guard shouldScroll else { return }

                withAnimation(keyboardAnimation(from: notification)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onReceive(keyboardWillHidePublisher) { _ in
                keyboardHeight = 0
            }
        }
    }

    private var keyboardFrameDidChangePublisher: NotificationCenter.Publisher {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        #else
        NotificationCenter.default.publisher(for: Notification.Name("keyboardWillChangeFrameNotification"))
        #endif
    }

    private var keyboardWillHidePublisher: NotificationCenter.Publisher {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        #else
        NotificationCenter.default.publisher(for: Notification.Name("keyboardWillHideNotification"))
        #endif
    }

    private func keyboardHeight(from notification: Notification) -> CGFloat {
        #if canImport(UIKit)
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }

        let screenHeight = UIScreen.main.bounds.height
        return max(0, screenHeight - endFrame.minY)
        #else
        _ = notification
        return 0
        #endif
    }

    private func keyboardAnimation(from notification: Notification) -> Animation {
        #if canImport(UIKit)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        return .easeOut(duration: duration)
        #else
        _ = notification
        return .easeOut(duration: 0.25)
        #endif
    }

    // MARK: - Date Section

    private var historyLoadSentinel: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                guard hasUserInitiatedHistoryScroll else { return }
                guard let anchorMessageID = viewModel.messageGroups.first?.messages.first?.id else { return }
                Task {
                    await viewModel.loadPreviousDayIfNeeded(anchorMessageID: anchorMessageID)
                }
            }
    }

    @ViewBuilder
    private func dateSection(group: MessageGroup) -> some View {
        VStack(spacing: 10) {
            HStack {
                Rectangle().fill(Color.appSeparator).frame(height: 1)
                Text(group.label)
                    .font(.dateLabel)
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 8)
                    .fixedSize()
                Rectangle().fill(Color.appSeparator).frame(height: 1)
            }
            .padding(.vertical, 4)

            ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, _ in
                let groupIndex = viewModel.messageGroups.firstIndex { $0.id == group.id }!
                let message = viewModel.messageGroups[groupIndex].messages[index]

                Group {
                    if message.isTyping {
                        // Typing bubble — AI is processing
                        TypingBubbleView()
                    } else {
                        MessageBubbleView(
                            message: $viewModel.messageGroups[groupIndex].messages[index],
                            onDeleteExercise: { _, exerciseId in
                                let msg = group.messages[index]
                                Task {
                                    await viewModel.deleteExercise(
                                        messageId: msg.id,
                                        workoutRecordId: msg.workoutRecord?.id ?? "",
                                        exerciseId: exerciseId
                                    )
                                }
                            },
                            onSetChanged: { _, exerciseId, updatedSet in
                                let msg = group.messages[index]
                                Task {
                                    await viewModel.updateSet(
                                        messageId: msg.id,
                                        exerciseId: exerciseId,
                                        setId: updatedSet.id,
                                        weight: updatedSet.weight,
                                        weightUnit: updatedSet.weightUnit,
                                        reps: updatedSet.reps
                                    )
                                }
                            }
                        )
                    }
                }
                .id(message.id)
            }
        }
    }
}

// MARK: - Typing Bubble View
// Shown while the AI is processing (message.status == .processing)

struct TypingBubbleView: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.textMuted)
                        .frame(width: 7, height: 7)
                        .offset(y: animating ? -4 : 0)
                        .animation(
                            .easeInOut(duration: 0.4)
                                .repeatForever()
                                .delay(Double(i) * 0.15),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .onAppear { animating = true }
    }
}

#Preview {
    // Preview with mock conversation ID — uses MockChatService fallback
    // In production this comes from authState.defaultConversationId
    ChatScreen(conversationId: "preview-conversation-id")
        .preferredColorScheme(.dark)
}
