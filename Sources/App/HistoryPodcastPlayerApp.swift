import SwiftUI

@main
struct HistoryPodcastPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var audioPlayer = AudioPlayerService()
    @StateObject private var playlistManager = PlaylistManager()
    @StateObject private var whisperService = WhisperService()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
                .environmentObject(playlistManager)
                .environmentObject(whisperService)
                .onAppear {
                    appDelegate.whisperService = whisperService
                    appDelegate.audioPlayer = audioPlayer
                    // 连接 AudioPlayer 和 WhisperService
                    audioPlayer.setWhisperService(whisperService)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("设置...") {
                    NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Button("AI 模型管理") {
                    NSApp.sendAction(#selector(AppDelegate.showAIModelManager), to: nil, from: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .windowArrangement) {
                Button("切换桌面歌词") {
                    NSApp.sendAction(#selector(AppDelegate.toggleDesktopLyrics), to: nil, from: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var whisperService: WhisperService?
    var audioPlayer: AudioPlayerService?
    private var settingsWindow: NSWindow?
    private var aiManagerWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化 AI 模型管理器
        Task { @MainActor in
            await AIModelManager.shared.refreshAll()
        }
    }
    
    @objc func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "设置"
            window.styleMask = [.titled, .closable]
            window.center()
            
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc func showAIModelManager() {
        if aiManagerWindow == nil {
            let managerView = AIModelManagerView()
            let hostingController = NSHostingController(rootView: managerView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AI 模型管理"
            window.styleMask = [.titled, .closable]
            window.center()
            
            aiManagerWindow = window
        }
        aiManagerWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc func toggleDesktopLyrics() {
        guard let whisperService = whisperService, let audioPlayer = audioPlayer else { return }
        
        Task { @MainActor in
            AppSettings.shared.desktopLyrics.enabled.toggle()
            DesktopLyricsWindowController.shared.toggle(with: whisperService, audioPlayer: audioPlayer)
        }
    }
}
