import SwiftUI
import AVFoundation

// MARK: - 批量转写任务
struct TranscribeTask: Identifiable {
    let id = UUID()
    let audioURL: URL
    var status: TaskStatus = .pending
    var progress: Double = 0
    
    var fileName: String { audioURL.deletingPathExtension().lastPathComponent }
    
    enum TaskStatus: String {
        case pending = "等待中"
        case transcribing = "转写中"
        case polishing = "润色中"
        case completed = "已完成"
        case failed = "失败"
        case skipped = "已跳过"
    }
}

// MARK: - 批量转写管理器
@MainActor
class BatchTranscribeManager: ObservableObject {
    static var shared: BatchTranscribeManager?
    
    @Published var allAudioFiles: [URL] = []
    @Published var tasks: [TranscribeTask] = []
    @Published var isProcessing = false
    @Published var currentTaskIndex = 0
    @Published var showOnlyWithoutSubtitle = true
    @Published var currentStatus = ""
    @Published var mode: BatchMode = .full  // 批量模式
    
    enum BatchMode {
        case full       // 完整转写
        case initialize // 初始化（只转前1分钟）
    }
    
    private var whisperService: WhisperService?
    private var shouldCancel = false
    
    var filteredFiles: [URL] {
        if showOnlyWithoutSubtitle {
            return allAudioFiles.filter { !hasSubtitle(for: $0) }
        }
        return allAudioFiles
    }
    
    var completedCount: Int { tasks.filter { $0.status == .completed || $0.status == .skipped }.count }
    var totalCount: Int { tasks.count }
    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        let totalProgress = tasks.reduce(0.0) { $0 + $1.progress }
        return totalProgress / Double(totalCount)
    }
    
    init() {
        BatchTranscribeManager.shared = self
    }
    
    func setWhisperService(_ service: WhisperService) {
        self.whisperService = service
    }
    
    func loadAudioFiles(from folderURLs: [URL]) {
        var files: [URL] = []
        let supportedExtensions = ["m4a", "mp3", "wav", "aac", "flac"]
        let fm = FileManager.default
        
        for folder in folderURLs {
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                while let url = enumerator.nextObject() as? URL {
                    if supportedExtensions.contains(url.pathExtension.lowercased()) {
                        files.append(url)
                    }
                }
            }
        }
        
        allAudioFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    func hasSubtitle(for audioURL: URL) -> Bool {
        whisperService?.hasSubtitle(for: audioURL) ?? false
    }
    
    // 批量初始化（只转前1分钟）
    func startBatchInitialize(urls: [URL]) {
        mode = .initialize
        shouldCancel = false
        tasks = urls.map { TranscribeTask(audioURL: $0) }
        isProcessing = true
        currentTaskIndex = 0
        
        Task {
            await processInitializeTask()
        }
    }
    
    private func processInitializeTask() async {
        guard !shouldCancel else {
            isProcessing = false
            return
        }
        
        guard let index = tasks.firstIndex(where: { $0.status == .pending }) else {
            isProcessing = false
            currentStatus = "全部完成"
            return
        }
        
        currentTaskIndex = index
        tasks[index].status = .transcribing
        tasks[index].progress = 0.1
        currentStatus = "初始化: \(tasks[index].fileName)"
        
        let url = tasks[index].audioURL
        
        guard let whisper = self.whisperService else {
            tasks[index].status = .failed
            await processInitializeTask()
            return
        }
        
        // 等待之前的任务完成
        while whisper.isProcessing {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        
        // 确保模型已加载
        if !whisper.isModelLoaded {
            tasks[index].progress = 0.15
            currentStatus = "加载模型中..."
            await whisper.loadModel()
        }
        
        guard whisper.isModelLoaded else {
            tasks[index].status = .failed
            await processInitializeTask()
            return
        }
        
        print("🚀 初始化转写: \(url.lastPathComponent) (前60秒)")
        
        // 只转写前60秒
        do {
            tasks[index].progress = 0.2
            currentStatus = "转写中: \(tasks[index].fileName)"
            
            let success = try await whisper.initializeTranscription(audioURL: url, duration: 60)
            
            if success {
                tasks[index].status = .completed
                tasks[index].progress = 1.0
                print("✅ 初始化完成: \(tasks[index].fileName)")
            } else {
                tasks[index].status = .failed
                print("❌ 初始化失败: \(tasks[index].fileName)")
            }
        } catch {
            tasks[index].status = .failed
            print("❌ 初始化错误: \(error)")
        }
        
        // 处理下一个
        await processInitializeTask()
    }
    
    func startBatchTranscribe(urls: [URL], forceRetranscribe: Bool = false) {
        mode = .full
        shouldCancel = false
        tasks = urls.map { TranscribeTask(audioURL: $0) }
        
        isProcessing = true
        currentTaskIndex = 0
        
        Task {
            await processNextTask(forceRetranscribe: forceRetranscribe)
        }
    }
    
    private func processNextTask(forceRetranscribe: Bool) async {
        guard !shouldCancel else {
            isProcessing = false
            return
        }
        
        // 找到下一个待处理的任务
        guard let index = tasks.firstIndex(where: { $0.status == .pending }) else {
            isProcessing = false
            currentStatus = "全部完成"
            return
        }
        
        currentTaskIndex = index
        tasks[index].status = .transcribing
        tasks[index].progress = 0.02
        currentStatus = "正在转写: \(tasks[index].fileName)"
        
        let url = tasks[index].audioURL
        
        guard let whisper = self.whisperService else {
            print("❌ 批量转写失败: whisperService 为空")
            self.tasks[index].status = .failed
            await processNextTask(forceRetranscribe: forceRetranscribe)
            return
        }
        
        // 等待之前的任务完全结束
        while whisper.isProcessing {
            print("⏳ 等待上一个任务完成...")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        // 如果强制重新转写，先删除旧字幕
        if forceRetranscribe {
            print("🗑️ 删除旧字幕: \(url.lastPathComponent)")
            whisper.deleteSubtitle(for: url)
        }
        
        // 确保模型已加载
        if !whisper.isModelLoaded {
            tasks[index].progress = 0.05
            currentStatus = "加载模型中..."
            print("📦 加载 Whisper 模型...")
            await whisper.loadModel()
        }
        
        guard whisper.isModelLoaded else {
            print("❌ 批量转写失败: 模型未加载, error: \(whisper.error ?? "unknown")")
            tasks[index].status = .failed
            await processNextTask(forceRetranscribe: forceRetranscribe)
            return
        }
        
        print("🎙️ 开始转写: \(url.lastPathComponent)")
        
        // 开始转写
        whisper.startFullTranscription(audioURL: url, forceTranscribe: forceRetranscribe)
        tasks[index].progress = 0.05
        
        // 给一点时间让 isProcessing 变为 true
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // 获取音频时长用于估算进度
        var estimatedDuration: Double = 600 // 默认10分钟
        if let asset = try? AVURLAsset(url: url),
           let duration = try? await asset.load(.duration) {
            estimatedDuration = CMTimeGetSeconds(duration)
        }
        // 估算转写时间：large-v3 大约是音频时长的 1/5 到 1/3
        let estimatedTranscribeTime = estimatedDuration / 4.0
        let startTime = Date()
        
        // 等待转写完成
        while whisper.isProcessing && !shouldCancel {
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            let progressText = whisper.processingProgress
            let elapsed = Date().timeIntervalSince(startTime)
            
            if progressText.contains("下载") {
                tasks[index].progress = 0.02
                currentStatus = "下载模型中..."
            } else if progressText.contains("加载") {
                tasks[index].progress = 0.05
                currentStatus = "加载模型中..."
            } else if progressText.contains("转写中") {
                tasks[index].status = .transcribing
                // 基于时间估算进度，转写阶段占 0.05 到 0.5
                let transcribeProgress = min(elapsed / estimatedTranscribeTime, 1.0)
                tasks[index].progress = 0.05 + transcribeProgress * 0.45
                let remaining = max(0, estimatedTranscribeTime - elapsed)
                currentStatus = "转写中: \(tasks[index].fileName) (约\(Int(remaining))秒)"
            } else if progressText.contains("润色") {
                tasks[index].status = .polishing
                // 解析润色进度 (1/4) 这样的格式
                if let range = progressText.range(of: #"\((\d+)/(\d+)\)"#, options: .regularExpression) {
                    let match = String(progressText[range])
                    let nums = match.filter { $0.isNumber || $0 == "/" }.split(separator: "/")
                    if nums.count == 2, let current = Int(nums[0]), let total = Int(nums[1]) {
                        tasks[index].progress = 0.5 + 0.45 * Double(current) / Double(total)
                    }
                } else {
                    tasks[index].progress = 0.6
                }
                currentStatus = "AI润色中: \(tasks[index].fileName)"
            } else if progressText.contains("完成") {
                tasks[index].progress = 0.98
            }
        }
        
        if shouldCancel {
            tasks[index].status = .failed
            isProcessing = false
            return
        }
        
        // 额外等待一下确保状态更新
        try? await Task.sleep(nanoseconds: 300_000_000)
        
        // 检查结果
        print("✅ 转写结束: hasPreprocessedSubtitle=\(whisper.hasPreprocessedSubtitle), transcript长度=\(whisper.fullTranscript.count), error=\(whisper.error ?? "none")")
        
        if whisper.hasPreprocessedSubtitle && !whisper.fullTranscript.isEmpty {
            tasks[index].status = .completed
            tasks[index].progress = 1.0
            print("✅ 转写成功: \(tasks[index].fileName)")
        } else if let err = whisper.error {
            tasks[index].status = .failed
            print("❌ 转写失败: \(err)")
        } else if whisper.fullTranscript.isEmpty {
            tasks[index].status = .failed
            print("❌ 转写失败: 结果为空")
        } else {
            tasks[index].status = .completed
            tasks[index].progress = 1.0
        }
        
        // 处理下一个
        await processNextTask(forceRetranscribe: forceRetranscribe)
    }
    
    func cancelAll() {
        shouldCancel = true
        whisperService?.stopTranscription()
        for i in tasks.indices where tasks[i].status == .pending || tasks[i].status == .transcribing || tasks[i].status == .polishing {
            tasks[i].status = .failed
        }
        isProcessing = false
        currentStatus = "已取消"
    }
}

// MARK: - 批量转写视图
struct BatchTranscribeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject var whisperService: WhisperService
    
    // 使用共享的 manager，这样最小化后再打开能恢复状态
    @ObservedObject private var manager: BatchTranscribeManager
    
    @State private var selectedFiles: Set<URL> = []
    @State private var showingProgress: Bool
    @State private var selectCount = 20
    @State private var forceRetranscribe = false
    
    init() {
        // 如果已有共享实例且正在处理，使用它
        if let existing = BatchTranscribeManager.shared {
            _manager = ObservedObject(wrappedValue: existing)
            _showingProgress = State(initialValue: existing.isProcessing || !existing.tasks.isEmpty)
        } else {
            let newManager = BatchTranscribeManager()
            _manager = ObservedObject(wrappedValue: newManager)
            _showingProgress = State(initialValue: false)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("批量转写管理")
                    .font(.headline)
                Spacer()
                
                if manager.isProcessing || !manager.tasks.isEmpty {
                    Text(manager.currentStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    ProgressView(value: manager.overallProgress)
                        .frame(width: 100)
                    Text("\(manager.completedCount)/\(manager.totalCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if showingProgress {
                // 进度视图
                ProgressListView(manager: manager)
            } else {
                // 文件选择视图
                FileSelectionView(
                    manager: manager,
                    selectedFiles: $selectedFiles,
                    selectCount: $selectCount
                )
            }
            
            Divider()
            
            // 底部按钮
            HStack {
                if showingProgress {
                    Button("返回选择") {
                        if !manager.isProcessing {
                            showingProgress = false
                            selectedFiles.removeAll()
                            manager.tasks.removeAll()
                        }
                    }
                    .disabled(manager.isProcessing)
                    
                    if manager.isProcessing {
                        Button("最小化") {
                            dismiss()
                        }
                        .help("关闭窗口，转写将在后台继续，点击「批量转写」按钮可重新打开")
                    }
                } else {
                    Toggle("只显示未转写", isOn: $manager.showOnlyWithoutSubtitle)
                    
                    Toggle("强制重新转写", isOn: $forceRetranscribe)
                        .help("即使已有字幕也重新转写")
                    
                    Spacer()
                    
                    HStack {
                        Text("快速选择")
                        Stepper("\(selectCount) 个", value: $selectCount, in: 5...100, step: 5)
                        Button("选择") {
                            quickSelect(count: selectCount)
                        }
                    }
                }
                
                Spacer()
                
                if showingProgress && manager.isProcessing {
                    Button("取消全部") {
                        manager.cancelAll()
                    }
                    .foregroundColor(.red)
                }
                
                if !showingProgress {
                    Text("已选 \(selectedFiles.count) 个")
                        .foregroundColor(.secondary)
                    
                    // 批量初始化按钮（只转前1分钟）
                    Button("批量初始化") {
                        startInitialize()
                    }
                    .help("只转写每个音频的前1分钟，快速预处理")
                    .disabled(selectedFiles.isEmpty)
                    
                    Button("完整转写") {
                        startTranscribe()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFiles.isEmpty)
                }
                
                Button(manager.isProcessing ? "最小化" : "关闭") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(width: 750, height: 500)
        .onAppear {
            manager.setWhisperService(whisperService)
            loadFiles()
            // 如果有正在进行的任务，显示进度
            if manager.isProcessing || !manager.tasks.isEmpty {
                showingProgress = true
            }
        }
    }
    
    private func loadFiles() {
        let folders = playlistManager.rootPlaylists.map { $0.folderURL }
        manager.loadAudioFiles(from: folders)
    }
    
    private func quickSelect(count: Int) {
        selectedFiles.removeAll()
        for file in manager.filteredFiles.prefix(count) {
            selectedFiles.insert(file)
        }
    }
    
    private func startInitialize() {
        let urls = Array(selectedFiles).sorted { $0.lastPathComponent < $1.lastPathComponent }
        manager.startBatchInitialize(urls: urls)
        showingProgress = true
    }
    
    private func startTranscribe() {
        let urls = Array(selectedFiles).sorted { $0.lastPathComponent < $1.lastPathComponent }
        manager.startBatchTranscribe(urls: urls, forceRetranscribe: forceRetranscribe)
        showingProgress = true
    }
}

// MARK: - 文件选择视图
struct FileSelectionView: View {
    @ObservedObject var manager: BatchTranscribeManager
    @Binding var selectedFiles: Set<URL>
    @Binding var selectCount: Int
    
    var body: some View {
        List {
            ForEach(manager.filteredFiles, id: \.self) { url in
                FileRow(
                    url: url,
                    hasSubtitle: manager.hasSubtitle(for: url),
                    isSelected: selectedFiles.contains(url)
                ) {
                    if selectedFiles.contains(url) {
                        selectedFiles.remove(url)
                    } else {
                        selectedFiles.insert(url)
                    }
                }
            }
        }
    }
}

struct FileRow: View {
    let url: URL
    let hasSubtitle: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if hasSubtitle {
                Text("已有字幕")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 进度列表视图
struct ProgressListView: View {
    @ObservedObject var manager: BatchTranscribeManager
    
    var body: some View {
        List {
            ForEach(manager.tasks) { task in
                TaskProgressRow(task: task)
            }
        }
    }
}

struct TaskProgressRow: View {
    let task: TranscribeTask
    
    var body: some View {
        HStack {
            statusIcon
            
            VStack(alignment: .leading) {
                Text(task.fileName)
                    .lineLimit(1)
                Text(task.status.rawValue)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            
            Spacer()
            
            if task.status == .transcribing || task.status == .polishing {
                ProgressView(value: task.progress)
                    .frame(width: 80)
                Text("\(Int(task.progress * 100))%")
                    .font(.caption)
                    .frame(width: 35)
            } else if task.status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if task.status == .failed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            } else if task.status == .skipped {
                Text("已有字幕")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    
    private var statusIcon: some View {
        Group {
            switch task.status {
            case .pending:
                Image(systemName: "clock").foregroundColor(.secondary)
            case .transcribing, .polishing:
                ProgressView().scaleEffect(0.6)
            case .completed:
                Image(systemName: "checkmark").foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark").foregroundColor(.red)
            case .skipped:
                Image(systemName: "arrow.right.circle").foregroundColor(.secondary)
            }
        }
        .frame(width: 20)
    }
    
    private var statusColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .transcribing, .polishing: return .blue
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}
