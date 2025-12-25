import SwiftUI

struct SubtitleView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var whisperService: WhisperService
    
    var body: some View {
        VStack(spacing: 0) {
            if !whisperService.processingProgress.isEmpty || whisperService.error != nil || whisperService.hasPreprocessedSubtitle {
                StatusBar(whisperService: whisperService)
            }
            
            if audioPlayer.currentTrack == nil {
                EmptySubtitlePlaceholder()
            } else if whisperService.subtitles.isEmpty && whisperService.isProcessing {
                ProcessingView(whisperService: whisperService)
            } else if whisperService.subtitles.isEmpty && !whisperService.isModelLoaded {
                ModelLoadingView(whisperService: whisperService)
            } else if whisperService.subtitles.isEmpty {
                WaitingView(whisperService: whisperService, audioPlayer: audioPlayer)
            } else {
                SubtitleContent(subtitles: whisperService.subtitles, currentTime: audioPlayer.currentTime)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onChange(of: audioPlayer.currentTrack) { _, newTrack in
            if let track = newTrack {
                whisperService.startTranscription(audioURL: track.url)
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var whisperService: WhisperService
    
    var body: some View {
        HStack {
            if let error = whisperService.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(error).foregroundColor(.orange).lineLimit(1)
            } else if whisperService.hasPreprocessedSubtitle && !whisperService.isProcessing {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("已加载缓存字幕").foregroundColor(.green)
            } else if !whisperService.processingProgress.isEmpty {
                ProgressView().scaleEffect(0.7)
                Text(whisperService.processingProgress).foregroundColor(.secondary)
            }
            Spacer()
            if whisperService.isProcessing {
                Button("停止") { whisperService.stopTranscription() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct ModelLoadingView: View {
    @ObservedObject var whisperService: WhisperService
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("正在加载语音识别模型...").foregroundColor(.secondary)
            Button("重新加载") { Task { await whisperService.loadModel() } }.buttonStyle(.bordered)
        }
    }
}

struct WaitingView: View {
    @ObservedObject var whisperService: WhisperService
    @ObservedObject var audioPlayer: AudioPlayerService
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 48)).foregroundColor(.secondary)
            if whisperService.isModelLoaded {
                Text("模型已就绪").foregroundColor(.green)
                if let track = audioPlayer.currentTrack {
                    Button("开始转写") { whisperService.startTranscription(audioURL: track.url) }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("等待模型加载...").foregroundColor(.secondary)
            }
        }
    }
}

struct EmptySubtitlePlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble").font(.system(size: 48)).foregroundColor(.secondary)
            Text("选择音频后显示字幕").foregroundColor(.secondary)
        }
    }
}

struct ProcessingView: View {
    @ObservedObject var whisperService: WhisperService
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.5)
            Text(whisperService.processingProgress.isEmpty ? "正在生成字幕..." : whisperService.processingProgress).foregroundColor(.secondary)
            if whisperService.isProcessing {
                Button("取消") { whisperService.stopTranscription() }.buttonStyle(.bordered)
            }
        }
    }
}

struct SubtitleContent: View {
    let subtitles: [Subtitle]
    let currentTime: TimeInterval
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(subtitles) { subtitle in
                        SubtitleRow(subtitle: subtitle, isActive: isActive(subtitle)).id(subtitle.id)
                    }
                }
                .padding()
            }
            .onChange(of: currentTime) { _, _ in
                if let active = subtitles.first(where: { isActive($0) }) {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(active.id, anchor: .center) }
                }
            }
        }
    }
    
    private func isActive(_ s: Subtitle) -> Bool { currentTime >= s.startTime && currentTime < s.endTime }
}

struct SubtitleRow: View {
    let subtitle: Subtitle
    let isActive: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(formatTime(subtitle.startTime)).font(.caption).foregroundColor(.secondary).monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(subtitle.text).font(.system(size: 16)).foregroundColor(isActive ? .primary : .secondary).fontWeight(isActive ? .medium : .regular)
                .padding(.vertical, 4).padding(.horizontal, 8).background(isActive ? Color.accentColor.opacity(0.1) : Color.clear).cornerRadius(4)
        }
    }
    
    private func formatTime(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t)/60, Int(t)%60) }
}
