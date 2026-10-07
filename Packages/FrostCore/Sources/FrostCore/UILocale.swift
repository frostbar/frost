import Foundation

/// The locale for text Frost formats itself (e.g. About's "Last checked" date): the language Frost's UI is shown in, with
/// the user's region and their overrides (calendar, 12 / 24-hour clock, first weekday).
///
/// `Locale.current` follows the system region's language, not the app's: with English as the region's language and
/// Frost's UI in Simplified Chinese, a relative date came out as "Today at 5:28 AM" inside a Chinese sentence.
public enum UILocale {
    /// `uiLanguage`: the localization the app runs in (`Bundle.main.preferredLocalizations.first`); nil keeps `current`.
    public static func make(uiLanguage: String?, current: Locale = .current) -> Locale {
        guard let uiLanguage, !uiLanguage.isEmpty else { return current }
        let language = Locale.Language(identifier: uiLanguage)
        guard language.languageCode != current.language.languageCode
                || language.script != current.language.script else { return current }
        var components = Locale.Components(locale: current)
        // The region is part of the language components: keep the user's.
        components.languageComponents = Locale.Language.Components(
            languageCode: language.languageCode, script: language.script,
            region: components.languageComponents.region ?? current.region)
        return Locale(components: components)
    }

    /// The UI locale of the running app.
    public static var app: Locale { make(uiLanguage: Bundle.main.preferredLocalizations.first) }
}
