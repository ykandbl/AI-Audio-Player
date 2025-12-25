import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // 标签栏
            HStack(spacing: 0) {
                TabButton(title: "主题", icon: "paintbrush", isSelected: selectedTab == 0) { selectedTab = 0 }
                TabButton(title: "桌面歌词", icon: "text.bubble", isSelected: selectedTab == 1) { selectedTab = 1 }
                TabButton(title: "AI 模型", icon: "cpu", isSelected: selectedTab == 2) { selectedTab = 2 }
                TabButton(title: "AI 提示词", icon: "text.quote", isSelected: selectedTab == 3) { selectedTab = 3 }
            }
            .padding(.horizontal)
            .padding(.top)
            
            Divider().padding(.top, 8)
            
            // 内容区
            ScrollView {
                switch selectedTab {
                case 0: ThemeSettingsView(settings: settings)
                case 1: DesktopLyricsSettingsView(settings: settings)
                case 2: AIModelSettingsView(settings: settings)
                case 3: PromptSettingsView(settings: settings)
                default: EmptyView()
                }
            }
            .padding()
            
            Divider()
            
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 600, height: 550)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 主题设置
struct ThemeSettingsView: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("外观模式") {
                Picker("", selection: $settings.theme.colorScheme) {
                    ForEach(ThemeSettings.AppColorScheme.allCases, id: \.self) { scheme in
                        Text(scheme.rawValue).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - 桌面歌词设置
struct DesktopLyricsSettingsView: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("启用桌面歌词", isOn: $settings.desktopLyrics.enabled)
                .toggleStyle(.switch)
            
            GroupBox("显示设置") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("字体大小")
                        Slider(value: $settings.desktopLyrics.fontSize, in: 14...48, step: 2)
                        Text("\(Int(settings.desktopLyrics.fontSize))pt")
                            .frame(width: 45)
                    }
                    
                    HStack {
                        Text("显示行数")
                        Stepper("\(settings.desktopLyrics.lineCount) 行", 
                               value: $settings.desktopLyrics.lineCount, in: 1...5)
                    }
                    
                    ColorPicker("字体颜色", selection: Binding(
                        get: { settings.desktopLyrics.fontColor.color },
                        set: { settings.desktopLyrics.fontColor = CodableColor($0) }
                    ))
                    
                    ColorPicker("背景颜色", selection: Binding(
                        get: { settings.desktopLyrics.backgroundColor.color },
                        set: { settings.desktopLyrics.backgroundColor = CodableColor($0) }
                    ))
                }
            }
            
            GroupBox("窗口大小") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("宽度")
                        Slider(value: $settings.desktopLyrics.windowWidth, in: 300...1200, step: 50)
                        Text("\(Int(settings.desktopLyrics.windowWidth))")
                            .frame(width: 50)
                    }
                    HStack {
                        Text("高度")
                        Slider(value: $settings.desktopLyrics.windowHeight, in: 50...300, step: 10)
                        Text("\(Int(settings.desktopLyrics.windowHeight))")
                            .frame(width: 50)
                    }
                }
            }
            
            Text("提示：桌面歌词窗口可以直接拖动调整位置")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - AI 模型设置
struct AIModelSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var modelManager = AIModelManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("语音转文字模型") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("当前模型", selection: Binding(
                        get: { modelManager.selectedWhisperModel },
                        set: { modelManager.selectWhisperModel($0) }
                    )) {
                        ForEach(modelManager.whisperModels.filter { $0.isDownloaded }) { model in
                            Text("\(model.name) (\(model.size))").tag(model.id)
                        }
                    }
                    
                    Text("在 AI 模型管理器中下载更多模型")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            GroupBox("大语言模型 (LM Studio)") {
                VStack(alignment: .leading, spacing: 8) {
                    if modelManager.lmStudioModels.isEmpty {
                        Text("请启动 LM Studio 并加载模型")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(modelManager.lmStudioModels) { model in
                            HStack {
                                Text(model.name)
                                Spacer()
                                Text("已加载")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            
            Toggle("自动加载模型", isOn: $settings.aiModel.autoLoadModels)
            
            Button("打开 AI 模型管理器") {
                NSApp.sendAction(#selector(AppDelegate.showAIModelManager), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}


// MARK: - AI 提示词设置
struct PromptSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var editingTemplate: PromptTemplate?
    @State private var showingEditor = false
    @State private var isCreatingNew = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 当前使用的模板
            GroupBox("当前提示词模板") {
                HStack {
                    Picker("", selection: $settings.currentPromptId) {
                        ForEach(settings.promptTemplates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                    .labelsHidden()
                    
                    Spacer()
                    
                    Button("编辑") {
                        editingTemplate = settings.currentPrompt
                        isCreatingNew = false
                        showingEditor = true
                    }
                }
            }
            
            // 模板列表
            GroupBox("所有模板") {
                VStack(spacing: 0) {
                    ForEach(settings.promptTemplates) { template in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(template.name)
                                        .fontWeight(.medium)
                                    if template.id == settings.currentPromptId {
                                        Text("当前")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.2))
                                            .cornerRadius(4)
                                    }
                                }
                                Text(template.id == "history" || template.id == "general" ? "内置模板" : "自定义")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("使用") {
                                settings.currentPromptId = template.id
                            }
                            .disabled(template.id == settings.currentPromptId)
                            
                            Button("编辑") {
                                editingTemplate = template
                                isCreatingNew = false
                                showingEditor = true
                            }
                            
                            if template.id != "history" && template.id != "general" {
                                Button(role: .destructive) {
                                    settings.deletePromptTemplate(id: template.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        
                        if template.id != settings.promptTemplates.last?.id {
                            Divider()
                        }
                    }
                }
            }
            
            Button("新建模板") {
                editingTemplate = PromptTemplate(
                    id: UUID().uuidString,
                    name: "新模板",
                    summaryPrompt: PromptTemplate.defaultGeneral.summaryPrompt,
                    relationPrompt: PromptTemplate.defaultGeneral.relationPrompt,
                    polishPrompt: PromptTemplate.defaultGeneral.polishPrompt
                )
                isCreatingNew = true
                showingEditor = true
            }
            
            Text("提示：使用 {{TRANSCRIPT}} 作为文字稿的占位符")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .sheet(isPresented: $showingEditor) {
            if let template = editingTemplate {
                PromptEditorView(
                    template: template,
                    isNew: isCreatingNew,
                    onSave: { updated in
                        if isCreatingNew {
                            settings.addPromptTemplate(updated)
                        } else {
                            settings.updatePromptTemplate(updated)
                        }
                        showingEditor = false
                    },
                    onCancel: {
                        showingEditor = false
                    }
                )
            }
        }
    }
}

// MARK: - 提示词编辑器
struct PromptEditorView: View {
    @State var template: PromptTemplate
    let isNew: Bool
    let onSave: (PromptTemplate) -> Void
    let onCancel: () -> Void
    
    @State private var selectedPromptType = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text(isNew ? "新建提示词模板" : "编辑提示词模板")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 模板名称
            HStack {
                Text("模板名称")
                    .frame(width: 80, alignment: .leading)
                TextField("名称", text: $template.name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
            
            // 提示词类型选择
            Picker("", selection: $selectedPromptType) {
                Text("总结提示词").tag(0)
                Text("关系图提示词").tag(1)
                Text("润色提示词").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            // 提示词编辑区
            Group {
                switch selectedPromptType {
                case 0:
                    TextEditor(text: $template.summaryPrompt)
                case 1:
                    TextEditor(text: $template.relationPrompt)
                case 2:
                    TextEditor(text: $template.polishPrompt)
                default:
                    EmptyView()
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding()
            
            Divider()
            
            // 按钮
            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    onSave(template)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.isEmpty)
            }
            .padding()
        }
        .frame(width: 700, height: 600)
    }
}
