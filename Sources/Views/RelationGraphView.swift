import SwiftUI

// MARK: - 全局状态管理器（后台生成）
@MainActor
class RelationManager: ObservableObject {
    static let shared = RelationManager()
    
    @Published var isGenerating = false
    @Published var streamingText = ""
    @Published var graphData: RelationGraphData?
    @Published var error: String?
    @Published var currentTrackPath: String?
    
    private var currentTask: Task<Void, Never>?
    
    private var relationDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HistoryPodcastPlayer/Relations")
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
    
    private func relationFileURL(for trackPath: String) -> URL {
        let hash = stableHash(trackPath)
        return relationDirectory.appendingPathComponent("\(hash).json")
    }
    
    // 加载已保存的关系图
    func loadRelation(for trackPath: String) -> Bool {
        currentTrackPath = trackPath
        let fileURL = relationFileURL(for: trackPath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(RelationGraphDataCodable.self, from: data) else {
            graphData = nil
            return false
        }
        
        // 重建 levels 字典
        var levels: [Int: [CharacterInfo]] = [:]
        for char in loaded.characters {
            if levels[char.level] == nil {
                levels[char.level] = []
            }
            levels[char.level]?.append(char)
        }
        
        graphData = RelationGraphData(
            characters: loaded.characters,
            relations: loaded.relations,
            levels: levels
        )
        print("📄 已加载关系图: \(fileURL.lastPathComponent)")
        return true
    }
    
    // 保存关系图
    private func saveRelation(_ data: RelationGraphData, for trackPath: String) {
        let fileURL = relationFileURL(for: trackPath)
        let codable = RelationGraphDataCodable(
            characters: data.characters,
            relations: data.relations
        )
        if let jsonData = try? JSONEncoder().encode(codable) {
            try? jsonData.write(to: fileURL)
            print("💾 已保存关系图: \(fileURL.lastPathComponent)")
        }
    }
    
    func generate(transcript: String, trackPath: String? = nil) {
        currentTask?.cancel()
        isGenerating = true
        streamingText = ""
        graphData = nil
        error = nil
        
        let path = trackPath ?? currentTrackPath
        
        currentTask = Task {
            do {
                let result = try await OllamaService.shared.extractHierarchyRelations(
                    transcript: transcript,
                    onToken: { [weak self] token in
                        Task { @MainActor in
                            self?.streamingText += token
                        }
                    }
                )
                graphData = result
                
                // 自动保存
                if let path = path {
                    saveRelation(result, for: path)
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
    
    // 删除关系图文件
    func deleteRelation(for trackPath: String) {
        let fileURL = relationFileURL(for: trackPath)
        try? FileManager.default.removeItem(at: fileURL)
        print("🗑️ 已删除关系图: \(fileURL.lastPathComponent)")
    }
    
    // 检查是否有已保存的关系图
    func hasRelation(for trackPath: String) -> Bool {
        let fileURL = relationFileURL(for: trackPath)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}

// 用于序列化的结构
struct RelationGraphDataCodable: Codable {
    let characters: [CharacterInfo]
    let relations: [CharacterRelation]
}

struct RelationGraphView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var whisperService: WhisperService
    @StateObject private var manager = RelationManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("人物关系图")
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
                
                if manager.graphData != nil && !manager.isGenerating {
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
                RelationStreamingView(text: $manager.streamingText)
            } else if let error = manager.error {
                RelationErrorView(message: error) {
                    startGeneration()
                }
            } else if let data = manager.graphData {
                HierarchyGraphContent(graphData: data)
            } else {
                EmptyRelationView {
                    startGeneration()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            // 自动加载已保存的关系图
            if let track = audioPlayer.currentTrack {
                let loaded = manager.loadRelation(for: track.url.path)
                if loaded {
                    print("✅ 关系图已加载: \(manager.graphData?.characters.count ?? 0) 个人物")
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
struct RelationStreamingView: View {
    @Binding var text: String
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundColor(.accentColor)
                        Text("AI 正在分析人物关系...")
                            .font(.headline)
                    }
                    .padding(.bottom, 8)
                    
                    Text(text.isEmpty ? "等待响应..." : text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                    
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("生成中...（可关闭窗口，后台继续）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .id("bottom")
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

// MARK: - 层级关系图内容
struct HierarchyGraphContent: View {
    let graphData: RelationGraphData
    
    // 找出没有连线的人物
    var isolatedCharacters: [String] {
        let connectedNames = Set(graphData.relations.flatMap { [$0.from, $0.to] })
        return graphData.characters.map { $0.name }.filter { !connectedNames.contains($0) }
    }
    
    var body: some View {
        HSplitView {
            // 左侧：关系列表
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("人物层级")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(graphData.characters.count) 人")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                
                List {
                    ForEach(graphData.levels.sorted(by: { $0.key < $1.key }), id: \.key) { level, chars in
                        Section(header: Text(levelName(level))) {
                            ForEach(chars, id: \.name) { char in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(char.name)
                                            .fontWeight(.medium)
                                        if isolatedCharacters.contains(char.name) {
                                            Text("(无连线)")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    if !char.title.isEmpty {
                                        Text(char.title)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    
                    if !graphData.relations.isEmpty {
                        Section(header: Text("关系 (\(graphData.relations.count))")) {
                            ForEach(graphData.relations.prefix(20)) { rel in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(rel.from)
                                            .foregroundColor(.accentColor)
                                        Image(systemName: "arrow.right")
                                            .font(.caption)
                                        Text(rel.to)
                                            .foregroundColor(.accentColor)
                                    }
                                    Text(rel.relation)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 200, maxWidth: 280)
            
            // 右侧：层级图
            HierarchyGraphVisualization(graphData: graphData)
        }
    }
    
    private func levelName(_ level: Int) -> String {
        switch level {
        case 1: return "👑 第一层（核心）"
        case 2: return "🎖️ 第二层"
        case 3: return "👤 第三层"
        default: return "第\(level)层"
        }
    }
}

// MARK: - 层级图可视化（可拖动）
struct HierarchyGraphVisualization: View {
    let graphData: RelationGraphData
    @State private var nodePositions: [String: CGPoint] = [:]
    @State private var scale: CGFloat = 1.0
    @State private var hasInitialized = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 绘制连线
                ForEach(graphData.relations) { relation in
                    if let fromPos = nodePositions[relation.from],
                       let toPos = nodePositions[relation.to] {
                        DraggableRelationLine(
                            from: fromPos,
                            to: toPos,
                            label: relation.relation,
                            relationType: relation.type
                        )
                    }
                }
                
                // 绘制人物节点（可拖动）
                ForEach(graphData.characters, id: \.name) { character in
                    if let position = nodePositions[character.name] {
                        DraggableCharacterNode(character: character)
                            .position(position)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        nodePositions[character.name] = value.location
                                    }
                            )
                    }
                }
            }
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(value, 0.5), 2.0)
                    }
            )
            .onAppear {
                // 延迟初始化，确保 geometry 有正确的尺寸
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !hasInitialized {
                        initializePositions(width: geometry.size.width, height: geometry.size.height)
                        hasInitialized = true
                    }
                }
            }
            .onChange(of: geometry.size) { oldSize, newSize in
                // 只在尺寸显著变化时重新布局
                if abs(newSize.width - oldSize.width) > 50 || abs(newSize.height - oldSize.height) > 50 {
                    initializePositions(width: newSize.width, height: newSize.height)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 8) {
                Button(action: { scale = min(scale + 0.2, 2.0) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button(action: { scale = max(scale - 0.2, 0.5) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button(action: { 
                    hasInitialized = false
                    nodePositions.removeAll()
                    scale = 1.0
                    // 触发重新布局
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        hasInitialized = false
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("重新布局")
            }
            .buttonStyle(.bordered)
            .padding()
        }
        .overlay(alignment: .topLeading) {
            Text("💡 拖动节点调整位置，双指缩放")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                .cornerRadius(6)
                .padding()
        }
    }
    
    private func initializePositions(width: CGFloat, height: CGFloat) {
        let count = graphData.characters.count
        print("🔧 初始化布局: \(count) 人物, 区域: \(width) x \(height)")
        
        guard count > 0, width > 100, height > 100 else { 
            print("⚠️ 区域太小或无人物，跳过布局")
            return 
        }
        
        nodePositions.removeAll()
        
        // 智能分层
        let levelGroups = smartGrouping(graphData.characters, relations: graphData.relations)
        let sortedLevels = levelGroups.keys.sorted()
        let levelCount = max(sortedLevels.count, 1)
        
        // 布局参数
        let padding: CGFloat = 80
        let usableWidth = max(width - padding * 2, 200)
        let usableHeight = max(height - padding * 2, 200)
        let levelHeight = usableHeight / CGFloat(levelCount)
        
        print("📐 分层: \(levelCount) 层, 可用区域: \(usableWidth) x \(usableHeight)")
        
        for (levelIndex, level) in sortedLevels.enumerated() {
            guard let chars = levelGroups[level] else { continue }
            let charCount = chars.count
            
            // Y 坐标：从上到下分布
            let y = padding + levelHeight * CGFloat(levelIndex) + levelHeight / 2
            
            // X 坐标：均匀分布
            let spacing = usableWidth / CGFloat(charCount + 1)
            
            for (charIndex, char) in chars.enumerated() {
                let x = padding + spacing * CGFloat(charIndex + 1)
                // 添加小幅随机偏移
                let offsetX = CGFloat.random(in: -15...15)
                let offsetY = CGFloat.random(in: -10...10)
                let finalX = x + offsetX
                let finalY = y + offsetY
                
                nodePositions[char.name] = CGPoint(x: finalX, y: finalY)
                print("  📍 \(char.name): (\(Int(finalX)), \(Int(finalY)))")
            }
        }
        
        print("✅ 布局完成: \(nodePositions.count) 个节点")
    }
    
    // 智能分组
    private func smartGrouping(_ characters: [CharacterInfo], relations: [CharacterRelation]) -> [Int: [CharacterInfo]] {
        var levels: [Int: [CharacterInfo]] = [:]
        let count = characters.count
        
        if count <= 3 {
            levels[1] = characters
            return levels
        }
        
        // 构建关系图，计算重要性
        var importance: [String: Int] = [:]
        for char in characters {
            importance[char.name] = 0
        }
        for rel in relations {
            importance[rel.from, default: 0] += 1
            importance[rel.to, default: 0] += 2  // 被指向更重要
        }
        
        // 按重要性排序
        let sortedChars = characters.sorted { 
            (importance[$0.name] ?? 0) > (importance[$1.name] ?? 0) 
        }
        
        // 每行最多 4 个人
        let maxPerRow = 4
        var currentLevel = 1
        var currentCount = 0
        
        for char in sortedChars {
            if currentCount >= maxPerRow {
                currentLevel += 1
                currentCount = 0
            }
            if levels[currentLevel] == nil {
                levels[currentLevel] = []
            }
            levels[currentLevel]?.append(char)
            currentCount += 1
        }
        
        return levels
    }
    
    private func doNothing() {
        // placeholder
    }
}

// MARK: - 可拖动的人物节点
struct DraggableCharacterNode: View {
    let character: CharacterInfo
    @State private var isHovered = false
    
    var nodeColor: Color {
        switch character.role {
        case "emperor", "king": return .red
        case "queen", "consort": return .pink
        case "minister", "official": return .blue
        case "general": return .orange
        default: return .accentColor
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(nodeColor)
                .frame(width: isHovered ? 52 : 44, height: isHovered ? 52 : 44)
                .overlay(
                    Text(String(character.name.prefix(1)))
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                        .font(isHovered ? .title3 : .body)
                )
                .shadow(color: nodeColor.opacity(0.5), radius: isHovered ? 8 : 4)
            
            VStack(spacing: 2) {
                Text(character.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                if !character.title.isEmpty && isHovered {
                    Text(character.title)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .cornerRadius(6)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .cursor(.openHand)
    }
}

// MARK: - 关系连线
struct DraggableRelationLine: View {
    let from: CGPoint
    let to: CGPoint
    let label: String
    let relationType: String
    
    var lineColor: Color {
        switch relationType {
        case "family": return .red.opacity(0.6)
        case "political": return .blue.opacity(0.6)
        case "enemy": return .orange.opacity(0.6)
        default: return .secondary.opacity(0.5)
        }
    }
    
    var body: some View {
        ZStack {
            // 曲线连接
            Path { path in
                path.move(to: from)
                let midY = (from.y + to.y) / 2
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x, y: midY),
                    control2: CGPoint(x: to.x, y: midY)
                )
            }
            .stroke(lineColor, lineWidth: 2)
            
            // 关系标签
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                .cornerRadius(4)
                .position(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        }
    }
}

// 自定义光标
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - 空状态视图
struct EmptyRelationView: View {
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("点击分析人物关系")
                .foregroundColor(.secondary)
            Button("分析关系", action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RelationErrorView: View {
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
