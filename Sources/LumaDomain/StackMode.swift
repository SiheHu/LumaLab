import Foundation

package enum StackMode: String, CaseIterable, Identifiable {
    case average, median, sigmaClip, starTrails, hdr, focus, panorama
    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .sigmaClip: return "Sigma-clipped 降噪"
        case .focus: return "Focus Stacking"
        case .panorama: return "Panorama"
        case .average: return "平均堆栈降噪"
        case .median: return "中位数堆栈降噪"
        case .starTrails: return "星轨叠加"
        case .hdr: return "HDR 曝光融合（标准动态范围）"
        }
    }
}
