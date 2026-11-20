// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system, portuguese = "pt-BR", english = "en", spanish = "es", french = "fr"
    case german = "de", japanese = "ja", korean = "ko", italian = "it"

    public var nativeName: String {
        switch self {
        case .system: "System"
        case .portuguese: "Português (Brasil)"
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .italian: "Italiano"
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .system, .english: "en_US"
        case .portuguese: "pt_BR"
        case .spanish: "es_ES"
        case .french: "fr_FR"
        case .german: "de_DE"
        case .japanese: "ja_JP"
        case .korean: "ko_KR"
        case .italian: "it_IT"
        }
    }

    public static func resolve(_ preferred: [String]) -> AppLanguage {
        for identifier in preferred {
            let base = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init)
            if base == "pt" { return .portuguese }
            if let language = allCases.first(where: { $0 != .system && $0.rawValue.lowercased() == base }) { return language }
        }
        return .english
    }
}

public struct Localization: Sendable {
    private static let resources: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("MyExplorer_ExplorerLocalization.bundle"),
                  let bundle = Bundle(url: url) else { fatalError("Application localization resources are missing") }
            return bundle
        }
        return Bundle.module
    }()
    public let language: AppLanguage
    public var locale: Locale { Locale(identifier: language.localeIdentifier) }

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language == .system ? AppLanguage.resolve(preferredLanguages) : language
    }

    public func text(_ key: String, _ arguments: CVarArg...) -> String {
        let fallback = bundle(for: .english)?.localizedString(forKey: key, value: key, table: nil) ?? key
        let format = bundle(for: language)?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    public func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
    public func bytes(_ value: Int64) -> String { value.formatted(.byteCount(style: .file).locale(locale)) }
    public func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter.string(from: value)
    }

    /// Integer cardinal categories for the eight supported languages.
    public func pluralCategory(_ count: Int) -> String {
        switch language {
        case .japanese, .korean: return "other"
        case .french, .portuguese: return count == 0 || count == 1 ? "one" : "other"
        default: return count == 1 ? "one" : "other"
        }
    }

    public func itemCount(_ count: Int) -> String {
        text("status.items.\(pluralCategory(count))", number(count))
    }

    public func listingStatus(visible: Int, total: Int, filtered: Bool, selected: Int) -> String {
        let items = filtered ? text("status.filtered.\(pluralCategory(total))", number(visible), number(total)) : itemCount(visible)
        guard selected > 0 else { return items }
        return text("status.combined", items, text("status.selection.\(pluralCategory(selected))", number(selected)))
    }

    func bundle(for language: AppLanguage) -> Bundle? {
        // Xcode preserves region casing. Some SwiftPM resource bundles lowercase it.
        guard let url = Self.resources.url(forResource: language.rawValue, withExtension: "lproj")
            ?? Self.resources.url(forResource: language.rawValue.lowercased(), withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }

    func catalog(for language: AppLanguage) -> [String: String] {
        guard let url = bundle(for: language)?.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return dictionary
    }
}

@MainActor
public final class LanguagePreferences {
    private let defaults: UserDefaults
    public private(set) var selection: AppLanguage
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: "interfaceLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
    public func select(_ language: AppLanguage) {
        selection = language
        defaults.set(language.rawValue, forKey: "interfaceLanguage")
    }
}
