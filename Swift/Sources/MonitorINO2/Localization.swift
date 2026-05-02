import Foundation

/// Localização inline pt/en — segue o idioma do sistema. Default: en.
enum L {
    static let isPT: Bool = {
        let code = Locale.current.language.languageCode?.identifier
        return code == "pt"
    }()

    static func t(_ en: String, _ pt: String) -> String {
        isPT ? pt : en
    }
}
