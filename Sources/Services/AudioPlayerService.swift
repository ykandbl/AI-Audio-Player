import Foundation
import AVFoundation
import Combine

@MainActor
class AudioPlayerService: ObservableObject {
    @Published var playlist: [AudioTrack] = []
    @Published var currentTrack: AudioTrack?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published var isPreparingSubtitles = false  // 正在准备字幕
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var whisperService: WhisperService?
    
    let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    
    func setWhisperService(_ service: WhisperService) {
        self.whisperService = service
    }
    
    func loadFolder(url: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        var tracks: [AudioTrack] = []
        let supportedExtensions = ["m4a", "mp3", "wav", "aac", "flac"]
        
        while let fileURL = enumerator.nextObject() as? URL {
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                tracks.append(AudioTrack(url: fileURL))
            }
        }
        
        playlist = tracks.sorted { $0.fileName < $1.fileName }
    }
    
    func loadPlaylist(_ tracks: [AudioTrack]) {
        playlist = tracks
    }
    
    func play(track: AudioTrack) {
        stop()
        
        do {
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.enableRate = true
            player?.rate = playbackRate
            player?.prepareToPlay()
            
            currentTrack = track
            duration = player?.duration ?? 0
            
            if track.lastPlayedPosition > 0 {
                player?.currentTime = track.lastPlayedPosition
                currentTime = track.lastPlayedPosition
            }
            
            // 检查是否有字幕
            if let whisper = whisperService {
                // 始终使用流式模式，它会自动处理：
                // 1. 没有字幕 -> 从头开始转录
                // 2. 有完整字幕 -> 直接使用
                // 3. 有部分字幕 -> 加载后继续转录
                isPreparingSubtitles = true
                whisper.startStreamingTranscription(audioURL: track.url) { [weak self] in
                    Task { @MainActor in
                        self?.isPreparingSubtitles = false
                        self?.startPlayback()
                    }
                }
            } else {
                startPlayback()
            }
        } catch {
            print("播放失败: \(error.localizedDescription)")
        }
    }
    
    private func startPlayback() {
        player?.play()
        isPlaying = true
        startTimer()
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
    
    func stop() {
        saveProgress()
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        isPreparingSubtitles = false
        whisperService?.stopStreamingTranscription()
    }
    
    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }
    
    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }
    
    func skipForward(_ seconds: TimeInterval = 15) {
        let newTime = min(currentTime + seconds, duration)
        seek(to: newTime)
    }
    
    func skipBackward(_ seconds: TimeInterval = 15) {
        let newTime = max(currentTime - seconds, 0)
        seek(to: newTime)
    }
    
    func playNext() {
        guard let current = currentTrack,
              let index = playlist.firstIndex(where: { $0.id == current.id }),
              index + 1 < playlist.count else { return }
        play(track: playlist[index + 1])
    }
    
    func playPrevious() {
        guard let current = currentTrack,
              let index = playlist.firstIndex(where: { $0.id == current.id }),
              index > 0 else { return }
        play(track: playlist[index - 1])
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let player = self.player else { return }
                self.currentTime = player.currentTime
                
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.playNext()
                }
            }
        }
    }
    
    private func saveProgress() {
        guard let track = currentTrack else { return }
        if let index = playlist.firstIndex(where: { $0.id == track.id }) {
            playlist[index].lastPlayedPosition = currentTime
        }
    }
}
