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
