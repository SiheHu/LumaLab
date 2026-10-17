import Foundation

package struct PhotoLibraryItem: Codable, Equatable, Identifiable {
    package var path: String
    package var rating: Int = 0
    package var flag: Int = 0
    package var keywords: String = ""
    package var collection: String = ""
    package var id: String { path }
    package var url: URL { URL(fileURLWithPath: path) }
    package var name: String { url.lastPathComponent }

    package init(path: String, rating: Int = 0, flag: Int = 0, keywords: String = "", collection: String = "") {
        self.path = path; self.rating = rating; self.flag = flag; self.keywords = keywords; self.collection = collection
    }
}
package struct UserPreset: Codable, Identifiable {
    package var id = UUID()
    package var name: String
    package var state: EditState
    package var category = "自定义"
    package var author = ""

    package init(id: UUID = UUID(), name: String, state: EditState) {
        self.id = id; self.name = name; self.state = state
    }
}
package struct ExportPreset: Codable, Identifiable {
    package var id = UUID()
    package var name: String
    package var options: ExportOptions

    package init(id: UUID = UUID(), name: String, options: ExportOptions) {
        self.id = id; self.name = name; self.options = options
    }
}
package struct WorkspaceData: Codable {
    package var library: [PhotoLibraryItem] = []
    package var presets: [UserPreset] = []
    package var exportPresets: [ExportPreset] = []

    package init(library: [PhotoLibraryItem] = [], presets: [UserPreset] = [], exportPresets: [ExportPreset] = []) {
        self.library = library; self.presets = presets; self.exportPresets = exportPresets
    }
}
package struct SidecarDocument: Codable {
    package var version: Int = 2
    package var sourceSHA256: String
    package var sourceFilename: String
    package var edits: EditState
    package var snapshots: [SavedSnapshot] = []
    package var virtualCopies: [SavedSnapshot] = []
    package var history: [EditState] = []
    package var updatedAt = Date()

    package init(version: Int = 2, sourceSHA256: String, sourceFilename: String, edits: EditState, snapshots: [SavedSnapshot] = [], virtualCopies: [SavedSnapshot] = [], history: [EditState] = [], updatedAt: Date = Date()) {
        self.version = version; self.sourceSHA256 = sourceSHA256; self.sourceFilename = sourceFilename; self.edits = edits; self.snapshots = snapshots; self.virtualCopies = virtualCopies; self.history = history; self.updatedAt = updatedAt
    }
}

package func mergedSettings(_ source: EditState, into destination: EditState, color: Bool, geometry: Bool, masks: Bool) -> EditState {
    var result = destination
    if color {
        result.adjustments = source.adjustments; result.curves = source.curves; result.hsl = source.hsl
        result.lut = source.lut; result.grading = source.grading; result.pointColor = source.pointColor; result.calibration = source.calibration
    }
    if geometry {
        result.crop = source.crop; result.quarterTurns = source.quarterTurns
        result.flipHorizontal = source.flipHorizontal; result.geometry = source.geometry
    }
    if masks { result.masks = source.masks }
    for section in AdjustmentSection.allCases {
        let transfer = section == .repairs ? false : section == .masks ? masks : ([.geometry,.transform].contains(section) ? geometry : color)
        if transfer {
            if source.disabledSections.contains(section) { result.disabledSections.insert(section) }
            else { result.disabledSections.remove(section) }
        }
    }
    return result
}


extension UserPreset {
    private enum CodingKeys: String, CodingKey { case id, name, state, category, author }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(), name: try c.decode(String.self, forKey: .name), state: try c.decode(EditState.self, forKey: .state))
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "自定义"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
    }
}

package enum BuiltInPreset: String, CaseIterable {
    case original = "原始", daylight = "柔和日光", cinema = "电影色调", silver = "黑白"
    package var category: String { self == .original ? "基础" : self == .silver ? "黑白" : "风格" }
    package var state: EditState {
        var s = EditState()
        switch self {
        case .original: break
        case .daylight: s.adjustments.exposure=0.2; s.adjustments.contrast = -12; s.adjustments.highlights = -30; s.adjustments.shadows=24; s.adjustments.temperature=12; s.adjustments.vibrance=18
        case .cinema: s.adjustments.contrast=22; s.adjustments.highlights = -28; s.adjustments.shadows=14; s.adjustments.temperature = -12; s.adjustments.saturation = -20; s.adjustments.vignette=24
        case .silver: s.adjustments.saturation = -100; s.adjustments.contrast=24; s.adjustments.highlights = -15; s.adjustments.shadows=16; s.adjustments.clarity=12
        }
        return s
    }
}
