import SwiftUI

// MARK: - 进度条滑块
struct ProgressSlider: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: progressWidth(in: geometry.size.width), height: 4)
                    
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(x: progressWidth(in: geometry.size.width) - 6)
                        .opacity(isDragging ? 1 : 0)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            dragValue = progress * audioPlayer.duration
                        }
                        .onEnded { _ in
                            isDragging = false
                            audioPlayer.seek(to: dragValue)
                        }
                )
            }
            .frame(height: 12)
            
            HStack {
                Text(formatTime(isDragging ? dragValue : audioPlayer.currentTime))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                
                Spacer()
                
                Text(formatTime(audioPlayer.duration))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }
    
    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        let currentValue = isDragging ? dragValue : audioPlayer.currentTime
        let progress = currentValue / audioPlayer.duration
        return totalWidth * CGFloat(progress)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct PlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        VStack(spacing: 0) {
            CurrentTrackHeader()
            Divider()
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
            ProgressSlider()
            
            HStack(spacing: 24) {
                Button(action: { audioPlayer.playPrevious() }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                
                Button(action: { audioPlayer.skipBackward() }) {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                
                Button(action: { audioPlayer.togglePlayPause() }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                .buttonStyle(.borderless)
                
                Button(action: { audioPlayer.skipForward() }) {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                
                Button(action: { audioPlayer.playNext() }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }
            
            SpeedControl()
        }
        .padding()
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
