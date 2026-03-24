import SwiftUI

struct ChatTranscriptView: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(geminiVM.messages) { message in
            MessageBubbleView(message: message)
              .id(message.id)
          }
        }
        .padding(.vertical, 12)
      }
      .onChange(of: geminiVM.messages.count) { _, _ in
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(geminiVM.messages.last?.id, anchor: .bottom)
        }
      }
      .onChange(of: geminiVM.messages.last?.text) { _, _ in
        proxy.scrollTo(geminiVM.messages.last?.id, anchor: .bottom)
      }
    }
  }
}

struct MessageBubbleView: View {
  let message: ChatMessage

  var body: some View {
    switch message.role {
    case .user:
      userBubble
    case .assistant:
      assistantBubble
    case .toolCall(let name):
      toolCallPill(name: name)
    }
  }

  private var userBubble: some View {
    HStack {
      Spacer(minLength: 60)
      Text(message.text)
        .font(.system(size: 15))
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.blue)
        .cornerRadius(18)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 2)
  }

  private var assistantBubble: some View {
    HStack {
      VStack(alignment: .leading, spacing: 0) {
        Text(message.text)
          .font(.system(size: 15))
          .foregroundColor(.white.opacity(0.9))
        if message.status == .streaming {
          TypingCursor()
            .padding(.top, 2)
        }
      }
      Spacer(minLength: 60)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 2)
  }

  private func toolCallPill(name: String) -> some View {
    HStack(spacing: 6) {
      if message.status == .streaming {
        ProgressView()
          .scaleEffect(0.6)
          .tint(.white)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
          .font(.system(size: 12))
      }
      Text(name)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.8))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.white.opacity(0.15))
    .cornerRadius(12)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
  }
}

struct TypingCursor: View {
  @State private var visible = true

  var body: some View {
    RoundedRectangle(cornerRadius: 1)
      .fill(Color.white.opacity(0.6))
      .frame(width: 2, height: 14)
      .opacity(visible ? 1 : 0)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
          visible = false
        }
      }
  }
}
