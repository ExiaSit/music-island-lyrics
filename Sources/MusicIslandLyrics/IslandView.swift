import AppKit
import SwiftUI

struct IslandView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFieldFocused: Bool

    private let islandWidth: CGFloat = 376

    private var islandHeight: CGFloat {
        model.compactIslandHeight + model.islandExtraHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(.black)
                .frame(width: islandWidth, height: islandHeight + 28)
                .offset(y: -28)

            VStack(spacing: 0) {
                compactContent

                switch model.islandPresentation {
                case .compact:
                    EmptyView()
                case .hover:
                    hoverContent
                case .search:
                    searchContent
                }
            }
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .contextMenu {
            Button("搜索在线音乐") { model.openSearch() }
            Divider()
            Button("重新匹配歌词") { model.retryLyrics() }
                .disabled(model.track == nil)
            Divider()
            Button("退出 Music Island Lyrics") {
                NSApplication.shared.terminate(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: model.islandPresentation) {
            if model.islandPresentation == .search {
                searchFieldFocused = true
            } else {
                searchFieldFocused = false
            }
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        if let track = model.track {
            HStack(spacing: 8) {
                Group {
                    if model.status == .loadingLyrics {
                        Text("匹配歌词中…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    } else if case .synced(let lines) = model.lyrics {
                        SynchronizedLyricText(lines: lines, track: track)
                    } else {
                        Text(model.currentLyric)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .frame(width: 120, height: 30, alignment: .leading)

                Color.clear.frame(width: 172)

                artworkView
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .frame(width: islandWidth, height: model.compactIslandHeight)
            .animation(.easeInOut(duration: 0.18), value: model.currentLyric)
        } else {
            idleCompactContent
        }
    }

    @ViewBuilder
    private var hoverContent: some View {
        if let track = model.track {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                progressScrubber(for: track)

                controlButton(
                    symbol: "magnifyingglass",
                    label: "搜索在线音乐",
                    action: model.openSearch
                )
                controlButton(
                    symbol: track.isPlaying ? "pause.fill" : "play.fill",
                    label: track.isPlaying ? "暂停" : "播放",
                    action: model.togglePlayback
                )
                controlButton(
                    symbol: "forward.end.fill",
                    label: "下一首",
                    action: model.playNext
                )
            }
            .padding(.horizontal, 16)
            .frame(width: islandWidth, height: 38)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: model.activateMusicApp)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("搜索在线音乐")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("在 Music 中打开搜索结果")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
                controlButton(
                    symbol: "magnifyingglass",
                    label: "搜索在线音乐",
                    action: model.openSearch
                )
            }
            .padding(.horizontal, 16)
            .frame(width: islandWidth, height: 38)
        }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))

                ZStack(alignment: .leading) {
                    if model.searchQuery.isEmpty {
                        Text("搜索歌名、歌手或专辑")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused($searchFieldFocused)
                        .onExitCommand(perform: model.closeSearch)
                }

                if !model.searchQuery.isEmpty {
                    Button(action: { model.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .frame(height: 50)

            switch model.searchStatus {
            case .idle:
                EmptyView()
            case .loading:
                searchStatusRow(icon: nil, text: "正在搜索…", showsProgress: true)
            case .empty:
                searchStatusRow(icon: "magnifyingglass", text: "没有找到相关歌曲")
            case .failure(let message):
                searchStatusRow(icon: "exclamationmark.triangle", text: message)
            case .results:
                ForEach(model.searchResults.prefix(6)) { result in
                    searchResultRow(result)
                }
            }
        }
        .frame(width: islandWidth, alignment: .top)
    }

    private func searchStatusRow(
        icon: String?,
        text: String,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: islandWidth, height: 42)
    }

    private func searchResultRow(_ result: StoreSearchResult) -> some View {
        Button(action: { model.openSearchResult(result) }) {
            HStack(spacing: 9) {
                AsyncImage(url: result.artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(result.album.isEmpty
                         ? result.artist
                         : "\(result.artist) · \(result.album)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(width: islandWidth, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("在 Music 中打开 \(result.title)，\(result.artist)")
    }

    private func progressScrubber(for track: TrackSnapshot) -> some View {
        let duration = max(track.duration, 1)
        let position = min(max(model.displayPlaybackPosition, 0), duration)

        return VStack(spacing: 0) {
            PlaybackScrubber(
                position: position,
                duration: duration,
                onScrub: model.updateSeekPreview,
                onCommit: model.finishSeeking
            )
            .frame(height: 14)

            HStack {
                Text(formatTime(position))
                Spacer(minLength: 0)
                Text(formatTime(track.duration))
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.46))
            .monospacedDigit()
        }
        .frame(width: 104, height: 30)
        .accessibilityLabel("播放进度")
    }

    private var artworkView: some View {
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.pink, .purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.7)
        }
    }

    private func controlButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private var idleCompactContent: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.09), in: Circle())
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(width: islandWidth, height: model.compactIslandHeight)
    }

    private var statusIcon: String {
        switch model.status {
        case .permissionRequired: return "lock.trianglebadge.exclamationmark"
        case .error: return "exclamationmark.triangle"
        default: return "music.note"
        }
    }

    private var statusText: String {
        switch model.status {
        case .waitingForMusic: return "在 Apple Music 中播放一首歌"
        case .permissionRequired(let message), .error(let message): return message
        default: return "在 Apple Music 中播放一首歌"
        }
    }
}

private struct PlaybackScrubber: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onScrub: (TimeInterval) -> Void
    let onCommit: () -> Void

    @State private var isHoveringKnob = false
    @State private var isDragging = false

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let knobSize: CGFloat = isHoveringKnob || isDragging ? 10 : 7
            let filledWidth = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 3)

                Capsule()
                    .fill(.white.opacity(0.86))
                    .frame(width: max(filledWidth, 0), height: 3)

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(filledWidth - knobSize / 2, 0), width - knobSize))
                    .onHover { hovering in
                        isHoveringKnob = hovering
                    }
                    .animation(.easeOut(duration: 0.12), value: isHoveringKnob)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub(time(for: value.location.x, width: width))
                    }
                    .onEnded { value in
                        onScrub(time(for: value.location.x, width: width))
                        isDragging = false
                        onCommit()
                    }
            )
        }
        .accessibilityLabel("播放进度")
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        duration * min(max(x / width, 0), 1)
    }
}

private struct SynchronizedLyricText: View {
    let lines: [LyricLine]
    let track: TrackSnapshot
    private let lineWidths: [CGFloat]

    private let pointSize: CGFloat = 11

    init(lines: [LyricLine], track: TrackSnapshot) {
        self.lines = lines
        self.track = track
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        self.lineWidths = lines.map { line in
            (line.text as NSString).size(withAttributes: [.font: font]).width
        }
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let position = track.estimatedPosition(at: context.date)
                let index = LyricSynchronizer.lineIndex(at: position, in: lines) ?? 0
                let line = lines[index]
                let end = LyricSynchronizer.endTime(
                    for: index,
                    in: lines,
                    trackDuration: track.duration
                )
                let progress = LyricSynchronizer.progress(
                    at: position,
                    start: line.time,
                    end: end
                )

                Text(line.text)
                    .font(.system(size: pointSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: offset(
                        textWidth: lineWidths[index],
                        progress: progress,
                        availableWidth: geometry.size.width
                    ))
                    .id(index)
            }
        }
        .frame(height: 17)
        .clipped()
        .accessibilityLabel("同步歌词")
    }

    private func offset(
        textWidth: CGFloat,
        progress: Double,
        availableWidth: CGFloat
    ) -> CGFloat {
        let distance = max(0, textWidth - availableWidth)
        guard distance > 1 else { return 0 }

        // 每句开头和结尾各停留 12%，中间只滚动一次。
        let scrollingProgress = min(max((progress - 0.12) / 0.76, 0), 1)
        return -distance * CGFloat(scrollingProgress)
    }
}
