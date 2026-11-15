import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, animation, targets, playback, sound, display, presets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .animation: return "动画"
        case .targets: return "应用"
        case .playback: return "播放"
        case .sound: return "声音与过渡"
        case .display: return "显示"
        case .presets: return "我的方案"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "house"
        case .animation: return "film"
        case .targets: return "square.grid.2x2"
        case .playback: return "play"
        case .sound: return "speaker.wave.2"
        case .display: return "macwindow"
        case .presets: return "bookmark"
        }
    }
}
