import SwiftUI
import AppKit

// MARK: - 桌面歌词窗口控制器
class DesktopLyricsWindowController: NSWindowController {
    static let shared = DesktopLyricsWindowController()
    
    private var lyricsWindow: NSWindow?
    private var hostingView: NSHostingView<DesktopLyricsView>?
    private weak var whisperService: WhisperService?
    private weak var audioPlayer: AudioPlayerService?
    
    func show(with whisperService: WhisperService, audioPlayer: AudioPlayerService) {
        self.whisperService = whisperService
        self.audioPlayer = audioPlayer
        if lyricsWindow == nil {
            createWindow(whisperService: whisperService, audioPlayer: audioPlayer)
        } else {
            // 更新已有窗口的内容
            let contentView = DesktopLyricsView(whisperService: whisperService, audioPlayer: audioPlayer, windowController: self)
            hostingView?.rootView = contentView
        }
        lyricsWindow?.orderFront(nil)
    }
    
    func hide() {
        lyricsWindow?.orderOut(nil)
    }
    
    func toggle(with whisperService: WhisperService, audioPlayer: AudioPlayerService) {
        if lyricsWindow?.isVisible == true {
            hide()
        } else {
            show(with: whisperService, audioPlayer: audioPlayer)
        }
    }
    
    private func createWindow(whisperService: WhisperService, audioPlayer: AudioPlayerService) {
        let settings = AppSettings.shared.desktopLyrics
        
        let window = NSWindow(
            contentRect: NSRect(
                x: settings.positionX,
                y: settings.positionY,
                width: settings.windowWidth,
                height: settings.windowHeight
            ),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = !settings.locked
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let contentView = DesktopLyricsView(whisperService: whisperService, audioPlayer: audioPlayer, windowController: self)
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        
        self.lyricsWindow = window
        self.hostingView = hostingView
        
        // 监听窗口位置变化
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.saveWindowPosition()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.saveWindowSize()
        }
    }
    
    private func saveWindowPosition() {
        guard let frame = lyricsWindow?.frame else { return }
        Task { @MainActor in
            AppSettings.shared.desktopLyrics.positionX = frame.origin.x
            AppSettings.shared.desktopLyrics.positionY = frame.origin.y
        }
    }
    
    private func saveWindowSize() {
        guard let frame = lyricsWindow?.frame else { return }
        Task { @MainActor in
            AppSettings.shared.desktopLyrics.windowWidth = frame.width
            AppSettings.shared.desktopLyrics.windowHeight = frame.height
        }
    }
    
    func updateLockState() {
        lyricsWindow?.isMovableByWindowBackground = !AppSettings.shared.desktopLyrics.locked
    }
    
    func updateSettings() {
        guard let window = lyricsWindow else { return }
        let settings = AppSettings.shared.desktopLyrics
        window.setFrame(
            NSRect(x: settings.positionX, y: settings.positionY,
                   width: settings.windowWidth, height: settings.windowHeight),
            display: true
        )
        window.isMovableByWindowBackground = !settings.locked
    }
}

// MARK: - 桌面歌词视图
struct DesktopLyricsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var whisperService: WhisperService
    @ObservedObject var audioPlayer: AudioPlayerService
    weak var windowController: DesktopLyricsWindowController?
    @State private var isHovering = false
    @State private var showingSettings = false
    
    // 定时器更新当前时间
    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    @State private var currentTime: TimeInterval = 0
    
    var body: some View {
        ZStack {
            // 背景
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.desktopLyrics.backgroundColor.color)
            
            // 歌词文本
            VStack(spacing: 4) {
                ForEach(Array(currentLines.enumerated()), id: \.offset) { index, line in
                    Text(line.text)
                        .font(.system(size: settings.desktopLyrics.fontSize, weight: .medium))
                        .foregroundColor(line.isCurrent ? 
                            settings.desktopLyrics.fontColor.color : 
                            settings.desktopLyrics.fontColor.color.opacity(0.5))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .animation(.easeInOut(duration: 0.2), value: line.isCurrent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
            // 悬停时显示控制按钮
            if isHovering {
                VStack {
                    HStack(spacing: 8) {
                        Spacer()
                        
                        // 锁定按钮
                        Button(action: toggleLock) {
                            Image(systemName: settings.desktopLyrics.locked ? "lock.fill" : "lock.open")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(settings.desktopLyrics.locked ? "解锁歌词位置" : "锁定歌词位置")
                        
                        // 设置按钮
                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("歌词设置")
                        
                        // 关闭按钮
                        Button(action: { DesktopLyricsWindowController.shared.hide() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .background(Color.red.opacity(0.7))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("关闭桌面歌词")
                    }
                    .padding(8)
                    Spacer()
                }
            }
            
            // 锁定状态指示器
            if settings.desktopLyrics.locked && !isHovering {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(6)
                    }
                    Spacer()
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onReceive(timer) { _ in
            currentTime = audioPlayer.currentTime
        }
        .popover(isPresented: $showingSettings) {
            LyricsSettingsPopover(settings: settings, windowController: windowController)
        }
    }
    
    // 根据当前播放时间获取要显示的歌词行
    private var currentLines: [LyricLine] {
        let subtitles = whisperService.subtitles
        let lineCount = settings.desktopLyrics.lineCount
        
        guard !subtitles.isEmpty else {
            return [LyricLine(text: "等待字幕...", isCurrent: true)]
        }
        
        // 找到当前正在播放的字幕索引
        var currentIndex = 0
        for (index, subtitle) in subtitles.enumerated() {
            if currentTime >= subtitle.startTime && currentTime < subtitle.endTime {
                currentIndex = index
                break
            } else if currentTime >= subtitle.endTime {
                currentIndex = index
            }
        }
        
        // 计算要显示的范围：当前行在中间
        let halfCount = lineCount / 2
        var startIndex = max(0, currentIndex - halfCount)
        var endIndex = min(subtitles.count, startIndex + lineCount)
        
        // 调整确保显示足够的行数
        if endIndex - startIndex < lineCount && startIndex > 0 {
            startIndex = max(0, endIndex - lineCount)
        }
        
        var lines: [LyricLine] = []
        for i in startIndex..<endIndex {
            let subtitle = subtitles[i]
            let isCurrent = (i == currentIndex)
            lines.append(LyricLine(text: subtitle.text, isCurrent: isCurrent))
        }
        
        return lines.isEmpty ? [LyricLine(text: "等待字幕...", isCurrent: true)] : lines
    }
    
    private func toggleLock() {
        settings.desktopLyrics.locked.toggle()
        windowController?.updateLockState()
    }
}

// 歌词行数据
struct LyricLine: Equatable {
    let text: String
    let isCurrent: Bool
}

// MARK: - 歌词设置弹出框
struct LyricsSettingsPopover: View {
    @ObservedObject var settings: AppSettings
    weak var windowController: DesktopLyricsWindowController?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("桌面歌词设置")
                .font(.headline)
            
            Divider()
            
            // 锁定开关
            Toggle("锁定位置", isOn: $settings.desktopLyrics.locked)
                .onChange(of: settings.desktopLyrics.locked) { _, _ in
                    windowController?.updateLockState()
                }
            
            Divider()
            
            // 字体大小
            HStack {
                Text("字体大小")
                Slider(value: $settings.desktopLyrics.fontSize, in: 14...48, step: 2)
                Text("\(Int(settings.desktopLyrics.fontSize))")
                    .frame(width: 30)
            }
            
            // 显示行数
            HStack {
                Text("显示行数")
                Stepper("\(settings.desktopLyrics.lineCount) 行", 
                       value: $settings.desktopLyrics.lineCount, in: 1...5)
            }
            
            // 字体颜色
            ColorPicker("字体颜色", selection: Binding(
                get: { settings.desktopLyrics.fontColor.color },
                set: { settings.desktopLyrics.fontColor = CodableColor($0) }
            ))
            
            // 背景颜色
            ColorPicker("背景颜色", selection: Binding(
                get: { settings.desktopLyrics.backgroundColor.color },
                set: { settings.desktopLyrics.backgroundColor = CodableColor($0) }
            ))
            
            Divider()
            
            // 窗口大小
            HStack {
                Text("宽度")
                Slider(value: $settings.desktopLyrics.windowWidth, in: 300...1200, step: 50)
                Text("\(Int(settings.desktopLyrics.windowWidth))")
                    .frame(width: 45)
            }
            .onChange(of: settings.desktopLyrics.windowWidth) { _, _ in
                windowController?.updateSettings()
            }
            
            HStack {
                Text("高度")
                Slider(value: $settings.desktopLyrics.windowHeight, in: 50...300, step: 10)
                Text("\(Int(settings.desktopLyrics.windowHeight))")
                    .frame(width: 45)
            }
            .onChange(of: settings.desktopLyrics.windowHeight) { _, _ in
                windowController?.updateSettings()
            }
        }
        .padding()
        .frame(width: 300)
    }
}
