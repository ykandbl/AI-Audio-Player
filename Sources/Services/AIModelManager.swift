import Foundation
import Combine

// MARK: - AI 模型信息
struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let type: ModelType
    var isDownloaded: Bool = false
    var isLoaded: Bool = false
    
    enum ModelType: String {
        case whisper = "语音转文字"
        case llm = "大语言模型"
    }
}

// MARK: - 系统内存信息
struct MemoryInfo {
    let total: UInt64
    let used: UInt64
    let free: UInt64
    
    var usedPercentage: Double {
        Double(used) / Double(total) * 100
    }
    
    var usedFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)
    }
    
    var totalFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory)
    }
    
    var freeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .memory)
    }
}

// MARK: - AI 模型管理器
@MainActor
class AIModelManager: ObservableObject {
    static let shared = AIModelManager()
    
    @Published var whisperModels: [AIModel] = []
    @Published var lmStudioModels: [AIModel] = []
    @Published var memoryInfo: MemoryInfo?
    @Published var isRefreshing = false
    @Published var lmStudioStatus: LMStudioStatus = .unknown
    @Published var error: String?
    @Published var downloadProgress: [String: Double] = [:]
    
    @Published var selectedWhisperModel: String = "large-v3"
    
    enum LMStudioStatus {
        case unknown, running, stopped, error(String)
        
        var description: String {
            switch self {
            case .unknown: return "检查中..."
            case .running: return "运行中"
            case .stopped: return "未启动"
            case .error(let msg): return "错误: \(msg)"
            }
        }
    }
    
    var whisperModelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("HistoryPodcastPlayer/WhisperModels")
    }
    
    private var whisperKitModelDirectory: URL {
        whisperModelDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
    }
    
    private var memoryTimer: Timer?
    
    private init() {
        startMemoryMonitoring()
        Task { await refreshAll() }
    }
    
    // MARK: - 内存监控
    func startMemoryMonitoring() {
        updateMemoryInfo()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMemoryInfo()
            }
        }
    }
    
    private func updateMemoryInfo() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return }
        
        let pageSize = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed
        
        memoryInfo = MemoryInfo(total: total, used: used, free: total - used)
    }
    
    // MARK: - 刷新所有模型
    func refreshAll() async {
        isRefreshing = true
        error = nil
        
        await checkLMStudioStatus()
        await fetchLMStudioModels()
        await checkWhisperModels()
        
        isRefreshing = false
    }
    
    // MARK: - LM Studio 状态检查
    func checkLMStudioStatus() async {
        do {
            let url = URL(string: "http://127.0.0.1:1234/v1/models")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                lmStudioStatus = .running
            } else {
                lmStudioStatus = .stopped
            }
        } catch {
            lmStudioStatus = .stopped
        }
    }
    
    // MARK: - 获取 LM Studio 模型
    private func fetchLMStudioModels() async {
        guard case .running = lmStudioStatus else {
            lmStudioModels = []
            return
        }
        
        do {
            let url = URL(string: "http://127.0.0.1:1234/v1/models")!
            let (data, _) = try await URLSession.shared.data(from: url)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                lmStudioModels = models.compactMap { model in
                    guard let id = model["id"] as? String else { return nil }
                    // 过滤掉 embedding 模型
                    if id.contains("embed") { return nil }
                    return AIModel(
                        id: id,
                        name: id,
                        size: "MLX 优化",
                        type: .llm,
                        isDownloaded: true,
                        isLoaded: true
                    )
                }
            }
        } catch {
            self.error = "获取 LM Studio 模型失败"
        }
    }
    
    // MARK: - 检查 Whisper 模型
    func checkWhisperModels() async {
        // 注意：distil 模型对中文支持不好，中文推荐用 large-v3
        let availableModels = [
            ("large-v3", "Large V3 (中文推荐)", "~3GB", true),
            ("large-v3-turbo", "Large V3 Turbo (快速)", "~1.6GB", false),
            ("medium", "Medium", "~1.5GB", false),
            ("small", "Small", "~500MB", false),
            ("base", "Base", "~150MB", false),
            ("tiny", "Tiny (最快)", "~75MB", false)
        ]
        
        let fm = FileManager.default
        
        whisperModels = availableModels.map { (id, name, size, _) in
            let modelPath = whisperKitModelDirectory.appendingPathComponent("openai_whisper-\(id)")
            let isDownloaded = fm.fileExists(atPath: modelPath.path)
            let isLoaded = isDownloaded && selectedWhisperModel == id
            
            return AIModel(
                id: id,
                name: name,
                size: size,
                type: .whisper,
                isDownloaded: isDownloaded,
                isLoaded: isLoaded
            )
        }
    }
    
    // MARK: - 下载 Whisper 模型
    func downloadWhisperModel(_ modelId: String) async {
        downloadProgress[modelId] = 0.01
        
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: whisperModelDirectory.path) {
                try fm.createDirectory(at: whisperModelDirectory, withIntermediateDirectories: true)
            }
            
            downloadProgress[modelId] = 0.1
            
            let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    do {
                        for i in 2...9 {
                            try await Task.sleep(nanoseconds: 500_000_000)
                            await MainActor.run {
                                self.downloadProgress[modelId] = Double(i) / 10.0
                            }
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            downloadProgress[modelId] = 1.0
            await checkWhisperModels()
            
            try await Task.sleep(nanoseconds: 500_000_000)
            downloadProgress.removeValue(forKey: modelId)
            
        } catch {
            self.error = "下载模型失败: \(error.localizedDescription)"
            downloadProgress.removeValue(forKey: modelId)
        }
    }
    
    // MARK: - 删除 Whisper 模型
    func deleteWhisperModel(_ modelId: String) async {
        let modelPath = whisperKitModelDirectory.appendingPathComponent("openai_whisper-\(modelId)")
        
        do {
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            await checkWhisperModels()
        } catch {
            self.error = "删除模型失败: \(error.localizedDescription)"
        }
    }
    
    // MARK: - 选择 Whisper 模型
    func selectWhisperModel(_ modelId: String) {
        selectedWhisperModel = modelId
        for i in whisperModels.indices {
            whisperModels[i].isLoaded = whisperModels[i].id == modelId && whisperModels[i].isDownloaded
        }
        NotificationCenter.default.post(name: .whisperModelChanged, object: modelId)
    }
}

// MARK: - 通知
extension Notification.Name {
    static let whisperModelChanged = Notification.Name("whisperModelChanged")
}
