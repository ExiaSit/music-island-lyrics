import SwiftUI

struct LyricsPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let track = model.track {
                HStack(spacing: 10) {
                    if let artwork = model.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(action: model.togglePlayback) {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .help(track.isPlaying ? "暂停" : "播放")
                    Button(action: model.playNext) {
                        Image(systemName: "forward.end.fill")
                    }
                    .help("下一首")
                }

                Divider()

                lyricsContent
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "没有正在播放的歌曲",
                    systemImage: "music.note",
                    description: Text("请先在 Apple Music 中开始播放。")
                )
                .frame(minHeight: 170)
            }

            Divider()

            Toggle("显示顶部悬浮歌词", isOn: $model.overlayVisible)
            HStack {
                Button("重新匹配") { model.retryLyrics() }
                    .disabled(model.track == nil)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private var lyricsContent: some View {
        switch model.lyrics {
        case .synced(let lines):
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(index == model.currentLineIndex ? .headline : .body)
                                .foregroundStyle(index == model.currentLineIndex ? .primary : .secondary)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)
                .onChange(of: model.currentLineIndex) { _, index in
                    guard let index else { return }
                    withAnimation { proxy.scrollTo(index, anchor: .center) }
                }
            }
        case .plain(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
        case .instrumental:
            ContentUnavailableView("纯音乐", systemImage: "waveform", description: Text("这首曲目没有歌词。"))
        case .notFound:
            if model.status == .loadingLyrics {
                HStack { Spacer(); ProgressView("正在匹配歌词…"); Spacer() }
                    .frame(height: 120)
            } else if case .error(let message) = model.status {
                ContentUnavailableView(
                    "歌词加载失败",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
            } else {
                ContentUnavailableView("未找到歌词", systemImage: "text.magnifyingglass", description: Text("可稍后重新匹配。"))
            }
        }
    }
}
