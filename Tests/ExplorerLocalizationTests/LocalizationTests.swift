// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerLocalization

struct LocalizationTests {
    @Test func catalogsCoverEveryKeyAndPreserveArguments() {
        let localization = Localization(language: .english)
        let english = localization.catalog(for: .english)
        #expect(english.count >= 75)
        for language in AppLanguage.allCases where language != .system {
            let catalog = localization.catalog(for: language)
            #expect(Set(catalog.keys) == Set(english.keys))
            for (key, source) in english {
                let translated = catalog[key] ?? ""
                #expect(!translated.isEmpty)
                #expect(translated.components(separatedBy: "%@").count == source.components(separatedBy: "%@").count)
                #expect(Localization(language: language).text(key) == translated)
            }
        }
    }

    /// The interface names no trademark of another company's products.
    @Test func noMicrosoftOrWindowsNamesInAnyLanguage() {
        let localization = Localization(language: .english)
        for language in AppLanguage.allCases where language != .system {
            let named = localization.catalog(for: language).filter {
                $0.value.localizedCaseInsensitiveContains("windows") || $0.value.localizedCaseInsensitiveContains("microsoft")
            }
            #expect(named.isEmpty, "\(language.rawValue): \(named.keys.sorted())")
        }
    }

    @Test func systemMatchesVariantsAndFallsBackToEnglish() {
        #expect(AppLanguage.resolve(["pt-PT"]) == .portuguese)
        #expect(AppLanguage.resolve(["en-GB"]) == .english)
        #expect(AppLanguage.resolve(["zh-Hant", "fr_CA"]) == .french)
        #expect(AppLanguage.resolve(["zh-Hant"]) == .english)
        #expect(Localization(language: .system, preferredLanguages: ["ja-JP"]).text("column.name") == "名前")
    }

    @Test func countsAndFormatsUseSelectedLanguage() {
        let english = Localization(language: .english), portuguese = Localization(language: .portuguese)
        #expect(english.itemCount(0) == "0 items")
        #expect(english.itemCount(1) == "1 item")
        #expect(english.itemCount(2) == "2 items")
        #expect(portuguese.itemCount(0) == "0 item")
        #expect(Localization(language: .french).pluralCategory(0) == "one")
        for language in [AppLanguage.japanese, .korean] {
            for count in [0, 1, 2] { #expect(Localization(language: language).pluralCategory(count) == "other") }
        }
        #expect(english.listingStatus(visible: 1, total: 2, filtered: true, selected: 1) == "1 of 2 items • 1 selected")
        #expect(english.number(1234) == "1,234")
        #expect(portuguese.number(1234) == "1.234")
        #expect(english.date(Date(timeIntervalSince1970: 1_700_000_000)) != portuguese.date(Date(timeIntervalSince1970: 1_700_000_000)))
        for language in AppLanguage.allCases where language != .system {
            let localization = Localization(language: language)
            #expect(!localization.bytes(123456).isEmpty)
            #expect(!localization.listingStatus(visible: 0, total: 3, filtered: true, selected: 0).contains("%@"))
        }
    }

    @Test @MainActor func languagePreferenceSurvivesRecreation() {
        let name = "MyExplorer.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LanguagePreferences(defaults: defaults).selection == .system)
        LanguagePreferences(defaults: defaults).select(.korean)
        #expect(LanguagePreferences(defaults: defaults).selection == .korean)
        LanguagePreferences(defaults: defaults).select(.system)
        #expect(LanguagePreferences(defaults: defaults).selection == .system)
    }
}
