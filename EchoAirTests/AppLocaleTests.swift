import XCTest
@testable import EchoAir

final class AppLocaleTests: XCTestCase {

    func testTagsMatchAndroidResourceQualifiers() {
        XCTAssertEqual(AppLocale.english.tag,  "en")
        XCTAssertEqual(AppLocale.spanish.tag,  "es")
        XCTAssertEqual(AppLocale.chinese.tag,  "zh")
        XCTAssertEqual(AppLocale.japanese.tag, "ja")
    }

    func testDisplayCodes() {
        XCTAssertEqual(AppLocale.english.displayCode,  "EN")
        XCTAssertEqual(AppLocale.spanish.displayCode,  "ES")
        XCTAssertEqual(AppLocale.chinese.displayCode,  "中")
        XCTAssertEqual(AppLocale.japanese.displayCode, "日")
    }

    func testNativeNameKey() {
        XCTAssertEqual(AppLocale.english.nativeNameKey,  "language_name_en")
        XCTAssertEqual(AppLocale.spanish.nativeNameKey,  "language_name_es")
        XCTAssertEqual(AppLocale.chinese.nativeNameKey,  "language_name_zh")
        XCTAssertEqual(AppLocale.japanese.nativeNameKey, "language_name_ja")
    }

    // MARK: - fromTag

    func testFromTagBareLanguage() {
        XCTAssertEqual(AppLocale.fromTag("en"), .english)
        XCTAssertEqual(AppLocale.fromTag("es"), .spanish)
        XCTAssertEqual(AppLocale.fromTag("zh"), .chinese)
        XCTAssertEqual(AppLocale.fromTag("ja"), .japanese)
    }

    func testFromTagNormalisesRegionVariants() {
        XCTAssertEqual(AppLocale.fromTag("en-US"),      .english)
        XCTAssertEqual(AppLocale.fromTag("es-MX"),      .spanish)
        XCTAssertEqual(AppLocale.fromTag("es-419"),     .spanish)   // LATAM
        XCTAssertEqual(AppLocale.fromTag("zh-Hans-CN"), .chinese)
        XCTAssertEqual(AppLocale.fromTag("zh-TW"),      .chinese)
        XCTAssertEqual(AppLocale.fromTag("ja-JP"),      .japanese)
    }

    func testFromTagCaseInsensitive() {
        XCTAssertEqual(AppLocale.fromTag("EN"),    .english)
        XCTAssertEqual(AppLocale.fromTag("Es-MX"), .spanish)
        XCTAssertEqual(AppLocale.fromTag("ZH"),    .chinese)
    }

    func testFromTagUnsupported() {
        XCTAssertNil(AppLocale.fromTag("fr"))
        XCTAssertNil(AppLocale.fromTag("de-DE"))
        XCTAssertNil(AppLocale.fromTag("pt-BR"))
        XCTAssertNil(AppLocale.fromTag(""))
        XCTAssertNil(AppLocale.fromTag(nil))
    }

    // MARK: - misc

    func testDefaultIsEnglish() {
        XCTAssertEqual(AppLocale.default, .english)
    }

    func testCaseIterationOrderMatchesPickerOrder() {
        // Order in the Kotlin enum drives picker order; mirror it.
        XCTAssertEqual(AppLocale.allCases, [.english, .spanish, .chinese, .japanese])
    }
}
