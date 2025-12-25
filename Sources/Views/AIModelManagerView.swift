import SwiftUI

struct AIModelManagerView: View {
    @ObservedObject var modelManager = AIModelManager.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI 模型管理")
                    .font(.headline)
                Spacer()
                Button(action: { Task { await modelManager.refreshAll() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(modelManager.isRefreshing)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SystemStatusSection(modelManager: modelManager)
                    LMStudioStatusSection(modelManager: modelManager)
                    WhisperModelsSection(modelManager: modelManager)
                    LMStudioModelsSection(modelManager: modelManager)
                }
                .padding()
            }
            
            Divider()
            
            HStack {
                if let error = modelManager.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()
        }
        .frame(width: 550, height: 550)
    }
}

// MARK: - 系统状态
struct SystemStatusSection: View {
    @ObservedObject var modelManager: AIModelManager
    
    var body: some View {
        GroupBox("系统内存") {
            if let memory = modelManager.memoryInfo {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已使用")
                        Spacer()
                        Text("\(memory.usedFormatted) / \(memory.totalFormatted)")
                            .foregroundColor(.secondary)
                    }
                    
                    ProgressView(value: memory.usedPercentage, total: 100)
                        .tint(memoryColor(percentage: memory.usedPercentage))
                    
                    HStack {
                        Text("可用内存")
                        Spacer()
                        Text(memory.freeFormatted)
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                }
            } else {
                ProgressView("加载中...")
            }
        }
    }
    
    private func memoryColor(percentage: Double) -> Color {
        if percentage > 90 { return .red }
        if percentage > 70 { return .orange }
        return .green
    }
}

// MARK: - LM Studio 状态
struct LMStudioStatusSection: View {
    @ObservedObject var modelManager: AIModelManager
    
    var body: some View {
        GroupBox("LM Studio 服务") {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(modelManager.lmStudioStatus.description)
                
                Spacer()
                
                if case .stopped = modelManager.lmStudioStatus {
                    Text("请打开 LM Studio 并启动 Server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button("刷新") {
                    Task { await modelManager.checkLMStudioStatus() }
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch modelManager.lmStudioStatus {
        case .running: return .green
        case .stopped: return .red
        case .unknown: return .gray
        case .error: return .orange
        }
    }
}

// MARK: - Whisper 模型列表
struct WhisperModelsSection: View {
    @ObservedObject var modelManager: AIModelManager
    
    var body: some View {
        GroupBox("语音转文字模型 (WhisperKit)") {
            VStack(spacing: 0) {
                ForEach(modelManager.whisperModels) { model in
                    WhisperModelRow(model: model, modelManager: modelManager)
                    if model.id != modelManager.whisperModels.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

struct WhisperModelRow: View {
    let model: AIModel
    @ObservedObject var modelManager: AIModelManager
    @State private var showDeleteConfirm = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.name)
                        .font(.system(size: 13, weight: model.isLoaded ? .semibold : .regular))
                    
                    if model.isLoaded {
                        Text("使用中")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                
                Text(model.size)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let progress = modelManager.downloadProgress[model.id] {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if model.isDownloaded {
                HStack(spacing: 8) {
                    if !model.isLoaded {
                        Button("使用") {
                            modelManager.selectWhisperModel(model.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button("下载") {
                    Task { await modelManager.downloadWhisperModel(model.id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                Task { await modelManager.deleteWhisperModel(model.id) }
            }
        } message: {
            Text("确定要删除 \(model.name) 吗？")
        }
    }
}

// MARK: - LM Studio 模型列表
struct LMStudioModelsSection: View {
    @ObservedObject var modelManager: AIModelManager
    
    var body: some View {
        GroupBox("大语言模型 (LM Studio / MLX)") {
            if modelManager.lmStudioModels.isEmpty {
                if case .running = modelManager.lmStudioStatus {
                    Text("没有加载的模型，请在 LM Studio 中加载模型")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("LM Studio 未运行")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(modelManager.lmStudioModels) { model in
                        LMStudioModelRow(model: model)
                        if model.id != modelManager.lmStudioModels.last?.id {
                            Divider()
                        }
                    }
                }
            }
            
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("在 LM Studio 中管理和加载模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
    }
}

struct LMStudioModelRow: View {
    let model: AIModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13))
                
                HStack(spacing: 8) {
                    Text(model.size)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("MLX")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("已加载")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}
