import Foundation
import SwiftUI
import LumaDomain

/// Machine-local UI preference. It never becomes part of a photo's edit state.
enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans", english = "en", system = "system"
    var id: String { rawValue }
    var nativeName: String {
        switch self { case .chinese: return "简体中文"; case .english: return "English"; case .system: return L("跟随系统") }
    }
}

@MainActor final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published var selection: AppLanguage {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Localization.preferenceKey) }
    }
    init() { selection = Localization.preference(stored: UserDefaults.standard.string(forKey: Localization.preferenceKey)) }
    var refreshID: String { selection.rawValue + ":" + Localization.effectiveLanguage(preference: selection).rawValue }
}

enum Localization {
    static let preferenceKey = "LumaLab.interfaceLanguage"
    static func preference(stored: String?) -> AppLanguage { stored.flatMap(AppLanguage.init(rawValue:)) ?? .system }
    static func effectiveLanguage(preference: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard preference == .system else { return preference }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }
    static var current: AppLanguage {
        let preference = preference(stored: UserDefaults.standard.string(forKey: preferenceKey))
        return effectiveLanguage(preference: preference)
    }
    private struct Template {
        var expression: NSRegularExpression
        var english: String
        var count: Int
    }
    // Templates are anchored: user filenames or arbitrary names are never translated by substring replacement.
    private static let templates: [Template] = LocalizationCatalog.english.keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
        let pieces = key.components(separatedBy: try! NSRegularExpression(pattern: "\\{[0-9]+\\}"))
        let expression = "^" + pieces.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
        return Template(expression: regex, english: LocalizationCatalog.english[key]!, count: pieces.count - 1)
    }
    static func translate(_ text: String, language: AppLanguage) -> String {
        guard language == .english else { return text }
        if let exact = LocalizationCatalog.english[text] { return exact }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for template in templates {
            guard let match = template.expression.firstMatch(in: text, range: range) else { continue }
            var result = template.english
            for index in 0..<template.count {
                guard let capture = Range(match.range(at: index + 1), in: text) else { continue }
                // Translate a captured enum title only when it is itself a known, complete catalog key.
                let raw = String(text[capture])
                let value = LocalizationCatalog.english[raw] ?? raw
                result = result.replacingOccurrences(of: "{\(index)}", with: value)
            }
            return result
        }
        return text
    }
}

func L(_ text: String) -> String { Localization.translate(text, language: Localization.current) }

func localizedMaskName(_ mask: LocalMask, language: AppLanguage? = nil) -> String {
    guard mask.kind == .automatic else { return mask.name }
    let isDefault = AutomaticMaskKind.allCases.contains { kind in
        if mask.name == kind.title { return true }
        guard mask.name.hasPrefix(kind.title + " ") else { return false }
        return Int(mask.name.dropFirst(kind.title.count + 1)) != nil
    }
    return isDefault ? Localization.translate(mask.name, language: language ?? Localization.current) : mask.name
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let matches = regex.matches(in: self, range: NSRange(startIndex..<endIndex, in: self))
        var result: [String] = [], last = startIndex
        for match in matches {
            guard let range = Range(match.range, in: self) else { continue }
            result.append(String(self[last..<range.lowerBound])); last = range.upperBound
        }
        result.append(String(self[last...])); return result
    }
}

struct LanguageSettingsView: View {
    @ObservedObject private var language = LanguageStore.shared
    var onClose: () -> Void = { NSApp.keyWindow?.close() }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("通用")).font(.title2.bold())
            Picker(L("界面语言"), selection: $language.selection) {
                ForEach(AppLanguage.allCases) { option in Text(option.nativeName).tag(option) }
            }.pickerStyle(.menu)
            Text(L("切换后立即生效；照片编辑参数不受影响。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("默认跟随系统；可分别设置每台电脑的界面语言。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("完成"), action: onClose).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 430).preferredColorScheme(.dark)
    }
}

// Kept independent of GPU/framework tests, and reusable by a Windows UI adapter.
enum LocalizationChecks {
    static func run() throws -> String {
        var checks = 0
        func check(_ ok: Bool, _ message: String) throws {
            checks += 1
            if !ok { throw NSError(domain: "LocalizationChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try check(Localization.translate("曝光", language: .english) == "Exposure", "Exposure label")
        try check(Localization.translate("曝光", language: .chinese) == "曝光", "Chinese must remain unchanged")
        try check(Localization.translate("修复笔触 · 12", language: .english) == "Repair Strokes · 12", "Interpolated count")
        try check(Localization.translate("红色范围", language: .english) == "Red Color Range", "Interpolated enum label")
        try check(Localization.translate("example.jpg", language: .english) == "example.jpg", "Filename passthrough")
        try check(Localization.translate("我的曝光.jpg", language: .english) == "我的曝光.jpg", "No substring replacement in filenames")
        try check(Localization.translate("正在识别主题…", language: .english) == "Detecting Subject…", "Automatic selection status")
        try check(Localization.translate("面部与颈部皮肤 2", language: .english) == "Face & Neck Skin 2", "Numbered face mask")
        let automatic = LocalMask(name: "面部与颈部皮肤 2", kind: .automatic)
        try check(localizedMaskName(automatic, language: .english) == "Face & Neck Skin 2", "Default mask display translation")
        try check(automatic.name == "面部与颈部皮肤 2", "Translation never mutates stored mask names")
        let renamed = LocalMask(name: "我的曝光", kind: .automatic)
        try check(localizedMaskName(renamed, language: .english) == "我的曝光", "Custom mask names stay verbatim")
        let manual = LocalMask(name: "主题", kind: .brush)
        try check(localizedMaskName(manual, language: .english) == "主题", "Manual mask names stay verbatim")
        try check(Localization.effectiveLanguage(preference: .system, preferredLanguages: ["zh-Hant-TW"]) == .chinese, "Chinese system language")
        try check(Localization.effectiveLanguage(preference: .system, preferredLanguages: ["de-DE"]) == .english, "Unsupported system language falls back to English")
        try check(Localization.effectiveLanguage(preference: .chinese, preferredLanguages: ["en-US"]) == .chinese, "Explicit preference wins")
        try check(Localization.preference(stored:nil) == .system,"Fresh install defaults to system language")
        try check(Localization.preference(stored:"invalid") == .system,"Invalid stored language falls back to system")
        try check(Localization.preference(stored:"zh-Hans") == .chinese,"Existing explicit Chinese preference is retained")
        try check(Localization.preference(stored:"en") == .english,"Existing explicit English preference is retained")
        for (key, value) in LocalizationCatalog.english {
            try check(!key.isEmpty && !value.isEmpty, "Empty localization entry")
            let tokens = try NSRegularExpression(pattern: "\\{[0-9]+\\}")
            func placeholders(_ text: String) -> [String] { tokens.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {Range($0.range,in:text).map {String(text[$0])}}.sorted() }
            try check(placeholders(key) == placeholders(value), "Placeholder mismatch: \(key)")
        }
        return "Localization checks passed: \(checks)"
    }
}
