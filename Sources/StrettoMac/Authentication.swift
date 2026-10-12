import AppKit
import AuthenticationServices
import CryptoKit
import Security
import StrettoCore

enum SecretStore {
    private static let service = "dev.benkaiser.stretto-native-macos"
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure(status) }
        return data
    }
    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> StrettoError {
        .message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)")")
    }
}

@MainActor
final class BrowserAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var active = false
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StrettoError.message("Could not create a secure sign-in request.") }
        return Data(bytes).base64URLEncoded
    }
    func signIn(baseURL: URL, spotify: Bool = false) async throws -> (code: String, verifier: String, state: String) {
        guard !active else { throw StrettoError.message("A browser sign-in is already in progress.") }
        let verifier = try random()
        let state = try random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        guard var url = URLComponents(url: baseURL.appendingPathComponent(spotify ? "native/spotify/login" : "native/login"), resolvingAgainstBaseURL: false) else {
            throw StrettoError.message("Invalid authentication endpoint.")
        }
        url.queryItems = [.init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
        guard let startURL = url.url else { throw StrettoError.message("Invalid authentication URL.") }
        active = true
        defer { active = false; session = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: startURL, callbackURLScheme: "stretto-native") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: StrettoError.message("Sign-in completed without a callback.")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: StrettoError.message("macOS could not open the sign-in browser.")) }
        }
        guard callback.scheme == "stretto-native", callback.host == (spotify ? "spotify" : "auth"),
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw StrettoError.message("The sign-in callback did not match this request.")
        }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            throw StrettoError.message("Browser sign-in failed: \(error)")
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw StrettoError.message("No one-time sign-in code was returned.")
        }
        return (code, verifier, state)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
