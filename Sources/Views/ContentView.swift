import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject var whisperService: WhisperService
    @ObservedObject var settings = AppSettings.shared
    
    @State private var showingSummary = false
    @State private var showingRelationGraph = false
    @State private var showingSettings = false
    @State private var showingAIManager = false
    @State private var showingBatchTranscribe = false
    @State private var showingSubtitleManager = false
    @State private var showingNowPlaying = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showingNowPlaying && audioPlayer.currentTrack != nil {
                NowPlayingFullView(showingNowPlaying: $showingNowPlaying)
            } else {
                HSplitView {
                    PlaylistView()
                        .frame(minWidth: 260, maxWidth: 350)
                    
                    if audioPlayer.currentTrack != nil {
                        SubtitleContentView()
                    } else {
                        WelcomeView()
                    }
                }
            }
            
            BottomPlayerBar(
                showingNowPlaying: $showingNowPlaying,
                showingSummary: $showingSummary,
                showingRelationGraph: $showingRelationGraph,
                showingSettings: $showingSettings,
                showingAIManager: $showingAIManager,
                showingBatchTranscribe: $showingBatchTranscribe,
                showingSubtitleManager: $showingSubtitleManager
            )
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showingSummary) { SummaryView() }
        .sheet(isPresented: $showingRelationGraph) { RelationGraphView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingAIManager) { AIModelManagerView() }
        .sheet(isPresented: $showingBatchTranscribe) { BatchTranscribeView() }
        .sheet(isPresented: $showingSubtitleManager) { SubtitleManagerView() }
    }
    
    private var colorScheme: ColorScheme? {
        switch settings.theme.colorScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 欢迎页
struct WelcomeView: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.03), Color.purple.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 40) {
                Spacer()
                
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue.opacity(0.15), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 120, height: 120)
                        .scaleEffect(isAnimating ? 1.08 : 1.0)
                    
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: isAnimating)
                .onAppear { isAnimating = true }
                
                VStack(spacing: 8) {
                    Text("AI Audio Player")
                        .font(.system(size: 28, weight: .bold))
                    Text("智能音频播放 · 实时转写 · AI 分析")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 16) {
                    MiniFeatureCard(icon: "waveform", title: "语音转写", color: .blue)
                    MiniFeatureCard(icon: "sparkles", title: "AI 润色", color: .purple)
                    MiniFeatureCard(icon: "person.3.fill", title: "关系图谱", color: .orange)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left").font(.caption2)
                    Text("从左侧选择音频开始").font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 30)
            }
        }
    }
}

struct MiniFeatureCard: View {
    let icon: String
    let title: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundColor(color)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(width: 90, height: 70)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(12)
    }
}

// MARK: - 字幕内容视图
struct SubtitleContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(audioPlayer.currentTrack?.title ?? "")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    
                    if audioPlayer.isPreparingSubtitles {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5)
                            Text("准备字幕中...").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            
            SubtitleView()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - 正在播放全屏视图
struct NowPlayingFullView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @Binding var showingNowPlaying: Bool
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.blue.opacity(0.08), Color.purple.opacity(0.05), Color(NSColor.windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
            
            VStack(spacing: 0) {
                HStack {
                    Button(action: { showingNowPlaying = false }) {
                        Image(systemName: "chevron.down").font(.title3).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding()
                
                HStack(spacing: 40) {
                    VStack(spacing: 24) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [.blue.opacity(0.4), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                            Image(systemName: audioPlayer.isPlaying ? "waveform" : "music.note")
                                .font(.system(size: 60))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .frame(width: 280, height: 280)
                        
                        Text(audioPlayer.currentTrack?.title ?? "")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 280)
                        
                        VStack(spacing: 8) {
                            FullProgressBar()
                            FullPlayControls()
                        }
                        .frame(width: 280)
                    }
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Text("字幕").font(.headline).foregroundColor(.secondary)
                        SubtitleView()
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
        }
    }
}

struct FullProgressBar: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: progressWidth(in: geo.size.width), height: 4)
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { isDragging = true; dragValue = max(0, min(1, $0.location.x / geo.size.width)) * audioPlayer.duration }
                    .onEnded { _ in isDragging = false; audioPlayer.seek(to: dragValue) })
            }
            .frame(height: 4)
            
            HStack {
                Text(formatTime(isDragging ? dragValue : audioPlayer.currentTime)).font(.caption2).foregroundColor(.secondary).monospacedDigit()
                Spacer()
                Text(formatTime(audioPlayer.duration)).font(.caption2).foregroundColor(.secondary).monospacedDigit()
            }
        }
    }
    
    private func progressWidth(in w: CGFloat) -> CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return w * CGFloat((isDragging ? dragValue : audioPlayer.currentTime) / audioPlayer.duration)
    }
    
    private func formatTime(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

struct FullPlayControls: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        HStack(spacing: 32) {
            Button(action: { audioPlayer.playPrevious() }) { Image(systemName: "backward.fill").font(.title3) }.buttonStyle(.plain).foregroundColor(.secondary)
            Button(action: { audioPlayer.togglePlayPause() }) { Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 50)).foregroundColor(.accentColor) }.buttonStyle(.plain)
            Button(action: { audioPlayer.playNext() }) { Image(systemName: "forward.fill").font(.title3) }.buttonStyle(.plain).foregroundColor(.secondary)
        }
    }
}


// MARK: - 底部播放栏
struct BottomPlayerBar: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var whisperService: WhisperService
    @ObservedObject var settings = AppSettings.shared
    
    @Binding var showingNowPlaying: Bool
    @Binding var showingSummary: Bool
    @Binding var showingRelationGraph: Bool
    @Binding var showingSettings: Bool
    @Binding var showingAIManager: Bool
    @Binding var showingBatchTranscribe: Bool
    @Binding var showingSubtitleManager: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            if audioPlayer.currentTrack != nil { MiniProgressBar() }
            
            HStack(spacing: 0) {
                // 左侧：当前播放
                HStack(spacing: 12) {
                    if let track = audioPlayer.currentTrack {
                        Button(action: { showingNowPlaying.toggle() }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LinearGradient(colors: [.blue.opacity(0.4), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: audioPlayer.isPlaying ? "waveform" : "music.note")
                                    .font(.caption).foregroundColor(.white)
                            }
                            .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.plain)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(formatTime(audioPlayer.currentTime) + " / " + formatTime(audioPlayer.duration))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                    } else {
                        Text("未播放").font(.caption).foregroundColor(.secondary).frame(width: 180, alignment: .leading)
                    }
                }
                .frame(width: 250)
                
                Spacer()
                
                // 中间：播放控制
                HStack(spacing: 20) {
                    Menu {
                        ForEach(audioPlayer.availableRates, id: \.self) { rate in
                            Button("\(rate, specifier: "%.2g")x") { audioPlayer.setRate(rate) }
                        }
                    } label: {
                        Text("\(audioPlayer.playbackRate, specifier: "%.2g")x")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15)).cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { audioPlayer.playPrevious() }) { Image(systemName: "backward.fill").font(.system(size: 14)) }.buttonStyle(.plain).foregroundColor(.secondary)
                    Button(action: { audioPlayer.skipBackward() }) { Image(systemName: "gobackward.15").font(.system(size: 16)) }.buttonStyle(.plain).foregroundColor(.secondary)
                    Button(action: { audioPlayer.togglePlayPause() }) { Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)) }.buttonStyle(.plain).disabled(audioPlayer.currentTrack == nil)
                    Button(action: { audioPlayer.skipForward() }) { Image(systemName: "goforward.15").font(.system(size: 16)) }.buttonStyle(.plain).foregroundColor(.secondary)
                    Button(action: { audioPlayer.playNext() }) { Image(systemName: "forward.fill").font(.system(size: 14)) }.buttonStyle(.plain).foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 右侧：功能按钮
                HStack(spacing: 14) {
                    Menu {
                        Button(action: { showingSummary = true }) { Label("生成总结", systemImage: "doc.text") }
                        Button(action: { showingRelationGraph = true }) { Label("关系图谱", systemImage: "person.3.sequence") }
                        Divider()
                        Button(action: { showingBatchTranscribe = true }) { Label("批量转写", systemImage: "doc.on.doc") }
                        Button(action: { showingSubtitleManager = true }) { Label("字幕管理", systemImage: "list.bullet.rectangle") }
                        Divider()
                        Button(action: exportText) { Label("导出文本", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "sparkles").font(.system(size: 14))
                    }
                    .buttonStyle(.plain).foregroundColor(.purple)
                    
                    Button(action: toggleDesktopLyrics) { Image(systemName: settings.desktopLyrics.enabled ? "text.bubble.fill" : "text.bubble").font(.system(size: 14)) }
                        .buttonStyle(.plain).foregroundColor(settings.desktopLyrics.enabled ? .accentColor : .secondary)
                    
                    Button(action: { showingAIManager = true }) { Image(systemName: "cpu").font(.system(size: 14)) }.buttonStyle(.plain).foregroundColor(.secondary)
                    Button(action: { showingSettings = true }) { Image(systemName: "gearshape").font(.system(size: 14)) }.buttonStyle(.plain).foregroundColor(.secondary)
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func formatTime(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
    
    private func exportText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"
        if panel.runModal() == .OK, let url = panel.url { try? whisperService.currentTranscription.write(to: url, atomically: true, encoding: .utf8) }
    }
    
    private func toggleDesktopLyrics() {
        settings.desktopLyrics.enabled.toggle()
        DesktopLyricsWindowController.shared.toggle(with: whisperService, audioPlayer: audioPlayer)
    }
}

struct MiniProgressBar: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.1))
                Rectangle().fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: progressWidth(in: geo.size.width))
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { isDragging = true; dragValue = max(0, min(1, $0.location.x / geo.size.width)) * audioPlayer.duration }
                .onEnded { _ in isDragging = false; audioPlayer.seek(to: dragValue) })
        }
        .frame(height: isHovering || isDragging ? 4 : 2)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
    
    private func progressWidth(in w: CGFloat) -> CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return w * CGFloat((isDragging ? dragValue : audioPlayer.currentTime) / audioPlayer.duration)
    }
}
