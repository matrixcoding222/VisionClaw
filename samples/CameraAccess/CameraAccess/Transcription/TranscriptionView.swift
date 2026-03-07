import SwiftUI

struct TranscriptionOverlayView: View {
  @ObservedObject var viewModel: TranscriptionViewModel

  var body: some View {
    VStack {
      // Connection status bar at top
      TranscriptionStatusBar(state: viewModel.connectionState)

      Spacer()

      // Scrollable transcript panel at bottom
      TranscriptionPanel(viewModel: viewModel)
        .padding(.bottom, 80)
    }
    .padding(.all, 24)
  }
}

// MARK: - Status Bar

struct TranscriptionStatusBar: View {
  let state: DeepgramConnectionState

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
      Text(statusText)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.black.opacity(0.6))
    .cornerRadius(16)
  }

  private var statusColor: Color {
    switch state {
    case .connected: return .green
    case .connecting: return .yellow
    case .disconnected: return .gray
    case .error: return .red
    }
  }

  private var statusText: String {
    switch state {
    case .connected: return "Transcribing"
    case .connecting: return "Connecting..."
    case .disconnected: return "Disconnected"
    case .error(let msg): return "Error: \(msg)"
    }
  }
}

// MARK: - Transcript Panel

struct TranscriptionPanel: View {
  @ObservedObject var viewModel: TranscriptionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if viewModel.segments.isEmpty {
        Text("Listening...")
          .font(.system(size: 15))
          .foregroundColor(.white.opacity(0.5))
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 20)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(viewModel.segments) { segment in
                TranscriptSegmentRow(segment: segment)
                  .id(segment.id)
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
          .onChange(of: viewModel.segments.count) { _ in
            if let lastId = viewModel.segments.last?.id {
              withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
              }
            }
          }
          .onChange(of: viewModel.currentPartialText) { _ in
            if let lastId = viewModel.segments.last?.id {
              withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .frame(maxHeight: 300)
    .background(Color.black.opacity(0.7))
    .cornerRadius(16)
  }
}

// MARK: - Segment Row

struct TranscriptSegmentRow: View {
  let segment: TranscriptSegment

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if let speaker = segment.speaker {
        Text("S\(speaker + 1)")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundColor(speakerColor(speaker))
          .frame(width: 28)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(segment.text)
          .font(.system(size: 15))
          .foregroundColor(segment.isFinal ? .white : .white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)

        Text(timeString(segment.timestamp))
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.white.opacity(0.3))
      }
    }
  }

  private func speakerColor(_ speaker: Int) -> Color {
    let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan]
    return colors[speaker % colors.count]
  }

  private func timeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}
