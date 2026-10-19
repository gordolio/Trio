import Foundation

enum AIAssistantsConfig {
    enum Config {}

    /// The account card's status line while linked.
    enum SharingStatus: Equatable {
        case sharing(lastUpload: Date)
        case waitingForFirstUpdate
        /// The last upload failed; `lastUpload` is the last one that worked.
        case failed(message: String, lastUpload: Date?)
    }
}
