import Foundation

public enum AutomaticMaskKind: String, Codable, CaseIterable, Identifiable {
    case subject, people, background, face, skin, allSkin, hair, eyes, glasses, lips, sky
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .subject: return "主题"
        case .people: return "人物"
        case .background: return "背景"
        case .face: return "面部"
        case .skin: return "面部与颈部皮肤"
        case .allSkin: return "所有皮肤"
        case .hair: return "头发"
        case .eyes: return "眼睛"
        case .glasses: return "眼镜"
        case .lips: return "嘴唇"
        case .sky: return "天空"
        }
    }
    public var symbol: String {
        switch self {
        case .subject: return "viewfinder"
        case .people: return "person.fill"
        case .background: return "person.crop.rectangle"
        case .face, .skin: return "face.smiling"
        case .allSkin: return "person.fill.viewfinder"
        case .hair: return "person.crop.circle"
        case .eyes: return "eye"
        case .glasses: return "eyeglasses"
        case .lips: return "mouth"
        case .sky: return "cloud.sun"
        }
    }
}
public struct AutomaticMaskResult {
    public let name: String
    public let raster: PortableMaskRaster
    public let backend: String
    public init(name: String, raster: PortableMaskRaster, backend: String) { self.name = name; self.raster = raster; self.backend = backend }
}
