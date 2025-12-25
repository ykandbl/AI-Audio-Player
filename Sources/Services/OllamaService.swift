import Foundation

class OllamaService {
    static let shared = OllamaService()
    
    // LM Studio API
    private let lmStudioURL = "http://127.0.0.1:1234/v1/chat/completions"
    private let lmStudioModel = "qwen/qwen3-8b"
    
    private init() {}
    
    // MARK: - 流式生成总结
    func generateSummaryStreaming(transcript: String, onToken: @escaping (String) -> Void) async throws -> EpisodeSummary {
        let summaryPrompt = await AppSettings.shared.summaryPrompt
        let prompt = summaryPrompt.replacingOccurrences(of: "{{TRANSCRIPT}}", with: String(transcript.prefix(10000)))
        
        let response = try await generateStreaming(prompt: prompt, onToken: onToken)
        return try parseSummaryResponse(response)
    }
    
    // MARK: - 流式生成关系图
    func extractHierarchyRelations(transcript: String, onToken: @escaping (String) -> Void) async throws -> RelationGraphData {
        let relationPrompt = await AppSettings.shared.relationPrompt
        let prompt = relationPrompt.replacingOccurrences(of: "{{TRANSCRIPT}}", with: String(transcript.prefix(8000)))
        
        let response = try await generateStreaming(prompt: prompt, onToken: onToken)
        return try parseHierarchyResponse(response)
    }
    
    // MARK: - 流式生成
    private func generateStreaming(prompt: String, onToken: @escaping (String) -> Void) async throws -> String {
        let url = URL(string: lmStudioURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        
        let messages: [[String: String]] = [
            ["role": "user", "content": prompt]
        ]
        
        let body: [String: Any] = [
            "model": lmStudioModel,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 2000,  // 限制输出长度，防止死循环
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        
        var fullResponse = ""
        
        // 使用 URLSession 的 bytes 方法进行流式读取
        let (bytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }
        
        for try await line in bytes.lines {
            // SSE 格式：data: {...}
            if line.hasPrefix("data: ") {
                let jsonStr = String(line.dropFirst(6))
                if jsonStr == "[DONE]" { break }
                
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    fullResponse += content
                    onToken(content)
                }
            }
        }
        
        // 移除 Qwen3 的 <think></think> 标签
        if let thinkStart = fullResponse.range(of: "<think>") {
            if let thinkEnd = fullResponse.range(of: "</think>") {
                // 移除整个 think 块
                fullResponse = String(fullResponse[..<thinkStart.lowerBound]) + String(fullResponse[thinkEnd.upperBound...])
            }
        }
        fullResponse = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return fullResponse
    }
    
    // MARK: - 解析总结响应
    private func parseSummaryResponse(_ response: String) throws -> EpisodeSummary {
        let jsonString = extractJSON(from: response)
        print("📝 解析总结 JSON...")
        
        guard let data = jsonString.data(using: .utf8) else {
            throw OllamaError.parseError
        }
        
        do {
            let parsed = try JSONDecoder().decode(SummaryJSON.self, from: data)
            return EpisodeSummary(
                trackId: UUID(),
                keyPoints: parsed.keyPoints,
                characters: parsed.characters,
                events: parsed.events,
                fullText: parsed.summary,
                createdAt: Date()
            )
        } catch {
            print("❌ JSON 解析失败: \(error), 尝试手动解析...")
            return try parseManualSummary(jsonString)
        }
    }
    
    private func parseManualSummary(_ json: String) throws -> EpisodeSummary {
        var summary = extractStringValue(from: json, key: "summary") ?? ""
        let keyPoints = extractArray(from: json, key: "keyPoints")
        let characters = extractArray(from: json, key: "characters")
        let events = extractArray(from: json, key: "events")
        
        if summary.isEmpty && keyPoints.isEmpty {
            throw OllamaError.parseError
        }
        
        return EpisodeSummary(
            trackId: UUID(),
            keyPoints: keyPoints,
            characters: characters,
            events: events,
            fullText: summary,
            createdAt: Date()
        )
    }
    
    // MARK: - 解析人物关系响应
    private func parseHierarchyResponse(_ response: String) throws -> RelationGraphData {
        let jsonString = extractJSON(from: response)
        print("📝 解析人物关系 JSON...")
        
        guard let data = jsonString.data(using: .utf8) else {
            throw OllamaError.parseError
        }
        
        do {
            let parsed = try JSONDecoder().decode(SimpleRelationJSON.self, from: data)
            
            // 转换为 CharacterInfo
            let characters = parsed.characters.map { char in
                CharacterInfo(name: char.name, title: char.title, level: 1, role: "other")
            }
            
            return RelationGraphData(
                characters: characters,
                relations: parsed.relations,
                levels: [1: characters]
            )
        } catch {
            print("❌ JSON 解析失败: \(error), 尝试手动解析...")
            return try parseManualHierarchy(jsonString)
        }
    }
    
    private func parseManualHierarchy(_ json: String) throws -> RelationGraphData {
        var characters: [CharacterInfo] = []
        var relations: [CharacterRelation] = []
        
        // 简化的人物提取
        let charPattern = "\"name\"\\s*:\\s*\"([^\"]+)\"[^}]*\"title\"\\s*:\\s*\"([^\"]*)\""
        if let regex = try? NSRegularExpression(pattern: charPattern, options: []) {
            let range = NSRange(json.startIndex..., in: json)
            let matches = regex.matches(in: json, options: [], range: range)
            for match in matches {
                if match.numberOfRanges >= 3,
                   let nameRange = Range(match.range(at: 1), in: json),
                   let titleRange = Range(match.range(at: 2), in: json) {
                    let name = String(json[nameRange])
                    let title = String(json[titleRange])
                    if !characters.contains(where: { $0.name == name }) {
                        characters.append(CharacterInfo(name: name, title: title, level: 1, role: "other"))
                    }
                }
            }
        }
        
        // 提取关系
        let relPattern = "\"from\"\\s*:\\s*\"([^\"]+)\"[^}]*\"to\"\\s*:\\s*\"([^\"]+)\"[^}]*\"relation\"\\s*:\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: relPattern, options: []) {
            let range = NSRange(json.startIndex..., in: json)
            let matches = regex.matches(in: json, options: [], range: range)
            for match in matches {
                if match.numberOfRanges >= 4,
                   let fromRange = Range(match.range(at: 1), in: json),
                   let toRange = Range(match.range(at: 2), in: json),
                   let relationRange = Range(match.range(at: 3), in: json) {
                    let from = String(json[fromRange])
                    let to = String(json[toRange])
                    let relation = String(json[relationRange])
                    relations.append(CharacterRelation(from: from, to: to, relation: relation, type: "other"))
                }
            }
        }
        
        if characters.isEmpty {
            throw OllamaError.parseError
        }
        
        return RelationGraphData(characters: characters, relations: relations, levels: [1: characters])
    }
    
    // MARK: - 辅助方法
    private func extractJSON(from text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }
        return cleaned
    }
    
    private func extractStringValue(from json: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*(?:\\\\.[^\"]*)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: json, options: [], range: NSRange(json.startIndex..., in: json)),
              let valueRange = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return String(json[valueRange]).replacingOccurrences(of: "\\n", with: "\n")
    }
    
    private func extractArray(from json: String, key: String) -> [String] {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return [] }
        let afterKey = json[keyRange.upperBound...]
        
        guard let bracketStart = afterKey.firstIndex(of: "["),
              let bracketEnd = afterKey.firstIndex(of: "]") else { return [] }
        
        let arrayContent = String(afterKey[bracketStart...bracketEnd])
        
        var results: [String] = []
        let pattern = "\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(arrayContent.startIndex..., in: arrayContent)
            let matches = regex.matches(in: arrayContent, options: [], range: range)
            for match in matches {
                if let valueRange = Range(match.range(at: 1), in: arrayContent) {
                    results.append(String(arrayContent[valueRange]))
                }
            }
        }
        return results
    }
}

// MARK: - Models

struct SummaryJSON: Codable {
    let keyPoints: [String]
    let characters: [String]
    let events: [String]
    let summary: String
}

struct HierarchyJSON: Codable {
    let characters: [CharacterInfo]
    let relations: [CharacterRelation]
}

struct SimpleRelationJSON: Codable {
    let characters: [SimpleCharacter]
    let relations: [CharacterRelation]
}

struct SimpleCharacter: Codable {
    let name: String
    let title: String
}

struct CharacterInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let title: String
    let level: Int
    let role: String
}

struct CharacterRelation: Codable, Identifiable {
    var id: String { "\(from)-\(to)-\(relation)" }
    let from: String
    let to: String
    let relation: String
    let type: String
    
    init(from: String, to: String, relation: String, type: String = "political") {
        self.from = from
        self.to = to
        self.relation = relation
        self.type = type
    }
}

struct RelationGraphData {
    let characters: [CharacterInfo]
    let relations: [CharacterRelation]
    let levels: [Int: [CharacterInfo]]  // 按层级分组
}

enum OllamaError: Error, LocalizedError {
    case requestFailed
    case parseError
    case serviceNotRunning
    
    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "AI 服务请求失败，请确保 LM Studio 已启动并在 1234 端口运行"
        case .parseError:
            return "AI 返回格式解析失败，请重试"
        case .serviceNotRunning:
            return "AI 服务未运行，请启动 LM Studio"
        }
    }
}
