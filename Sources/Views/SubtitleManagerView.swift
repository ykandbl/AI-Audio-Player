import SwiftUI
import AVFoundation

// MARK: - 字幕状态
enum SubtitleStatus {
    case none           // 无字幕
    case partial        // 部分完成
    case complete       // 完整
    
    var icon: String {
        switch self {
        case .none: return "doc"
        case .partial: return "doc.badge.clock"
        case .complete: return "doc.badge.checkmark"
        }
    }
    
    var color: Color {
        switch self {
        case .none: return .secondary
        case .partial: return .orange
        case .complete: return .green
        }
    }
    
    var label: String {
        switch self {
        case .none: return "未转录"
        case .partial: return "未完成"
        case .complete: return "已完成"
        }
    }
}

// MARK: - 音频文件信息
struct AudioFileInfo: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let duration: TimeInterval
    var subtitleStatus: SubtitleStatus
    var subtitleEndTime: TimeInterval?
    
    var progressText: String {
        switch subtitleStatus {
        case .none:
            return "未转录"
        case .partial:
            if let endTime = subtitleEndTime {
                let percent = Int((endTime / duration) * 100)
                return "已转录 \(percent)%"
            }
            return "部分完成"
        case .complete:
            return "已完成"
        }
    }
}

// MARK: - 文件夹信息
struct FolderInfo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    var files: [AudioFileInfo]
    
    var completeCount: Int {
        files.filter { $0.subtitleStatus == .complete }.count
    }
    
    var partialCount: Int {
        files.filter { $0.subtitleStatus == .partial }.count
    }
    
    var totalCount: Int {
        files.count
    }
    
    static func == (lhs: FolderInfo, rhs: FolderInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - 字幕管理视图
struct SubtitleManagerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject var whisperService: WhisperService
    @Environment(\.dismiss) var dismiss
    
    @State private var folders: [FolderInfo] = []
    @State private var isLoading = true
    @State private var selectedFolder: FolderInfo?
    @State private var searchText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text("字幕管理")
                    .font(.headline)
                Spacer()
                Button(action: loadFolders) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding()
            
            Divider()
            
            if isLoading {
                Spacer()
                ProgressView("加载中...")
                Spacer()
            } else if folders.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "没有找到音频文件",
                    systemImage: "folder.badge.questionmark",
                    description: Text("请先在主界面打开一个包含音频文件的文件夹")
                )
                Spacer()
            } else {
                HSplitView {
                    // 左侧：文件夹列表
                    List(folders, selection: $selectedFolder) { folder in
                        FolderRow(folder: folder)
                            .tag(folder)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 200, maxWidth: 300)
                    
                    // 右侧：文件列表
                    if let folder = selectedFolder {
                        FileListView(
                            folder: folder,
                            searchText: $searchText,
                            onPlay: playFile,
                            onDelete: deleteSubtitle
                        )
                    } else {
                        ContentUnavailableView(
                            "选择文件夹",
                            systemImage: "folder",
                            description: Text("从左侧选择一个文件夹查看转录状态")
                        )
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            loadFolders()
        }
    }
    
    private func loadFolders() {
        isLoading = true
        
        Task {
            var folderURLs: Set<URL> = []
            
            // 从 audioPlayer.playlist 获取
            for track in audioPlayer.playlist {
                let folderURL = track.url.deletingLastPathComponent()
                folderURLs.insert(folderURL)
            }
            
            // 从 playlistManager.rootPlaylists 获取（修复：之前用的是 playlists）
            func collectFolders(from playlist: Playlist) {
                folderURLs.insert(playlist.folderURL)
                for track in playlist.tracks {
                    let folderURL = track.url.deletingLastPathComponent()
                    folderURLs.insert(folderURL)
                }
                // 递归处理子播放列表
                for subPlaylist in playlist.subPlaylists {
                    collectFolders(from: subPlaylist)
                }
            }
            
            for playlist in playlistManager.rootPlaylists {
                collectFolders(from: playlist)
            }
            
            // 构建文件夹信息
            var newFolders: [FolderInfo] = []
            
            for folderURL in folderURLs {
                let files = await scanFolder(folderURL)
                if !files.isEmpty {
                    let folder = FolderInfo(
                        url: folderURL,
                        name: folderURL.lastPathComponent,
                        files: files
                    )
                    newFolders.append(folder)
                }
            }
            
            // 按名称排序
            newFolders.sort { $0.name < $1.name }
            
            await MainActor.run {
                folders = newFolders
                isLoading = false
                
                // 自动选择第一个文件夹
                if selectedFolder == nil, let first = folders.first {
                    selectedFolder = first
                }
            }
        }
    }
    
    private func scanFolder(_ folderURL: URL) async -> [AudioFileInfo] {
        let fm = FileManager.default
        let supportedExtensions = ["m4a", "mp3", "wav", "aac", "flac"]
        
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var files: [AudioFileInfo] = []
        
        for fileURL in contents {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            
            // 获取音频时长
            let asset = AVURLAsset(url: fileURL)
            let duration: TimeInterval
            if let d = try? await asset.load(.duration) {
                duration = CMTimeGetSeconds(d)
            } else {
                duration = 0
            }
            
            // 检查字幕状态
            let (status, endTime) = await checkSubtitleStatus(for: fileURL, audioDuration: duration)
            
            files.append(AudioFileInfo(
                url: fileURL,
                name: fileURL.deletingPathExtension().lastPathComponent,
                duration: duration,
                subtitleStatus: status,
                subtitleEndTime: endTime
            ))
        }
        
        // 排序
        return files.sorted { $0.name < $1.name }
    }
    
    private func checkSubtitleStatus(for audioURL: URL, audioDuration: TimeInterval) async -> (SubtitleStatus, TimeInterval?) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let subtitleDir = appSupport.appendingPathComponent("HistoryPodcastPlayer/Subtitles")
        
        let fileName = audioURL.deletingPathExtension().lastPathComponent
        // 使用稳定的 hash（基于文件名，与 WhisperService 保持一致）
        let hash = stableHash(audioURL.lastPathComponent)
        var subtitlePath = subtitleDir.appendingPathComponent("\(fileName)_\(abs(hash)).srt")
        
        // 如果新格式不存在，尝试查找旧格式
        if !FileManager.default.fileExists(atPath: subtitlePath.path) {
            if let legacyPath = findLegacySubtitle(for: audioURL, in: subtitleDir) {
                subtitlePath = legacyPath
            }
        }
        
        guard FileManager.default.fileExists(atPath: subtitlePath.path),
              let content = try? String(contentsOf: subtitlePath, encoding: .utf8) else {
            return (.none, nil)
        }
        
        // 解析字幕获取最后时间
        let subtitles = parseSRT(content)
        guard let lastSub = subtitles.last else {
            return (.none, nil)
        }
        
        let endTime = lastSub.endTime
        
        // 判断是否完整（差距小于5秒认为完整）
        if endTime >= audioDuration - 5 {
            return (.complete, endTime)
        } else {
            return (.partial, endTime)
        }
    }
    
    private func parseSRT(_ content: String) -> [(startTime: TimeInterval, endTime: TimeInterval)] {
        var subs: [(TimeInterval, TimeInterval)] = []
        for block in content.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 2 else { continue }
            let times = lines[1].components(separatedBy: " --> ")
            guard times.count == 2 else { continue }
            subs.append((parseSRTTime(times[0]), parseSRTTime(times[1])))
        }
        return subs
    }
    
    private func parseSRTTime(_ t: String) -> TimeInterval {
        let p = t.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard p.count == 3 else { return 0 }
        let hours = Double(p[0]) ?? 0
        let mins = Double(p[1]) ?? 0
        let secs = Double(p[2]) ?? 0
        return hours * 3600 + mins * 60 + secs
    }
    
    /// 稳定的 hash 函数（跨会话一致）
    private func stableHash(_ string: String) -> Int {
        var hash = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(char)
        }
        return hash
    }
    
    /// 查找旧格式的字幕文件（兼容之前使用不稳定 hash 保存的文件）
    private func findLegacySubtitle(for audioURL: URL, in subtitleDir: URL) -> URL? {
        let fileName = audioURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(at: subtitleDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        
        // 查找以文件名开头的 .srt 文件
        for file in contents {
            if file.pathExtension == "srt" && file.lastPathComponent.hasPrefix(fileName + "_") {
                return file
            }
        }
        return nil
    }
    
    private func playFile(_ file: AudioFileInfo) {
        let track = AudioTrack(url: file.url)
        audioPlayer.play(track: track)
        dismiss()
    }
    
    private func deleteSubtitle(for file: AudioFileInfo) {
        whisperService.deleteSubtitle(for: file.url)
        loadFolders()
    }
}

// MARK: - 文件夹行
struct FolderRow: View {
    let folder: FolderInfo
    
    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if folder.completeCount > 0 {
                        Label("\(folder.completeCount)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    if folder.partialCount > 0 {
                        Label("\(folder.partialCount)", systemImage: "clock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Text("共\(folder.totalCount)个")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 文件列表视图
struct FileListView: View {
    let folder: FolderInfo
    @Binding var searchText: String
    let onPlay: (AudioFileInfo) -> Void
    let onDelete: (AudioFileInfo) -> Void
    
    var filteredFiles: [AudioFileInfo] {
        if searchText.isEmpty {
            return folder.files
        }
        return folder.files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索文件...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 统计信息
            HStack {
                Text(folder.name)
                    .font(.headline)
                Spacer()
                HStack(spacing: 12) {
                    StatusBadge(count: folder.completeCount, status: .complete)
                    StatusBadge(count: folder.partialCount, status: .partial)
                    StatusBadge(count: folder.totalCount - folder.completeCount - folder.partialCount, status: .none)
                }
            }
            .padding()
            
            Divider()
            
            // 文件列表
            List {
                ForEach(filteredFiles) { file in
                    SubtitleFileRow(file: file, onPlay: onPlay, onDelete: onDelete)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(folder.name)
    }
}

// MARK: - 状态徽章
struct StatusBadge: View {
    let count: Int
    let status: SubtitleStatus
    
    var body: some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                Text("\(count)")
            }
            .font(.caption)
            .foregroundColor(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

// MARK: - 字幕文件行
struct SubtitleFileRow: View {
    let file: AudioFileInfo
    let onPlay: (AudioFileInfo) -> Void
    let onDelete: (AudioFileInfo) -> Void
    
    @State private var isHovering = false
    @State private var showDeleteConfirm = false
    
    var body: some View {
        HStack {
            // 状态图标
            Image(systemName: file.subtitleStatus.icon)
                .foregroundColor(file.subtitleStatus.color)
                .frame(width: 24)
            
            // 文件信息
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                
                HStack {
                    Text(formatDuration(file.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(file.progressText)
                        .font(.caption)
                        .foregroundColor(file.subtitleStatus.color)
                }
            }
            
            Spacer()
            
            // 操作按钮
            if isHovering {
                HStack(spacing: 8) {
                    Button(action: { onPlay(file) }) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .help("播放")
                    
                    if file.subtitleStatus != .none {
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("删除字幕")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            onPlay(file)
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                onDelete(file)
            }
        } message: {
            Text("确定要删除「\(file.name)」的字幕文件吗？\n删除后下次播放需要重新转录。")
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
