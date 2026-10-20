import Combine
import Foundation
import Testing

@testable import Trio

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
}

/// A keychain that lives in memory, for tests.
final class InMemoryAIRequestKeychain: AIRequestKeychain {
    private var items: [String: Data] = [:]
    /// When `true`, `set` changes nothing and reports failure.
    var failWrites = false

    func data(for account: String) -> Data? {
        items[account]
    }

    @discardableResult func set(_ data: Data?, for account: String) -> Bool {
        guard !failWrites else { return false }
        items[account] = data
        return true
    }
}

@Suite("AI Assistants preferences") struct AIAssistantsPreferencesTests {
    @Test func defaults() {
        let p = AIAssistantsPreferencesStore(defaults: freshDefaults()).value
        #expect(p == AIAssistantsPreferences(
            allowsMealRequests: false,
            approvalStyle: .twoStep,
            phoneBackupDelay: 15,
            answerRoute: .both,
            wakePushType: .passive
        ))
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

    @Test func keyRotationReplacesTheKey() {
        let keys = AIRequestKeyStore(keychain: InMemoryAIRequestKeychain())
        #expect(keys.current == nil)
        let first = keys.rotate()
        #expect(first?.count == 32 && keys.current == first)
        #expect(keys.rotate() != first)
    }

    @Test func failedKeyWriteKeepsTheOldKey() {
        let keychain = InMemoryAIRequestKeychain()
        let keys = AIRequestKeyStore(keychain: keychain)
        let first = keys.rotate()
        #expect(first != nil)
        keychain.failWrites = true
        #expect(keys.rotate() == nil)
        #expect(keys.current == first)
    }
}
