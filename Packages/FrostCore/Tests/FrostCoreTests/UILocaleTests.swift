import Testing
import Foundation
@testable import FrostCore

@Suite struct UILocaleTests {
    @Test func takesTheUILanguageAndKeepsTheRegion() {
        let locale = UILocale.make(uiLanguage: "zh-Hans", current: Locale(identifier: "en_US"))
        #expect(locale.language.languageCode == .chinese)
        #expect(locale.language.script == .hanSimplified)
        #expect(locale.region == .unitedStates)
    }

    @Test func keepsTheUsersOverrides() {
        // A 24-hour clock chosen in an English (US) region.
        let current = Locale(identifier: "en_US@hours=h23")
        let locale = UILocale.make(uiLanguage: "zh-Hans", current: current)
        #expect(locale.hourCycle == .zeroToTwentyThree)
        #expect(locale.language.languageCode == .chinese)
    }

    @Test func leavesTheLocaleAloneWhenTheLanguagesMatch() {
        let current = Locale(identifier: "en_GB")
        #expect(UILocale.make(uiLanguage: "en", current: current) == current)
        #expect(UILocale.make(uiLanguage: nil, current: current) == current)
    }

    @Test func relativeDatesUseTheUILanguage() {
        let formatter = DateFormatter()
        formatter.locale = UILocale.make(uiLanguage: "de", current: Locale(identifier: "en_US"))
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        #expect(formatter.string(from: Date()).contains("Heute"))
    }
}
