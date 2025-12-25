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
    
    var body: some View {
        HSplitView {
            PlaylistView()
                .frame(minWidth: 200, maxWidth: 300)
            
            VStack(spacing: 0) {
                PlayerView()
                
                Divider()
                
                SubtitleView()
                    .frame(minHeight: 150)
                
                Divider()
                
                BottomToolbar(
                    showingSummary: $showingSummary,
                    showingRelationGraph: $showingRelationGraph,
                    showingSettings: $showingSettings,
                    showingAIManager: $showingAIManager,
                    showingBatchTranscribe: $showingBatchTranscribe,
                    showingSubtitleManager: $showingSubtitleManager,
                    whisperService: whisperService,
                    audioPlayer: audioPlayer
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showingSummary) {
            SummaryView()
        }
        .sheet(isPresented: $showingRelationGraph) {
            RelationGraphView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingAIManager) {
            AIModelManagerView()
        }
        .sheet(isPresented: $showingBatchTranscribe) {
            BatchTranscribeView()
        }
        .sheet(isPresented: $showingSubtitleManager) {
            SubtitleManagerView()
        }
    }
    
    private var colorScheme: ColorScheme? {
        switch settings.theme.colorScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct BottomToolbar: View {
    @Binding var showingSummary: Bool
    @Binding var showingRelationGraph: Bool
    @Binding var showingSettings: Bool
    @Binding var showingAIManager: Bool
    @Binding var showingBatchTranscribe: Bool
    @Binding var showingSubtitleManager: Bool
    @ObservedObject var whisperService: WhisperService
    @ObservedObject var audioPlayer: AudioPlayerService
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        HStack(spacing: 16) {
            // 批量转写按钮 - 显示进度
            Button(action: { showingBatchTranscribe = true }) {
                HStack(spacing: 4) {
                    if let manager = BatchTranscribeManager.shared, manager.isProcessing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                        Text("\(manager.completedCount)/\(manager.totalCount)")
                            .font(.caption)
                    } else {
                        Image(systemName: "doc.on.doc")
                    }
                    Text("批量转写")
                }
            }
            .help(BatchTranscribeManager.shared?.isProcessing == true ? "点击查看转写进度" : "批量转写音频文件")
            
            // 字幕管理按钮
            Button(action: { showingSubtitleManager = true }) {
                Label("字幕管理", systemImage: "list.bullet.rectangle")
            }
            .help("查看和管理已转录的字幕文件")
            Button(action: { showingSummary = true }) {
                Label("生成总结", systemImage: "doc.text")
            }
            
            Button(action: { showingRelationGraph = true }) {
                Label("人物关系图", systemImage: "person.3.sequence")
            }
            
            Button(action: exportText) {
                Label("导出文本", systemImage: "square.and.arrow.up")
            }
            
            Divider()
                .frame(height: 20)
            
            Button(action: { toggleDesktopLyrics() }) {
                Label(
                    settings.desktopLyrics.enabled ? "关闭桌面歌词" : "桌面歌词",
                    systemImage: settings.desktopLyrics.enabled ? "text.bubble.fill" : "text.bubble"
                )
            }
            
            Spacer()
            
            Button(action: { showingAIManager = true }) {
                Label("AI 管理", systemImage: "cpu")
            }
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func exportText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            try? whisperService.currentTranscription.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    private func toggleDesktopLyrics() {
        settings.desktopLyrics.enabled.toggle()
        DesktopLyricsWindowController.shared.toggle(with: whisperService, audioPlayer: audioPlayer)
    }
}
