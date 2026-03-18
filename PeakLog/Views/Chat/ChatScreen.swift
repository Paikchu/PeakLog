import SwiftUI

struct ChatScreen: View {
    @StateObject private var viewModel = ChatViewModel()
    var onShowHistory: (() -> Void)?
    var onShowProfile: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            ChatInputBar(
                text: $viewModel.inputText,
                isSending: viewModel.isSending
            ) {
                Task { await viewModel.sendMessage() }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .task { await viewModel.loadMessages() }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
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

            Text("AI Gym Logger")
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
        .padding(.top, 0)
        .padding(.bottom, 8)
    }

    // MARK: - Message List
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        ForEach(viewModel.messageGroups) { group in
                            dateSection(group: group)
                        }
                    }
                    // Scroll anchor
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .onChange(of: viewModel.messageGroups) { _, _ in
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Date Section
    @ViewBuilder
    private func dateSection(group: MessageGroup) -> some View {
        VStack(spacing: 8) {
            // Date separator
            HStack {
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(height: 1)
                Text(group.label)
                    .font(.dateLabel)
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 8)
                    .fixedSize()
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(height: 1)
            }
            .padding(.vertical, 4)

            // Messages in this group
            ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, _ in
                let groupIndex = viewModel.messageGroups.firstIndex { $0.id == group.id }!
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
    }
}

#Preview {
    ChatScreen()
        .preferredColorScheme(.dark)
}
