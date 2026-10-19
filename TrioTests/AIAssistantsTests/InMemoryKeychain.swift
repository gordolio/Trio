import Foundation

@testable import Trio

/// A dictionary-backed `Keychain` for tests.
final class InMemoryKeychain: Keychain {
    private(set) var storage: [String: Data] = [:]

    func allKeys() -> Set<String> { Set(storage.keys) }

    func hasValue(forKey key: String) -> Result<Bool, KeychainError> { .success(storage[key] != nil) }

    func accessibilityOfKey(_: String) -> Result<KeychainItemAccessibility, KeychainError> { .success(.afterFirstUnlock) }

    func getData(forKey key: String) -> Result<Data?, KeychainError> { .success(storage[key]) }

    func getValue<T: Decodable>(_: T.Type, forKey key: String) -> Result<T?, KeychainError> {
        guard let data = storage[key] else { return .success(nil) }
        do {
            return try .success(JSONDecoder().decode([T].self, from: data).first)
        } catch {
            return .failure(.codingError(error))
        }
    }

    @discardableResult func setData(_ value: Data, forKey key: String) -> Result<Void, KeychainError> {
        storage[key] = value
        return .success(())
    }

    @discardableResult func setValue<T: Encodable>(_ maybeValue: T?, forKey key: String) -> Result<Void, KeychainError> {
        guard let value = maybeValue else { return removeObject(forKey: key) }
        do {
            storage[key] = try JSONEncoder().encode([value])
            return .success(())
        } catch {
            return .failure(.codingError(error))
        }
    }

    @discardableResult func removeObject(forKey key: String) -> Result<Void, KeychainError> {
        storage[key] = nil
        return .success(())
    }

    @discardableResult func removeAllKeys() -> Result<Void, KeychainError> {
        storage = [:]
        return .success(())
    }

    static func wipeKeychain() {}

    func getValue<T: Codable>(_: T.Type, forKey key: String) -> T? {
        try? (getValue(T.self, forKey: key) as Result<T?, KeychainError>).get()
    }

    func getValue<T: Codable>(_: T.Type, forKey key: String, defaultValue: T?, reportError _: Bool) -> T? {
        let value: T? = getValue(T.self, forKey: key)
        return value ?? defaultValue
    }

    func setValue<T: Codable>(_ maybeValue: T?, forKey key: String) {
        _ = setValue(maybeValue, forKey: key) as Result<Void, KeychainError>
    }

    func setValue<T: Codable>(_ maybeValue: T?, forKey key: String, reportError _: Bool) {
        _ = setValue(maybeValue, forKey: key) as Result<Void, KeychainError>
    }
}
