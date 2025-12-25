import Foundation
import WhisperKit
import AVFoundation

@MainActor
class WhisperService: ObservableObject {
    @Published var subtitles: [Subtitle] = []
    @Published var isProcessing = false
    @Published var processingProgress: String = ""
    @Published var fullTranscript = ""
    @Published var error: String?
    @Published var isModelLoaded = false
    @Published var hasPreprocessedSubtitle = false
    @Published var isStreamingMode = false
    @Published var streamingReady = false  // 流式模式准备好可以播放
    
    var currentTranscription: String {
        subtitles.map { $0.text }.joined(separator: "\n")
    }
    
    private var whisperKit: WhisperKit?
    private var currentTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var currentAudioURL: URL?
    private var currentModelId: String = "large-v3"
    
    // 流式处理相关
    private var processedEndTime: TimeInterval = 0  // 已处理到的时间点
    private var pendingPolishText: String = ""      // 待润色的文本缓冲
    private var pendingPolishSubtitles: [Subtitle] = []  // 待润色的字幕
    private let chunkDuration: TimeInterval = 30    // 每个chunk 30秒
    private let overlapDuration: TimeInterval = 3   // 重叠3秒避免边界问题
    private let preloadDuration: TimeInterval = 60  // 预加载60秒
    
    private var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("HistoryPodcastPlayer/WhisperModels")
    }
    
    private var whisperKitModelDirectory: URL {
        modelDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
    }
    
    private var subtitleDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("HistoryPodcastPlayer/Subtitles")
    }
    
    init() {
        NotificationCenter.default.addObserver(forName: .whisperModelChanged, object: nil, queue: .main) { [weak self] notification in
            if let modelId = notification.object as? String {
                Task { @MainActor in self?.switchModel(to: modelId) }
            }
        }
        Task { await loadModel() }
    }

    
    private func subtitlePath(for audioURL: URL) -> URL {
        let fileName = audioURL.deletingPathExtension().lastPathComponent
        // 使用稳定的 hash（基于文件名，跨会话一致）
        let hash = stableHash(audioURL.lastPathComponent)
        return subtitleDirectory.appendingPathComponent("\(fileName)_\(abs(hash)).srt")
    }
    
    /// 稳定的 hash 函数（跨会话一致，不使用 Swift 的 hashValue）
    private func stableHash(_ string: String) -> Int {
        var hash = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(char)
        }
        return hash
    }
    
    func hasSubtitle(for audioURL: URL) -> Bool {
        // 先检查新格式（稳定 hash）
        if FileManager.default.fileExists(atPath: subtitlePath(for: audioURL).path) {
            return true
        }
        // 兼容旧格式（不稳定 hash）- 尝试查找匹配的文件
        return findLegacySubtitle(for: audioURL) != nil
    }
    
    /// 查找旧格式的字幕文件（兼容之前使用不稳定 hash 保存的文件）
    private func findLegacySubtitle(for audioURL: URL) -> URL? {
        let fileName = audioURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        
        // 确保目录存在
        if !fm.fileExists(atPath: subtitleDirectory.path) {
            return nil
        }
        
        guard let contents = try? fm.contentsOfDirectory(at: subtitleDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        
        // 查找以文件名开头的 .srt 文件，优先返回最新的
        var matchingFiles: [URL] = []
        for file in contents {
            if file.pathExtension == "srt" && file.lastPathComponent.hasPrefix(fileName + "_") {
                matchingFiles.append(file)
            }
        }
        
        // 如果有多个匹配，返回最新修改的那个
        if matchingFiles.count > 1 {
            let sorted = matchingFiles.sorted { url1, url2 in
                let date1 = (try? fm.attributesOfItem(atPath: url1.path)[.modificationDate] as? Date) ?? Date.distantPast
                let date2 = (try? fm.attributesOfItem(atPath: url2.path)[.modificationDate] as? Date) ?? Date.distantPast
                return date1 > date2
            }
            return sorted.first
        }
        
        return matchingFiles.first
    }
    
    func loadSavedSubtitle(for audioURL: URL) -> Bool {
        // 先尝试新格式
        var path = subtitlePath(for: audioURL)
        print("🔍 尝试加载字幕: \(path.lastPathComponent)")
        
        if !FileManager.default.fileExists(atPath: path.path) {
            print("🔍 新格式不存在，尝试旧格式...")
            // 尝试旧格式
            if let legacyPath = findLegacySubtitle(for: audioURL) {
                print("🔍 找到旧格式字幕: \(legacyPath.lastPathComponent)")
                path = legacyPath
            } else {
                print("🔍 没有找到任何字幕文件")
                return false
            }
        }
        
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            print("❌ 无法读取字幕文件内容")
            return false
        }
        subtitles = parseSRT(content)
        fullTranscript = subtitles.map { $0.text }.joined(separator: " ")
        hasPreprocessedSubtitle = true
        print("✅ 成功加载字幕，共 \(subtitles.count) 条")
        return true
    }
    
    func startTranscription(audioURL: URL) {
        currentAudioURL = audioURL
        subtitles = []
        fullTranscript = ""
        hasPreprocessedSubtitle = false
        
        if loadSavedSubtitle(for: audioURL) {
            processingProgress = "已加载保存的字幕"
            return
        }
        startFullTranscription(audioURL: audioURL)
    }
    
    func startFullTranscription(audioURL: URL, forceTranscribe: Bool = false) {
        currentTask?.cancel()
        currentTask = Task {
            // 确保无论如何都会重置 isProcessing
            defer {
                Task { @MainActor in
                    self.isProcessing = false
                }
            }
            
            if !isModelLoaded || whisperKit == nil { await loadModel() }
            guard let whisper = whisperKit else { error = "模型未加载"; return }
            
            isProcessing = true
            error = nil
            subtitles = []
            fullTranscript = ""
            hasPreprocessedSubtitle = false
            
            do {
                let asset = AVURLAsset(url: audioURL)
                let duration = try await asset.load(.duration)
                let totalDuration = CMTimeGetSeconds(duration)
                processingProgress = "转写中（\(formatTime(totalDuration))）..."
                print("🎤 开始 Whisper 转写，音频时长: \(formatTime(totalDuration))")
                
                let options = DecodingOptions(task: .transcribe, language: "zh", usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true)
                
                // 添加超时保护
                let transcribeTask = Task {
                    try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
                }
                
                let results: [TranscriptionResult]
                do {
                    results = try await transcribeTask.value
                    print("🎤 Whisper 转写完成，获得 \(results.count) 个结果")
                } catch {
                    print("❌ Whisper 转写出错: \(error)")
                    throw error
                }
                
                guard !Task.isCancelled else { return }
                
                var rawSubtitles: [Subtitle] = []
                var rawText = ""
                for result in results {
                    for segment in result.segments {
                        var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            text = convertToSimplified(text)
                            rawSubtitles.append(Subtitle(text: text, startTime: TimeInterval(segment.start), endTime: TimeInterval(segment.end)))
                            rawText += text
                        }
                    }
                }
                
                guard !Task.isCancelled else { return }
                
                print("📝 转写完成，原始文本长度: \(rawText.count) 字符")
                processingProgress = "AI 润色中..."
                let polishedText = await polishWithOllama(rawText)
                print("✅ 润色完成，结果长度: \(polishedText?.count ?? 0) 字符")
                
                guard !Task.isCancelled else { return }
                
                subtitles = redistributeTimestamps(polishedText: polishedText ?? rawText, originalSubtitles: rawSubtitles)
                fullTranscript = subtitles.map { $0.text }.joined(separator: " ")
                
                await saveSubtitle(for: audioURL)
                processingProgress = "转写完成并已保存"
                hasPreprocessedSubtitle = true
            } catch {
                if !Task.isCancelled { self.error = "转写失败: \(error.localizedDescription)" }
            }
        }
    }

    
    private func polishWithOllama(_ text: String) async -> String? {
        // 如果文本太长，分段处理（每段约1500字符，处理更快）
        let maxChars = 1500
        if text.count > maxChars {
            return await polishLongText(text, maxChars: maxChars)
        }
        
        return await polishSegment(text)
    }
    
    private func polishLongText(_ text: String, maxChars: Int) async -> String? {
        // 按字符数分割
        var segments: [String] = []
        var current = ""
        
        for char in text {
            current.append(char)
            if current.count >= maxChars {
                segments.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        
        print("📝 文本分为 \(segments.count) 段进行润色")
        
        var results: [String] = []
        for (i, segment) in segments.enumerated() {
            processingProgress = "AI 润色中 (\(i+1)/\(segments.count))..."
            print("🔄 润色第 \(i+1)/\(segments.count) 段...")
            if let polished = await polishSegment(segment) {
                results.append(polished)
                print("✅ 第 \(i+1) 段润色完成")
            } else {
                results.append(segment) // 失败时保留原文
                print("⚠️ 第 \(i+1) 段润色失败，保留原文")
            }
        }
        
        return results.joined(separator: "\n")
    }
    
    private func polishSegment(_ text: String) async -> String? {
        // 优先使用 LM Studio (MLX)，如果失败则回退到 Ollama
        if let result = await polishWithLMStudio(text) {
            return result
        }
        return await polishWithOllamaAPI(text)
    }
    
    private func polishWithLMStudio(_ text: String) async -> String? {
        print("🔄 开始 LM Studio 润色，输入长度: \(text.count)")
        
        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180 // 3分钟超时
        
        // 使用用户配置的润色提示词
        let polishTemplate = await AppSettings.shared.polishPrompt
        let prompt = polishTemplate.replacingOccurrences(of: "{{TRANSCRIPT}}", with: text)
        
        let messages: [[String: String]] = [
            ["role": "user", "content": prompt]
        ]
        
        let body: [String: Any] = [
            "model": "qwen/qwen3-8b",
            "messages": messages,
            "temperature": 0.1,
            "max_tokens": 8000
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 180
            config.timeoutIntervalForResource = 180
            let session = URLSession(configuration: config)
            
            print("📤 发送请求到 LM Studio...")
            let (data, response) = try await session.data(for: request)
            print("📥 收到 LM Studio 响应")
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ LM Studio: 无效响应")
                return nil
            }
            
            if httpResponse.statusCode != 200 {
                print("❌ LM Studio: HTTP \(httpResponse.statusCode)")
                if let errorStr = String(data: data, encoding: .utf8) {
                    print("   错误详情: \(errorStr.prefix(500))")
                }
                return nil
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any] {
                
                var result: String? = nil
                
                if let content = message["content"] as? String, !content.isEmpty {
                    result = content
                } else if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
                    result = reasoning
                }
                
                if var text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    // 移除 Qwen3 的 <think></think> 标签
                    if let thinkEnd = text.range(of: "</think>") {
                        text = String(text[thinkEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if !text.isEmpty {
                        print("✅ LM Studio 润色成功，返回 \(text.count) 字符")
                        return text
                    }
                }
                print("⚠️ LM Studio 返回空内容")
            }
        } catch {
            print("❌ LM Studio润色失败: \(error.localizedDescription)")
        }
        return nil
    }
    
    private func polishWithOllamaAPI(_ text: String) async -> String? {
        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        let prompt = """
        请校对以下语音转写文本，添加标点符号，修正错别字，每句话一行，直接输出不要解释：
        \(text)
        """
        
        let body: [String: Any] = [
            "model": "qwen2:7b",
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 2000, "num_ctx": 4096]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("Ollama润色失败: \(error)")
        }
        return nil
    }
    
    private func redistributeTimestamps(polishedText: String, originalSubtitles: [Subtitle]) -> [Subtitle] {
        guard !originalSubtitles.isEmpty else { return [] }
        
        // 先按换行分割，然后再按句号等标点分割
        var lines: [String] = []
        let rawLines = polishedText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        for line in rawLines {
            // 按句号、问号、感叹号分割每一行
            let sentences = splitBySentence(line)
            lines.append(contentsOf: sentences)
        }
        
        guard !lines.isEmpty else { return originalSubtitles }
        
        let totalDuration = originalSubtitles.last!.endTime - originalSubtitles.first!.startTime
        let startTime = originalSubtitles.first!.startTime
        let totalChars = lines.reduce(0) { $0 + $1.count }
        var currentTime = startTime
        var result: [Subtitle] = []
        
        for line in lines {
            let lineDuration = totalDuration * Double(line.count) / Double(totalChars)
            result.append(Subtitle(text: line, startTime: currentTime, endTime: currentTime + lineDuration, isPolished: true))
            currentTime += lineDuration
        }
        return result
    }
    
    /// 按句子分割文本（句号、问号、感叹号）
    private func splitBySentence(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        
        for char in text {
            current.append(char)
            // 遇到句末标点就分割
            if char == "。" || char == "？" || char == "！" || char == "?" || char == "!" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        
        // 处理最后一段（可能没有句末标点）
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            sentences.append(trimmed)
        }
        
        return sentences
    }
    
    private func saveSubtitle(for audioURL: URL) async {
        let path = subtitlePath(for: audioURL)
        do {
            try FileManager.default.createDirectory(at: subtitleDirectory, withIntermediateDirectories: true)
            try generateSRT(subtitles).write(to: path, atomically: true, encoding: .utf8)
        } catch { print("保存字幕失败: \(error)") }
    }
    
    private func generateSRT(_ subtitles: [Subtitle]) -> String {
        var srt = ""
        for (i, sub) in subtitles.enumerated() {
            srt += "\(i+1)\n\(formatSRTTime(sub.startTime)) --> \(formatSRTTime(sub.endTime))\n\(sub.text)\n\n"
        }
        return srt
    }
    
    private func formatSRTTime(_ s: TimeInterval) -> String {
        String(format: "%02d:%02d:%02d,%03d", Int(s)/3600, (Int(s)%3600)/60, Int(s)%60, Int((s.truncatingRemainder(dividingBy: 1))*1000))
    }
    
    private func parseSRT(_ content: String) -> [Subtitle] {
        var subs: [Subtitle] = []
        for block in content.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }
            let times = lines[1].components(separatedBy: " --> ")
            guard times.count == 2 else { continue }
            subs.append(Subtitle(text: lines[2...].joined(separator: "\n"), startTime: parseSRTTime(times[0]), endTime: parseSRTTime(times[1]), isPolished: true))
        }
        return subs
    }
    
    private func parseSRTTime(_ t: String) -> TimeInterval {
        let p = t.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard p.count == 3 else { return 0 }
        return (Double(p[0]) ?? 0) * 3600 + (Double(p[1]) ?? 0) * 60 + (Double(p[2]) ?? 0)
    }

    
    func deleteSubtitle(for audioURL: URL) {
        let fm = FileManager.default
        let fileName = audioURL.deletingPathExtension().lastPathComponent
        
        // 删除新格式文件
        let newPath = subtitlePath(for: audioURL)
        try? fm.removeItem(at: newPath)
        
        // 删除所有旧格式文件（可能有多个）
        if let contents = try? fm.contentsOfDirectory(at: subtitleDirectory, includingPropertiesForKeys: nil) {
            for file in contents {
                if file.pathExtension == "srt" && file.lastPathComponent.hasPrefix(fileName + "_") {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
    
    func switchModel(to modelId: String) {
        guard modelId != currentModelId else { return }
        currentModelId = modelId
        whisperKit = nil
        isModelLoaded = false
        Task { await loadModel() }
    }
    
    func loadModel() async {
        guard whisperKit == nil else { isModelLoaded = true; return }
        let selectedModel = AIModelManager.shared.selectedWhisperModel
        currentModelId = selectedModel
        processingProgress = "加载模型..."
        
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: modelDirectory.path) {
                try fm.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            }
            
            let modelPath = whisperKitModelDirectory.appendingPathComponent("openai_whisper-\(selectedModel)")
            
            if fm.fileExists(atPath: modelPath.path) {
                print("📦 从本地加载模型: \(modelPath.lastPathComponent)")
                whisperKit = try await WhisperKit(modelFolder: modelPath.path, verbose: false)
            } else {
                processingProgress = "下载模型 \(selectedModel)..."
                print("⬇️ 下载模型: \(selectedModel)")
                whisperKit = try await WhisperKit(model: selectedModel, downloadBase: modelDirectory, verbose: true)
            }
            isModelLoaded = true
            processingProgress = ""
            print("✅ 模型加载完成: \(selectedModel)")
            await AIModelManager.shared.checkWhisperModels()
        } catch {
            self.error = "模型加载失败: \(error.localizedDescription)"
            processingProgress = ""
            isModelLoaded = false
        }
    }
    
    func stopTranscription() { currentTask?.cancel(); currentTask = nil; streamingTask?.cancel(); streamingTask = nil; isProcessing = false; isStreamingMode = false; streamingReady = false; processingProgress = "" }
    func transcribe(audioURL: URL) async { startTranscription(audioURL: audioURL) }
    func seekAndTranscribe(to time: TimeInterval) { }
    
    // MARK: - 流式转写模式
    
    // 缓存完整的原始转写结果
    private var cachedRawSubtitles: [Subtitle] = []
    private var transcriptionComplete = false
    
    /// 检查字幕是否完整（是否已处理到音频末尾）
    private func isSubtitleComplete(for audioURL: URL, subtitles: [Subtitle]) async -> Bool {
        guard let lastSub = subtitles.last else { return false }
        
        let asset = AVURLAsset(url: audioURL)
        guard let duration = try? await asset.load(.duration) else { return false }
        let totalDuration = CMTimeGetSeconds(duration)
        
        let isComplete = lastSub.endTime >= totalDuration - 5
        print("📊 字幕完整性检查: 最后字幕结束时间=\(formatTime(lastSub.endTime)), 音频总时长=\(formatTime(totalDuration)), 完整=\(isComplete)")
        
        // 如果最后一条字幕的结束时间接近音频总时长（差距小于5秒），认为已完成
        return isComplete
    }
    
    /// 开始流式转写 - 支持断点续传
    func startStreamingTranscription(audioURL: URL, onReady: @escaping () -> Void) {
        currentAudioURL = audioURL
        subtitles = []
        fullTranscript = ""
        hasPreprocessedSubtitle = false
        isStreamingMode = true
        streamingReady = false
        processedEndTime = 0
        cachedRawSubtitles = []
        transcriptionComplete = false
        
        streamingTask = Task {
            defer {
                Task { @MainActor in
                    self.isProcessing = false
                }
            }
            
            // 检查是否有已保存的字幕（可能是上次中断的）
            var resumeFromTime: TimeInterval = 0
            print("🔍 检查字幕文件: \(audioURL.lastPathComponent)")
            if loadSavedSubtitle(for: audioURL) {
                print("📂 找到已保存的字幕，共 \(subtitles.count) 条")
                // 检查字幕是否完整
                if await isSubtitleComplete(for: audioURL, subtitles: subtitles) {
                    // 字幕完整，直接使用
                    print("✅ 字幕已完整，直接使用")
                    processingProgress = "已加载保存的字幕"
                    streamingReady = true
                    hasPreprocessedSubtitle = true
                    onReady()
                    return
                } else {
                    // 字幕不完整，从上次中断的地方继续
                    if let lastSub = subtitles.last {
                        // 往前推10秒，防止漏掉句子
                        resumeFromTime = max(0, lastSub.endTime - 10)
                        processedEndTime = lastSub.endTime
                        print("📂 检测到未完成的字幕，从 \(formatTime(resumeFromTime)) 继续处理")
                    }
                    // 已有字幕，可以先开始播放
                    streamingReady = true
                    onReady()
                }
            } else {
                print("📂 没有找到已保存的字幕，从头开始")
            }
            
            if !isModelLoaded || whisperKit == nil { await loadModel() }
            guard let whisper = whisperKit else { 
                error = "模型未加载"
                return 
            }
            
            isProcessing = true
            error = nil
            
            // 获取音频总时长
            let asset = AVURLAsset(url: audioURL)
            guard let duration = try? await asset.load(.duration) else {
                error = "无法读取音频"
                return
            }
            let totalDuration = CMTimeGetSeconds(duration)
            print("🎬 开始流式转写，总时长: \(formatTime(totalDuration))")
            
            // 渐进式 chunk：25秒 → 30秒 → 35秒 → 40秒（最大）
            // 每段之间有 5 秒重叠，防止边界丢失文字
            let chunkSizes: [TimeInterval] = [25, 30, 35, 40]
            let overlapDuration: TimeInterval = 5  // 重叠时间
            var chunkIndex = 0
            var currentStart: TimeInterval = resumeFromTime
            var isFirstChunk = (resumeFromTime == 0)
            var lastChunkEndTime: TimeInterval = resumeFromTime  // 上一段的实际结束时间（不含重叠）
            
            // 循环处理每个片段
            while currentStart < totalDuration && !Task.isCancelled && isStreamingMode {
                // 获取当前 chunk 大小（渐进增加）
                let currentChunkSize = chunkSizes[min(chunkIndex, chunkSizes.count - 1)]
                // 实际提取的结束时间（包含重叠）
                let extractEnd = min(currentStart + currentChunkSize, totalDuration)
                // 这一段的有效结束时间（不含重叠，用于下一段的起始）
                let effectiveEnd = min(currentStart + currentChunkSize - overlapDuration, totalDuration)
                
                if isFirstChunk {
                    processingProgress = "转写前\(Int(currentChunkSize))秒..."
                } else {
                    processingProgress = "转写 \(formatTime(currentStart))-\(formatTime(extractEnd))..."
                }
                
                print("🔄 转写 \(formatTime(currentStart)) - \(formatTime(extractEnd)) (chunk \(Int(currentChunkSize))秒, 有效到 \(formatTime(effectiveEnd)))")
                
                // 提取并转写这一段（包含重叠部分）
                guard let chunkSubs = await transcribeAudioChunk(
                    audioURL: audioURL,
                    start: currentStart,
                    end: extractEnd,
                    whisper: whisper
                ) else {
                    if isFirstChunk {
                        error = "转写失败"
                        return
                    }
                    currentStart = effectiveEnd
                    chunkIndex += 1
                    continue
                }
                
                guard !Task.isCancelled else { return }
                
                // 润色这一段
                if isFirstChunk {
                    processingProgress = "润色字幕中..."
                }
                
                let rawText = chunkSubs.map { $0.text }.joined()
                var polishedSubs = chunkSubs
                
                if let polishedText = await polishSegment(rawText), !chunkSubs.isEmpty {
                    polishedSubs = redistributeTimestamps(polishedText: polishedText, originalSubtitles: chunkSubs)
                }
                
                // 智能合并字幕（处理重叠部分）
                if subtitles.isEmpty {
                    subtitles = polishedSubs
                } else {
                    // 找到重叠区域的边界
                    let overlapBoundary = lastChunkEndTime
                    
                    // 从新字幕中只取重叠边界之后的部分
                    // 但要保留一些重叠以确保不丢失边界处的文字
                    let newSubs = polishedSubs.filter { sub in
                        // 如果字幕的中点在边界之后，就保留
                        let midPoint = (sub.startTime + sub.endTime) / 2
                        return midPoint > overlapBoundary - 1  // 允许1秒的容差
                    }
                    
                    // 移除旧字幕中与新字幕重叠的部分
                    if let firstNewSub = newSubs.first {
                        subtitles.removeAll { $0.startTime >= firstNewSub.startTime - 0.5 }
                    }
                    
                    subtitles.append(contentsOf: newSubs)
                    
                    // 按时间排序并去重
                    subtitles.sort { $0.startTime < $1.startTime }
                    subtitles = deduplicateSubtitles(subtitles)
                }
                
                cachedRawSubtitles.append(contentsOf: chunkSubs)
                lastChunkEndTime = effectiveEnd
                processedEndTime = extractEnd
                
                // 每处理完一段就保存，防止中途关闭丢失
                await saveSubtitle(for: audioURL)
                
                print("✅ 已处理到 \(formatTime(extractEnd))，共 \(subtitles.count) 条字幕")
                
                // 第一段处理完后，通知可以开始播放
                if isFirstChunk {
                    streamingReady = true
                    processingProgress = ""
                    print("✅ 前\(Int(currentChunkSize))秒准备完成，开始播放")
                    onReady()
                    isFirstChunk = false
                }
                
                // 下一段从有效结束时间开始（这样会有重叠）
                currentStart = effectiveEnd
                chunkIndex += 1
            }
            
            // 全部处理完成
            if !Task.isCancelled {
                transcriptionComplete = true
                await saveSubtitle(for: audioURL)
                hasPreprocessedSubtitle = true
                fullTranscript = subtitles.map { $0.text }.joined(separator: " ")
                processingProgress = ""
                print("✅ 流式转写完成，共 \(subtitles.count) 条字幕")
            }
        }
    }
    
    /// 转写指定时间段的音频（使用 AVAssetReader 提取音频数据）
    private func transcribeAudioChunk(audioURL: URL, start: TimeInterval, end: TimeInterval, whisper: WhisperKit) async -> [Subtitle]? {
        do {
            // 创建临时 WAV 文件
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk_\(UUID().uuidString).wav")
            
            // 提取音频片段到 WAV 文件
            let success = await extractAudioToWAV(from: audioURL, to: tempURL, start: start, end: end)
            guard success else {
                print("❌ 提取音频片段失败")
                return nil
            }
            
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            let options = DecodingOptions(
                task: .transcribe,
                language: "zh",
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: true
            )
            
            let results = try await whisper.transcribe(audioPath: tempURL.path, decodeOptions: options)
            
            var subtitles: [Subtitle] = []
            for result in results {
                for segment in result.segments {
                    var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        text = convertToSimplified(text)
                        // 调整时间戳：加上起始偏移
                        subtitles.append(Subtitle(
                            text: text,
                            startTime: TimeInterval(segment.start) + start,
                            endTime: TimeInterval(segment.end) + start,
                            isPolished: false
                        ))
                    }
                }
            }
            return subtitles
        } catch {
            print("❌ 转写chunk失败: \(error)")
            return nil
        }
    }
    
    /// 使用 AVAssetReader 提取音频片段到 WAV 文件
    private func extractAudioToWAV(from sourceURL: URL, to destURL: URL, start: TimeInterval, end: TimeInterval) async -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        
        do {
            // 加载音频轨道
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                print("❌ 没有找到音频轨道")
                return false
            }
            
            // 创建 reader
            let reader = try AVAssetReader(asset: asset)
            
            // 设置时间范围
            let startTime = CMTime(seconds: start, preferredTimescale: 44100)
            let endTime = CMTime(seconds: end, preferredTimescale: 44100)
            reader.timeRange = CMTimeRange(start: startTime, end: endTime)
            
            // 输出设置：16kHz 单声道 PCM（WhisperKit 需要的格式）
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            reader.add(readerOutput)
            
            guard reader.startReading() else {
                print("❌ 无法开始读取: \(reader.error?.localizedDescription ?? "未知错误")")
                return false
            }
            
            // 收集所有音频数据
            var audioData = Data()
            while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    var length = 0
                    var dataPointer: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
                    if let dataPointer = dataPointer {
                        audioData.append(UnsafeBufferPointer(start: dataPointer, count: length))
                    }
                }
            }
            
            guard reader.status == .completed else {
                print("❌ 读取未完成: \(reader.error?.localizedDescription ?? "未知错误")")
                return false
            }
            
            // 写入 WAV 文件
            let wavData = createWAVFile(from: audioData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
            try wavData.write(to: destURL)
            
            return true
        } catch {
            print("❌ 提取音频失败: \(error)")
            return false
        }
    }
    
    /// 创建 WAV 文件数据
    private func createWAVFile(from pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var wavData = Data()
        
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize
        
        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
        wavData.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM format
        wavData.append(withUnsafeBytes(of: UInt16(channels).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Data($0) })
        
        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })
        wavData.append(pcmData)
        
        return wavData
    }
    
    /// 停止流式转写
    func stopStreamingTranscription() {
        isStreamingMode = false
        streamingTask?.cancel()
        streamingTask = nil
    }
    
    /// 初始化转写：只转写前 N 秒并保存，用于批量预处理
    func initializeTranscription(audioURL: URL, duration: TimeInterval = 60) async throws -> Bool {
        // 如果已有字幕，跳过
        if hasSubtitle(for: audioURL) {
            print("⏭️ 已有字幕，跳过: \(audioURL.lastPathComponent)")
            return true
        }
        
        // 确保模型已加载
        if !isModelLoaded || whisperKit == nil {
            await loadModel()
        }
        
        guard let whisper = whisperKit else {
            throw NSError(domain: "WhisperService", code: -1, userInfo: [NSLocalizedDescriptionKey: "模型未加载"])
        }
        
        print("🚀 初始化转写: \(audioURL.lastPathComponent) (前\(Int(duration))秒)")
        
        // 获取音频实际时长
        let asset = AVURLAsset(url: audioURL)
        let assetDuration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(assetDuration)
        let actualDuration = min(duration, totalDuration)
        
        // 转写前 N 秒
        guard let rawSubs = await transcribeAudioChunk(
            audioURL: audioURL,
            start: 0,
            end: actualDuration,
            whisper: whisper
        ) else {
            throw NSError(domain: "WhisperService", code: -2, userInfo: [NSLocalizedDescriptionKey: "转写失败"])
        }
        
        // 润色
        let rawText = rawSubs.map { $0.text }.joined()
        var polishedSubs = rawSubs
        
        if let polishedText = await polishSegment(rawText), !rawSubs.isEmpty {
            polishedSubs = redistributeTimestamps(polishedText: polishedText, originalSubtitles: rawSubs)
        }
        
        // 临时保存到 subtitles 以便 saveSubtitle 使用
        let originalSubs = subtitles
        subtitles = polishedSubs
        await saveSubtitle(for: audioURL)
        subtitles = originalSubs  // 恢复原来的字幕
        
        print("✅ 初始化完成: \(audioURL.lastPathComponent), 共 \(polishedSubs.count) 条字幕")
        return true
    }
    
    private func formatTime(_ s: Double) -> String { String(format: "%d:%02d", Int(s)/60, Int(s)%60) }
    private func convertToSimplified(_ text: String) -> String {
        let m = NSMutableString(string: text)
        CFStringTransform(m, nil, "Traditional-Simplified" as CFString, false)
        return m as String
    }
    
    /// 去除重复的字幕（基于文本相似度和时间重叠）
    private func deduplicateSubtitles(_ subs: [Subtitle]) -> [Subtitle] {
        guard subs.count > 1 else { return subs }
        
        var result: [Subtitle] = []
        for sub in subs {
            // 检查是否与已有字幕重复
            let isDuplicate = result.contains { existing in
                // 时间重叠检查
                let timeOverlap = existing.startTime < sub.endTime && sub.startTime < existing.endTime
                if !timeOverlap { return false }
                
                // 文本相似度检查（如果文本相似度超过70%，认为是重复）
                let similarity = textSimilarity(existing.text, sub.text)
                return similarity > 0.7
            }
            
            if !isDuplicate {
                result.append(sub)
            }
        }
        return result
    }
    
    /// 计算两个字符串的相似度（0-1）
    private func textSimilarity(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        
        // 简单的字符重叠率计算
        let set1 = Set(s1)
        let set2 = Set(s2)
        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count
        
        return Double(intersection) / Double(union)
    }
}
