//
//  LocalizationTests.swift
//

import XCTest
@testable import MotionCues

final class LocalizationTests: XCTestCase {
    func testEnglishAndChineseDifferForChrome() {
        let en = L10n.t(.tabAppearance, .english)
        let zh = L10n.t(.tabAppearance, .chineseSimplified)
        XCTAssertEqual(en, "Appearance")
        XCTAssertEqual(zh, "外观")
        XCTAssertNotEqual(en, zh)
    }

    func testFormatArgsLocalize() {
        let en = L10n.t(.intensityFooter, .english, 900)
        let zh = L10n.t(.intensityFooter, .chineseSimplified, 900)
        XCTAssertTrue(en.contains("900"))
        XCTAssertTrue(zh.contains("900"))
        XCTAssertTrue(zh.contains("强度") || zh.contains("pt/s"))
    }

    func testEveryKeyHasEnglishAndChinese() {
        for key in L10n.Key.allCases {
            let en = L10n.t(key, .english)
            let zh = L10n.t(key, .chineseSimplified)
            XCTAssertFalse(en.isEmpty, "Empty English string for \(key)")
            XCTAssertFalse(zh.isEmpty, "Empty Chinese string for \(key)")
        }
    }

    func testCoreChromeIsTranslated() {
        XCTAssertEqual(L10n.t(.settingsEllipsis, .chineseSimplified), "设置…")
        XCTAssertEqual(L10n.t(.language, .chineseSimplified), "语言")
        XCTAssertEqual(L10n.t(.calibrate, .chineseSimplified), "校准")
        XCTAssertEqual(L10n.t(.startStreaming, .chineseSimplified), "开始推流")
    }

    @MainActor
    func testPreferredLanguagePersists() {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, .english)

        settings.language = .chineseSimplified
        XCTAssertEqual(defaults.string(forKey: AppLanguage.defaultsKey), "zh-Hans")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.language, .chineseSimplified)
    }

    func testIntensityNamesFollowLanguage() {
        XCTAssertEqual(CueIntensity.low.localizedName(.english), "Low")
        XCTAssertEqual(CueIntensity.low.localizedName(.chineseSimplified), "低")
    }
}
