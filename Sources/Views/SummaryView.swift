import SwiftUI

// MARK: - 全局状态管理器（后台生成）
@MainActor
class SummaryManager: ObservableObject {
    static let shared = SummaryManager()
    
    @Published var isGenerating = false
    @Published var streamingText = ""
    @Published var summary: EpisodeSummary?
    @Published var error: String?
    @Published var currentTrackPath: String?
    
    private var currentTask: Task<Void, Never>?
    
    private var summaryDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HistoryPodcastPlayer/Summaries")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    // 稳定的 hash 函数（与 WhisperService 相同）
    private func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return hash
    }
    
    private func summaryFileURL(for trackPath: String) -> URL {
        let hash = stableHash(trackPath)
        return summaryDirectory.appendingPathComponent("\(hash).json")
    }
    
    // 加载已保存的总结
    func loadSummary(for trackPath: String) -> Bool {
        currentTrackPath = trackPath
        let fileURL = summaryFileURL(for: trackPath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(EpisodeSummary.self, from: data) else {
            summary = nil
            return false
        }
        
        summary = loaded
        print("📄 已加载总结: \(fileURL.lastPathComponent)")
        return true
    }
    
    // 保存总结
    private func saveSummary(_ summary: EpisodeSummary, for trackPath: String) {
        let fileURL = summaryFileURL(for: trackPath)
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: fileURL)
            print("💾 已保存总结: \(fileURL.lastPathComponent)")
        }
    }
    
    func generate(transcript: String, trackPath: String? = nil) {
        currentTask?.cancel()
        isGenerating = true
        streamingText = ""
        summary = nil
        error = nil
        
        let path = trackPath ?? currentTrackPath
        
        currentTask = Task {
            do {
                let result = try await OllamaService.shared.generateSummaryStreaming(
                    transcript: transcript,
                    onToken: { [weak self] token in
                        Task { @MainActor in
                            self?.streamingText += token
                        }
                    }
                )
                summary = result
                
                // 自动保存
                if let path = path {
                    saveSummary(result, for: path)
                }
            } catch {
                self.error = error.localizedDescription
            }
            isGenerating = false
        }
    }
    
    func cancel() {
        currentTask?.cancel()
        isGenerating = false
    }
    
    // 删除总结文件
    func deleteSummary(for trackPath: String) {
        let fileURL = summaryFileURL(for: trackPath)
        try? FileManager.default.removeItem(at: fileURL)
        print("🗑️ 已删除总结: \(fileURL.lastPathComponent)")
    }
    
    // 检查是否有已保存的总结
    func hasSummary(for trackPath: String) -> Bool {
        let fileURL = summaryFileURL(for: trackPath)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}

struct SummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var whisperService: WhisperService
    @StateObject private var manager = SummaryManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("内容总结")
                    .font(.headline)
                Spacer()
                
                if manager.isGenerating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                    Text("生成中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if manager.summary != nil && !manager.isGenerating {
                    Button(action: { startGeneration() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("重新生成")
                }
                
                Button("关闭") {
                    dismiss()
                }
                .help("关闭窗口（后台继续生成）")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 内容区域
            if manager.isGenerating {
                StreamingView(text: $manager.streamingText, isLoading: true)
            } else if let error = manager.error {
                ErrorView(message: error) {
                    startGeneration()
                }
            } else if let summary = manager.summary {
                SummaryContent(summary: summary)
            } else {
                EmptySummaryView {
                    startGeneration()
                }
            }
        }
        .frame(minWidth: 650, minHeight: 550)
        .onAppear {
            // 自动加载已保存的总结
            if let track = audioPlayer.currentTrack {
                let loaded = manager.loadSummary(for: track.url.path)
                if loaded {
                    print("✅ 总结已加载")
                }
            }
        }
    }
    
    private func startGeneration() {
        let transcript = whisperService.fullTranscript.isEmpty 
            ? whisperService.subtitles.map { $0.text }.joined(separator: " ")
            : whisperService.fullTranscript
        
        guard !transcript.isEmpty else {
            manager.error = "没有可用的转写文本，请先播放音频生成字幕"
            return
        }
        
        let trackPath = audioPlayer.currentTrack?.url.path
        manager.generate(transcript: transcript, trackPath: trackPath)
    }
}

// MARK: - 流式输出视图
struct StreamingView: View {
    @Binding var text: String
    let isLoading: Bool
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundColor(.accentColor)
                        Text("AI 正在生成...")
                            .font(.headline)
                    }
                    .padding(.bottom, 8)
                    
                    Text(text.isEmpty ? "等待响应..." : text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                    
                    if isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("生成中...（可关闭窗口，后台继续）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .id("bottom")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: text) { _, _ in
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
    }
}

struct SummaryContent: View {
    let summary: EpisodeSummary
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionView(title: "📝 内容概述") {
                    Text(summary.fullText)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                }
                
                if !summary.keyPoints.isEmpty {
                    SectionView(title: "💡 关键要点") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { index, point in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1).")
                                        .fontWeight(.medium)
                                        .foregroundColor(.accentColor)
                                    Text(point)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                
                if !summary.characters.isEmpty {
                    SectionView(title: "👤 主要人物") {
                        FlowLayout(spacing: 8) {
                            ForEach(summary.characters, id: \.self) { character in
                                Text(character)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(16)
                            }
                        }
                    }
                }
                
                if !summary.events.isEmpty {
                    SectionView(title: "📅 重要事件") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(summary.events.enumerated()), id: \.offset) { _, event in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 6)
                                    Text(event)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

struct SectionView<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
}

struct EmptySummaryView: View {
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("点击生成本集内容总结")
                .foregroundColor(.secondary)
            Button("生成总结", action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    let retryAction: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retryAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in width: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > width && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            self.size = CGSize(width: width, height: y + rowHeight)
        }
    }
}
