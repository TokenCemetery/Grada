import Foundation
import Security

/// Where the Garmin key is kept; tests use memory, since unsigned test builds can't use the Keychain.
protocol GarminKeyStoring {
    var key: String? { get }
    func save(_ key: String) throws
    func delete()
}

/// The user's Garmin Personal API key, in this iPhone's Keychain only: not synced through iCloud Keychain
/// and not restored to another device. Garmin's terms forbid sharing the key with anyone.
struct GarminKeyStore: GarminKeyStoring {
    var service = "Grada.GarminPersonalAPIKey"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    var key: String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Updates in place rather than deleting first, so a failed save keeps the key that was there.
    func save(_ key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            // Readable after the first unlock, so background refreshes work; never leaves this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Calls Garmin's Personal API with the user's own key: swaps the key for a 24-hour token, then reads with it.
/// The key and token are sent only to `host`, never logged, and never follow a redirect elsewhere.
final class GarminClient {
    nonisolated static let host = "personal.connectapi.garmin.com"

    enum Failure: LocalizedError, Equatable {
        case noKey, keyRejected, rateLimited, http(Int), notGarminToken

        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "No Garmin key is saved.")
            case .keyRejected: String(localized: "Garmin didn't accept the key. It may have expired or been deleted.")
            case .rateLimited: String(localized: "Garmin asked Grada to slow down. Grada will try again later.")
            case .http(let status): String(localized: "Garmin answered with HTTP \(status).")
            case .notGarminToken: String(localized: "Garmin's answer didn't contain a token.")
            }
        }
    }

    /// Sends a request and returns the body and HTTP response; replaced in tests.
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Garmin publishes no rate limits; after a 429 Grada waits this long before calling again.
    static let rateLimitPause: TimeInterval = 15 * 60

    private let key: () -> String?
    private let transport: Transport
    private var token: (value: String, expires: Date)?
    private var pausedUntil: Date?

    init(key: @escaping () -> String?, transport: @escaping Transport = GarminClient.send) {
        self.key = key
        self.transport = transport
    }

    /// Forgets the token, e.g. when the key changes.
    func reset() {
        token = nil
        pausedUntil = nil
    }

    /// Checks that Garmin accepts the key by getting a token with it.
    func verify() async throws {
        token = nil
        _ = try await validToken()
    }

    /// GETs `path` and returns the body, or nil when Garmin answers 204 No Content, as it does for HRV
    /// ranges without data. An expired token is replaced once.
    func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data? {
        for attempt in 0..<2 {
            var request = URLRequest(url: Self.url(path, query))
            request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport(request)
            switch response.statusCode {
            case 200: return data
            case 204: return nil
            case 401 where attempt == 0: token = nil
            // A data endpoint's 403 refuses that kind of data, not the key: a new key wouldn't help.
            case 403: throw Failure.http(403)
            default: try fail(response.statusCode)
            }
        }
        throw Failure.keyRejected
    }

    private func validToken() async throws -> String {
        if let pausedUntil, pausedUntil > .now { throw Failure.rateLimited }
        if let token, token.expires > .now { return token.value }
        guard let key = key(), !key.isEmpty else { throw Failure.noKey }
        var request = URLRequest(url: Self.url("/personalapitoken-service/personal-api/personal-api-key/token"))
        request.httpMethod = "POST"
        request.setValue("ApiKey \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { try fail(response.statusCode) }
        guard let value = Self.token(from: data) else { throw Failure.notGarminToken }
        // Tokens last 24 hours; renewing an hour early avoids one expiring mid-import.
        token = (value, Date.now.addingTimeInterval(23 * 3600))
        return value
    }

    private func fail(_ status: Int) throws -> Never {
        switch status {
        case 401, 403: throw Failure.keyRejected
        case 429:
            pausedUntil = Date.now.addingTimeInterval(Self.rateLimitPause)
            throw Failure.rateLimited
        default: throw Failure.http(status)
        }
    }

    /// The token endpoint answers with the bare JWT, not JSON. A JSON object with `access_token` is accepted
    /// too, in case Garmin changes that.
    nonisolated static func token(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let value = (object as? String) ?? (object as? [String: Any])?["access_token"] as? String
            return value.flatMap { $0.isEmpty ? nil : $0 }
        }
        return text.split(separator: ".").count == 3 ? text : nil
    }

    nonisolated static func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: GarminNoRedirects(), delegateQueue: nil)

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.http(0) }
        return (data, http)
    }
}

/// A redirect would carry the key or token to another host. The completion-handler form: Swift 6.4's compiler
/// crashes on the async form here.
private nonisolated final class GarminNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
