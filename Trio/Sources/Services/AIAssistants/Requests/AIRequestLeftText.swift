import Foundation

/// The words a device's screen closes with when the request it has open leaves pending.
enum AIRequestLeftText {
    /// The headline for why the request left pending, and whether it went as the wearer asked. `source` is who asked,
    /// for example "ChatGPT".
    static func headline(for left: AIRequestLeft, source: String) -> (headline: String, isSuccess: Bool) {
        switch left {
        case .claimed(.watch):
            return (
                String(localized: "Logged on your watch", comment: "The request was carried out on the Apple Watch"),
                true
            )
        case .claimed(.phone):
            return (
                String(localized: "Logged on your iPhone", comment: "The request was carried out on the iPhone"),
                true
            )
        case .declined(.phone):
            return (
                String(localized: "Declined on your iPhone", comment: "The wearer declined the request on the iPhone"),
                false
            )
        case .declined(.dismissed),
             .declined(.watch):
            return (
                String(localized: "Declined on your watch", comment: "The wearer declined the request on the Apple Watch"),
                false
            )
        case .expired:
            return (String(localized: "Expired", comment: "The request wasn't answered in time"), false)
        case .withdrawn:
            return (
                String(
                    localized: "Canceled by \(source)",
                    comment: "The assistant canceled the request. The placeholder is the assistant's name"
                ),
                false
            )
        case .replaced:
            return (
                String(localized: "Replaced by a newer request", comment: "A newer request took this one's place"),
                false
            )
        }
    }
}
