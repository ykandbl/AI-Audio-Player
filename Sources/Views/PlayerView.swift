import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        VStack(spacing: 0) {
            // 当前播放信息
            CurrentTrackHeader()
            
            Divider()
            
            // 播放控制
            PlaybackControls()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct CurrentTrackHeader: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        VStack(spacing: 4) {
            Text("当前播放")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(audioPlayer.currentTrack?.title ?? "未选择音频")
                .font(.title2)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            
            // 显示准备字幕状态
            if audioPlayer.isPreparingSubtitles {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("准备字幕中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct PlaybackControls: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        VStack(spacing: 16) {
            // 进度条
            ProgressSlider()
            
            // 控制按钮
            HStack(spacing: 24) {
                Button(action: { audioPlayer.playPrevious() }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(audioPlayer.currentTrack == nil)
                
                Button(action: { audioPlayer.skipBackward() }) {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(audioPlayer.currentTrack == nil)
                
                Button(action: { audioPlayer.togglePlayPause() }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                .buttonStyle(.borderless)
                .disabled(audioPlayer.currentTrack == nil)
                
                Button(action: { audioPlayer.skipForward() }) {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(audioPlayer.currentTrack == nil)
                
                Button(action: { audioPlayer.playNext() }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(audioPlayer.currentTrack == nil)
            }
            
            // 速度控制
            SpeedControl()
        }
        .padding()
    }
}

struct ProgressSlider: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    
    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : audioPlayer.currentTime },
                    set: { newValue in
                        dragValue = newValue
                        if !isDragging {
                            audioPlayer.seek(to: newValue)
                        }
                    }
                ),
                in: 0...max(audioPlayer.duration, 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        audioPlayer.seek(to: dragValue)
                    }
                }
            )
            .disabled(audioPlayer.currentTrack == nil)
            
            HStack {
                Text(formatTime(audioPlayer.currentTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                
                Spacer()
                
                Text(formatTime(audioPlayer.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct SpeedControl: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        HStack {
            Text("播放速度")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Picker("", selection: Binding(
                get: { audioPlayer.playbackRate },
                set: { audioPlayer.setRate($0) }
            )) {
                ForEach(audioPlayer.availableRates, id: \.self) { rate in
                    Text("\(rate, specifier: "%.2g")x").tag(rate)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 80)
        }
    }
}
