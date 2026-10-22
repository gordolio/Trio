import Combine
import Foundation
import Testing

@testable import Trio

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
}

@Suite("AI Assistants preferences") struct AIAssistantsPreferencesTests {
    @Test func defaults() {
        let p = AIAssistantsPreferencesStore(defaults: freshDefaults()).value
        #expect(p == AIAssistantsPreferences(allowsMealRequests: false, phoneBackupDelay: 15, wakePushType: .passive))
    }

    @Test func roundTripsAndPublishes() {
        let store = AIAssistantsPreferencesStore(defaults: freshDefaults())
        var seen: [AIAssistantsPreferences] = []
        let c = store.changes.sink { seen.append($0) }
        store.value.phoneBackupDelay = 60
        #expect(AIAssistantsPreferencesStore(defaults: store.defaultsForTests).value.phoneBackupDelay == 60)
        #expect(seen.last?.phoneBackupDelay == 60)
        _ = c
    }

    @Test func mealRequestsAreOffUntilTurnedOn() {
        let store = AIAssistantsPreferencesStore(defaults: freshDefaults())
        #expect(!store.value.allowsMealRequests)
        store.value.allowsMealRequests = true
        #expect(store.defaultsForTests.bool(forKey: "AIAssistants.allowsMealRequests"))
        #expect(AIAssistantsPreferencesStore(defaults: store.defaultsForTests).value.allowsMealRequests)
    }

    @Test func unknownDelayReadsAsDefault() {
        let d = freshDefaults()
        d.set(45.0, forKey: "AIAssistants.phoneBackupDelay")
        #expect(AIAssistantsPreferencesStore(defaults: d).value.phoneBackupDelay == 15)
    }

    @Test func oldPreferencesStillDecode() {
        // A build that had the approval style and the answer route saved them next to the ones that are left.
        let d = freshDefaults()
        d.set(true, forKey: "AIAssistants.allowsMealRequests")
        d.set(30.0, forKey: "AIAssistants.phoneBackupDelay")
        d.set("timeSensitive", forKey: "AIAssistants.wakePushType")
        d.set("oneGesture", forKey: "AIAssistants.approvalStyle")
        d.set("serviceOnly", forKey: "AIAssistants.answerRoute")
        #expect(AIAssistantsPreferencesStore(defaults: d).value == AIAssistantsPreferences(
            allowsMealRequests: true,
            phoneBackupDelay: 30,
            wakePushType: .timeSensitive
        ))
    }
}
