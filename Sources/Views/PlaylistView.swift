import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 搜索窗口控制器
@MainActor
class SearchWindowController {
    static let shared = SearchWindowController()
    private var panel: NSPanel?
    
    func show(playlistManager: PlaylistManager, audioPlayer: AudioPlayerService) {
        if panel == nil {
            let searchView = SearchWindowContent(playlistManager: playlistManager, audioPlayer: audioPlayer) {
                self.panel?.close()
            }
            let hostingController = NSHostingController(rootView: searchView)
            
            // 使用 NSPanel 而不是 NSWindow，它能更好地处理键盘输入
            let newPanel = NSPanel(contentViewController: hostingController)
            newPanel.title = "搜索音频"
            newPanel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
            newPanel.isFloatingPanel = false
            newPanel.becomesKeyOnlyIfNeeded = false
            newPanel.setContentSize(NSSize(width: 500, height: 400))
            newPanel.center()
            
            panel = newPanel
        }
        
        // 根据应用设置更新主题
        updatePanelAppearance()
        
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func updatePanelAppearance() {
        guard let panel = panel else { return }
        
        let settings = AppSettings.shared
        switch settings.theme.colorScheme {
        case .system:
            panel.appearance = nil  // 跟随系统
        case .light:
            panel.appearance = NSAppearance(named: .aqua)
        case .dark:
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        panel.backgroundColor = NSColor.windowBackgroundColor
    }
}

// MARK: - 搜索窗口内容
struct SearchWindowContent: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerService
    @ObservedObject var settings = AppSettings.shared
    var onClose: () -> Void
    @State private var searchText = ""
    
    var searchResults: [AudioTrack] {
        guard !searchText.isEmpty else { return [] }
        var results: [AudioTrack] = []
        
        func searchInPlaylist(_ playlist: Playlist) {
            for track in playlist.tracks {
                if track.title.localizedCaseInsensitiveContains(searchText) {
                    results.append(track)
                }
            }
            for subPlaylist in playlist.subPlaylists {
                searchInPlaylist(subPlaylist)
            }
        }
        
        for playlist in playlistManager.rootPlaylists {
            searchInPlaylist(playlist)
        }
        return results
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索框
            TextField("输入关键词搜索...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
                .padding()
            
            Divider()
            
            // 搜索结果
            if searchText.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("输入关键词开始搜索")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if searchResults.isEmpty {
                VStack {
                    Spacer()
                    Text("没有找到「\(searchText)」")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults) { track in
                            HStack {
                                Image(systemName: "music.note")
                                    .foregroundColor(.secondary)
                                Text(track.title)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                audioPlayer.play(track: track)
                                onClose()
                            }
                            
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(colorScheme)
    }
    
    private var colorScheme: ColorScheme? {
        switch settings.theme.colorScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct PlaylistView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var playlistManager: PlaylistManager
    @State private var isTargeted = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 导航栏
            NavigationHeader(playlistManager: playlistManager, audioPlayer: audioPlayer)
            
            Divider()
            
            // 内容区
            if playlistManager.currentPlaylist == nil {
                RootPlaylistsView(playlistManager: playlistManager, audioPlayer: audioPlayer, isTargeted: $isTargeted)
            } else {
                PlaylistContentView(playlistManager: playlistManager, audioPlayer: audioPlayer)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                Task { @MainActor in
                    playlistManager.addRootFolder(url: url)
                }
            }
        }
        return true
    }
}

// MARK: - 导航栏
struct NavigationHeader: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if playlistManager.currentPlaylist != nil {
                    Button(action: { playlistManager.navigateUp() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                
                Text(playlistManager.currentPlaylist?.name ?? "播放列表")
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                // 搜索按钮
                Button(action: { 
                    SearchWindowController.shared.show(playlistManager: playlistManager, audioPlayer: audioPlayer)
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("搜索")
                
                Button(action: openFolder) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("添加文件夹")
            }
            
            // 面包屑导航
            if !playlistManager.navigationPath.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button("全部") {
                            playlistManager.navigateToRoot()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        
                        ForEach(playlistManager.navigationPath) { playlist in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Button(playlist.name) {
                                playlistManager.navigateTo(playlist)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(playlist.id == playlistManager.currentPlaylist?.id ? .primary : .accentColor)
                            .lineLimit(1)
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择包含音频文件的文件夹"
        
        if panel.runModal() == .OK, let url = panel.url {
            playlistManager.addRootFolder(url: url)
        }
    }
}

// MARK: - 根目录播放列表视图
struct RootPlaylistsView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerService
    @Binding var isTargeted: Bool
    
    var body: some View {
        if playlistManager.rootPlaylists.isEmpty {
            EmptyPlaylistView()
        } else {
            List {
                ForEach(playlistManager.rootPlaylists) { playlist in
                    PlaylistRow(playlist: playlist, playlistManager: playlistManager)
                        .contextMenu {
                            Button("刷新") {
                                playlistManager.refreshPlaylist(playlist)
                            }
                            Button("移除", role: .destructive) {
                                playlistManager.removePlaylist(playlist)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - 播放列表内容视图
struct PlaylistContentView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        if let playlist = playlistManager.currentPlaylist {
            List {
                // 子文件夹
                if !playlist.subPlaylists.isEmpty {
                    Section("文件夹") {
                        ForEach(playlist.subPlaylists) { subPlaylist in
                            PlaylistRow(playlist: subPlaylist, playlistManager: playlistManager)
                        }
                    }
                }
                
                // 音频文件
                if !playlist.tracks.isEmpty {
                    Section("音频 (\(playlist.tracks.count))") {
                        ForEach(playlist.tracks) { track in
                            TrackRow(
                                track: track,
                                isPlaying: audioPlayer.currentTrack?.id == track.id && audioPlayer.isPlaying
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                audioPlayer.loadPlaylist(playlist.tracks)
                                audioPlayer.play(track: track)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - 播放列表行
struct PlaylistRow: View {
    let playlist: Playlist
    @ObservedObject var playlistManager: PlaylistManager
    
    var body: some View {
        Button(action: { playlistManager.navigateTo(playlist) }) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        if !playlist.subPlaylists.isEmpty {
                            Label("\(playlist.subPlaylists.count) 文件夹", systemImage: "folder")
                        }
                        if !playlist.tracks.isEmpty {
                            Label("\(playlist.tracks.count) 音频", systemImage: "music.note")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 空播放列表视图
struct EmptyPlaylistView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("拖拽音频文件夹到这里")
                .foregroundColor(.secondary)
            Text("或点击上方按钮选择")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 音轨行
struct TrackRow: View {
    let track: AudioTrack
    let isPlaying: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "music.note")
                .foregroundColor(isPlaying ? .accentColor : .secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(2)
                    .font(.system(size: 12))
                
                if track.lastPlayedPosition > 0 {
                    Text("已播放 \(formatTime(track.lastPlayedPosition))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
