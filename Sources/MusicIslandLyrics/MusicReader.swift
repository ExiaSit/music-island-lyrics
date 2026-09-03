import AppKit
import Foundation

enum MusicReaderError: LocalizedError {
    case automationDenied
    case script(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "请在“系统设置 → 隐私与安全性 → 自动化”中允许访问 Music。"
        case .script(let message):
            return message
        }
    }
}

@MainActor
struct MusicReader {
    func currentTrack() throws -> TrackSnapshot? {
        let isRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .isEmpty
        guard isRunning else { return nil }

        let scriptSource = #"""
        tell application id "com.apple.Music"
            if player state is stopped then return ""

            if player state is playing then
                set stateText to "playing"
            else if player state is paused then
                set stateText to "paused"
            else
                set stateText to "other"
            end if

            set t to current track
            set separator to ASCII character 9
            return stateText & separator & (name of t as text) & separator & (artist of t as text) & separator & (album of t as text) & separator & (duration of t as text) & separator & (player position as text)
        end tell
        """#

        guard let script = NSAppleScript(source: scriptSource) else {
            throw MusicReaderError.script("无法创建 Music 查询脚本。")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                throw MusicReaderError.automationDenied
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "读取 Music 播放状态失败。"
            throw MusicReaderError.script(message)
        }

        guard let output = result.stringValue, !output.isEmpty else { return nil }
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 6 else {
            throw MusicReaderError.script("Music 返回了无法识别的播放信息。")
        }

        return TrackSnapshot(
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            duration: parseAppleScriptNumber(fields[4]),
            position: parseAppleScriptNumber(fields[5]),
            isPlaying: fields[0] == "playing",
            capturedAt: Date()
        )
    }

    func currentArtwork(for track: TrackSnapshot) throws -> NSImage? {
        let scriptSource = """
        tell application id "com.apple.Music"
            if player state is stopped then return missing value
            set t to current track
            if (name of t as text) is not \(appleScriptStringLiteral(track.title)) then return missing value
            if (artist of t as text) is not \(appleScriptStringLiteral(track.artist)) then return missing value
            if (album of t as text) is not \(appleScriptStringLiteral(track.album)) then return missing value
            if (count of artworks of t) is 0 then return missing value
            return data of artwork 1 of t
        end tell
        """

        let result = try execute(scriptSource)
        let data = result.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    func togglePlayback() throws {
        _ = try execute(#"tell application id "com.apple.Music" to playpause"#)
    }

    func nextTrack() throws {
        _ = try execute(#"tell application id "com.apple.Music" to next track"#)
    }

    func seek(to position: TimeInterval) throws {
        let clampedPosition = max(0, position)
        _ = try execute("tell application id \"com.apple.Music\" to set player position to \(clampedPosition)")
    }

    private func parseAppleScriptNumber(_ value: String) -> Double {
        if let number = Double(value) { return number }
        return Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MusicReaderError.script("无法创建 Music 控制脚本。")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                throw MusicReaderError.automationDenied
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "控制 Music 失败。"
            throw MusicReaderError.script(message)
        }
        return result
    }
}
