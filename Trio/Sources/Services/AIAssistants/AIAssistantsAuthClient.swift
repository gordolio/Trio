import AuthenticationServices
import Foundation

/// What Trio keeps from Sign in with Apple to sign in to the service.
struct AppleCredential: Equatable {
    let identityToken: String
    let rawNonce: String
    let givenName: String?
    let familyName: String?
}

/// The `trio-ios` OAuth tokens for the device API. Kept in the Keychain.
struct AIAssistantsTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

/// Who Trio signed in as, from the sign-in response. Kept in the Keychain to show in Settings.
struct AIAssistantsAccount: Codable, Equatable {
    let email: String?
    let name: String?
}

/// What `signIn` returns: the tokens, and the account if the service named it.
struct AIAssistantsSignIn: Equatable {
    let tokens: AIAssistantsTokens
    let account: AIAssistantsAccount?
}

enum AIAssistantsAuthError: Error, Equatable {
    case cancelled
    case appleFailed
    case notInvited
    case stateMismatch
    /// The authorize callback had no code; carries its `error` value.
    case missingCode(String?)
    case invalidGrant
    case http(Int)
    /// The phone is offline.
    case network
    /// The service couldn't be reached: unknown host, refused connection or a TLS failure.
    case unreachable
}

/// Signs Trio in to the trio-rc service, following the API contract's "Trio signs in with
/// native Sign in with Apple" steps: Apple identity token → Better Auth session → headless
/// OAuth authorize for the built-in `trio-ios` client → PKCE code exchange → sign the
/// temporary session out. Only the OAuth tokens outlive `signIn`.
final class AIAssistantsAuthClient {
    static let clientID = "trio-ios"
    static let redirectURI = "triomcp://oauth-callback"
    static let scope = "device offline_access"
    /// Tokens are refreshed this long before they expire.
    static let expiryMargin: TimeInterval = 60

    private let session: URLSession
    private let now: () -> Date

    init(session: URLSession = AIAssistantsAuthClient.makeSession(), now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    /// An ephemeral session that never stores or sends cookies: Better Auth rejects a
    /// cookie-bearing POST that has no Origin header.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    /// The device API resource every token request names (RFC 8707).
    static func resource(for baseURL: URL) -> String {
        baseURL.appendingPathComponent("api/v1").absoluteString
    }

    static func mapAppleError(_ error: Error) -> AIAssistantsAuthError {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            return .cancelled
        }
        return .appleFailed
    }

    // MARK: - Sign in

    func signIn(with credential: AppleCredential, baseURL: URL) async throws -> AIAssistantsSignIn {
        let (sessionToken, account) = try await createSession(credential, baseURL: baseURL)
        let pkce = PKCE.generate()
        let state = SecureRandom.base64URL(byteCount: 16)
        do {
            let code = try await authorize(sessionToken: sessionToken, pkce: pkce, state: state, baseURL: baseURL)
            let tokens = try await exchange(code: code, pkce: pkce, baseURL: baseURL)
            await signOut(sessionToken: sessionToken, baseURL: baseURL)
            return AIAssistantsSignIn(tokens: tokens, account: account)
        } catch {
            await signOut(sessionToken: sessionToken, baseURL: baseURL)
            throw error
        }
    }

    /// Contract step 2. Returns the Better Auth session token, and the account if the response
    /// names one.
    func createSession(
        _ credential: AppleCredential,
        baseURL: URL
    ) async throws -> (token: String, account: AIAssistantsAccount?) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/sign-in/social"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SocialSignInBody(credential))
        let (data, response) = try await send(request)
        try checkStatus(response, data)
        guard let body = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
            throw AIAssistantsAuthError.http(response.statusCode)
        }
        return (body.token, body.user?.account)
    }

    /// Contract step 3's URL.
    func authorizeURL(baseURL: URL, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/auth/oauth2/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "resource", value: Self.resource(for: baseURL)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "none")
        ]
        return components.url!
    }

    /// Contract step 3: authorize with the session as a bearer token. Nothing opens a
    /// browser; the callback URL comes back as JSON. Returns the code.
    func authorize(sessionToken: String, pkce: PKCE, state: String, baseURL: URL) async throws -> String {
        var request = URLRequest(url: authorizeURL(baseURL: baseURL, pkce: pkce, state: state))
        request.httpMethod = "GET"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        try checkStatus(response, data)
        guard let body = try? JSONDecoder().decode(AuthorizeResponse.self, from: data),
              let callback = URL(string: body.url)
        else {
            throw AIAssistantsAuthError.http(response.statusCode)
        }
        return try code(fromCallback: callback, expectedState: state)
    }

    func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else {
            throw AIAssistantsAuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw AIAssistantsAuthError.missingCode(value("error"))
        }
        return code
    }

    /// Contract step 4: exchange the code for tokens.
    func exchange(code: String, pkce: PKCE, baseURL: URL) async throws -> AIAssistantsTokens {
        let response = try await tokenRequest(baseURL: baseURL, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("client_id", Self.clientID),
            ("redirect_uri", Self.redirectURI),
            ("resource", Self.resource(for: baseURL))
        ])
        guard let refreshToken = response.body.refresh_token else {
            throw AIAssistantsAuthError.http(response.status)
        }
        return tokens(from: response.body, refreshToken: refreshToken)
    }

    /// Contract step 5. Errors are ignored: the tokens don't depend on this session.
    func signOut(sessionToken: String, baseURL: URL) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/sign-out"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await send(request)
    }

    // MARK: - Refresh

    /// Refresh tokens rotate on every use; if the response has none, the old one is kept.
    func refresh(_ tokens: AIAssistantsTokens, baseURL: URL) async throws -> AIAssistantsTokens {
        let response = try await tokenRequest(baseURL: baseURL, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refreshToken),
            ("client_id", Self.clientID),
            ("resource", Self.resource(for: baseURL))
        ])
        return self.tokens(from: response.body, refreshToken: response.body.refresh_token ?? tokens.refreshToken)
    }

    // MARK: - Requests

    private func tokenRequest(baseURL: URL, fields: [(String, String)]) async throws -> (status: Int, body: TokenResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await send(request)
        if response.statusCode == 400, (try? JSONDecoder().decode(OAuthError.self, from: data))?.error == "invalid_grant" {
            throw AIAssistantsAuthError.invalidGrant
        }
        try checkStatus(response, data)
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AIAssistantsAuthError.http(response.statusCode)
        }
        return (response.statusCode, body)
    }

    private func tokens(from body: TokenResponse, refreshToken: String) -> AIAssistantsTokens {
        AIAssistantsTokens(
            accessToken: body.access_token,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(body.expires_in - Self.expiryMargin)
        )
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AIAssistantsAuthError.network
            }
            return (data, response)
        } catch let error as URLError {
            throw Self.offlineCodes.contains(error.code) ? AIAssistantsAuthError.network : AIAssistantsAuthError.unreachable
        }
    }

    /// Errors that mean the phone has no usable connection; anything else points at the address.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .internationalRoamingOff,
        .callIsActive,
        .timedOut
    ]

    private func checkStatus(_ response: HTTPURLResponse, _ data: Data) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        if response.statusCode == 403,
           (try? JSONDecoder().decode(BetterAuthError.self, from: data))?.code == "not_invited"
        {
            throw AIAssistantsAuthError.notInvited
        }
        throw AIAssistantsAuthError.http(response.statusCode)
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// `application/x-www-form-urlencoded`, percent-encoding everything but unreserved characters.
    static func formBody(_ fields: [(String, String)]) -> Data {
        let pairs = fields.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? name
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
            return "\(encodedName)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

// MARK: - Wire types

private struct SocialSignInBody: Encodable {
    struct IDToken: Encodable {
        let token: String
        let nonce: String
        let user: User?
    }

    struct User: Encodable {
        let name: Name
    }

    struct Name: Encodable {
        let firstName: String?
        let lastName: String?
    }

    let provider = "apple"
    let idToken: IDToken

    /// `user` is sent only when Apple returned a name, which it does on the first sign-in only.
    init(_ credential: AppleCredential) {
        let user = credential.givenName == nil && credential.familyName == nil
            ? nil
            : User(name: Name(firstName: credential.givenName, lastName: credential.familyName))
        idToken = IDToken(token: credential.identityToken, nonce: credential.rawNonce, user: user)
    }
}

private struct SessionResponse: Decodable {
    struct User: Decodable {
        let email: String?
        let name: String?

        /// Trimmed, with empty values left out; `nil` if neither is left.
        var account: AIAssistantsAccount? {
            func clean(_ value: String?) -> String? {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            let email = clean(email), name = clean(name)
            return email == nil && name == nil ? nil : AIAssistantsAccount(email: email, name: name)
        }
    }

    enum CodingKeys: String, CodingKey {
        case token
        case user
    }

    let token: String
    let user: User?

    /// A `user` that doesn't decode is left out: the account is only shown, never needed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        user = try? container.decodeIfPresent(User.self, forKey: .user)
    }
}

private struct AuthorizeResponse: Decodable {
    let url: String
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: TimeInterval
    let refresh_token: String?
}

private struct OAuthError: Decodable {
    let error: String
}

private struct BetterAuthError: Decodable {
    let code: String?
}
