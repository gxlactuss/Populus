import Foundation

enum Format {
    /// Fixed so digits always group in threes, whatever the system region (e.g. not 28,31,874).
    private static let locale = Locale(identifier: "en_US")

    /// "2,831,874"
    static func integer(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.locale(locale))
    }

    /// "850,000", "12.5 million", "1.25 billion"
    static func people(_ v: Double) -> String {
        let sig = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3)).locale(locale)
        switch v {
        case 1e9...: return "\((v / 1e9).formatted(sig)) billion"
        case 1e6...: return "\((v / 1e6).formatted(sig)) million"
        default: return integer(v)
        }
    }

    /// "850K", "12.5M", "1.2B"
    static func compact(_ v: Double) -> String {
        let sig = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3)).locale(locale)
        switch v {
        case 1e9...: return "\((v / 1e9).formatted(sig))B"
        case 1e6...: return "\((v / 1e6).formatted(sig))M"
        case 1e3...: return "\((v / 1e3).formatted(sig))K"
        default: return integer(v)
        }
    }

    static func area(_ km2: Double) -> String {
        km2 < 10 ? "\(km2.formatted(.number.precision(.fractionLength(1)).locale(locale))) km²" : "\(integer(km2)) km²"
    }

    static func density(_ d: Double) -> String {
        "\(integer(d)) /km²"
    }

    /// "98.7%"
    static func accuracy(_ a: Double) -> String {
        "\((a * 100).formatted(.number.precision(.fractionLength(1)).locale(locale)))%"
    }

    static func percentOff(_ ratio: Double) -> String {
        let pct = Int(((ratio - 1) * 100).rounded())
        if pct == 0 { return "Spot on" }
        return pct > 0 ? "+\(integer(Double(pct)))%" : "\(integer(Double(pct)))%"
    }
}
