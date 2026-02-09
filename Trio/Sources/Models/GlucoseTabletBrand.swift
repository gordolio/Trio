import Foundation

/// Represents different brands of glucose tablets for calibration testing
enum GlucoseTabletBrand: String, CaseIterable, Identifiable, Equatable {
    case dex4
    // Future brands can be added here:
    // case glucoseTabs
    case reliOn
    case trueplus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dex4:
            return "Dex4"
        case .reliOn:
            return "ReliOn"
        case .trueplus:
            return "TruePlus"
        }
    }

    /// Grams of carbohydrate per tablet
    var carbsPerTablet: Decimal {
        switch self {
        case .dex4:
            return 4 // 4g carbs per tablet
        case .reliOn:
            return 4 // 4g carbs per tablet
        case .trueplus:
            return 3.75 // 3g carbs per tablet
        }
    }

    /// Asset catalog image name for this brand
    var imageName: String {
        switch self {
        case .dex4:
            return "dex4_tablets"
        case .reliOn:
            return "relion_tablets"
        case .trueplus:
            return "trueplus_tablets"
        }
    }

    /// Recommended number of tablets for a calibration test
    var recommendedCount: Int {
        switch self {
        case .dex4:
            return 2 // 8g total
        case .reliOn:
            return 2 // 8g total
        case .trueplus:
            return 2 // 7.5g total
        }
    }

    /// Description of the tablet for UI display
    var description: String {
        switch self {
        case .dex4:
            return String(localized: "Fast-acting glucose tablets, 4g carbs each")
        case .reliOn:
            return String(localized: "ReliOn glucose tablets, 4g carbs each")
        case .trueplus:
            return String(localized: "TruePlus glucose tablets, 3.75g carbs each")
        }
    }

    /// Calculate total carbs for a given tablet count
    func totalCarbs(for count: Int) -> Decimal {
        carbsPerTablet * Decimal(count)
    }

    /// Calculate the bolus amount for a given tablet count and carb ratio
    func bolusAmount(for count: Int, carbRatio: Decimal) -> Decimal {
        guard carbRatio > 0 else { return 0 }
        return totalCarbs(for: count) / carbRatio
    }

    /// Create from raw value string, defaulting to dex4 if invalid
    static func from(_ rawValue: String) -> GlucoseTabletBrand {
        GlucoseTabletBrand(rawValue: rawValue) ?? .dex4
    }
}
