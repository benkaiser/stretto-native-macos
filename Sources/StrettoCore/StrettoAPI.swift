import Foundation

public protocol LibraryTransport: Sendable {
    func latestVersion() async throws -> Double
    func latestData() async throws -> Library
    func upload(_ library: Library) async throws -> Double
}

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == origin.scheme && url?.host == origin.host && url?.port == origin.port ? request : nil)
    }
}

public actor StrettoAPI: LibraryTransport {
    public let baseURL: URL
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage?
    private let decoder = JSONDecoder()
    public init(baseURL: URL = URL(string: "https://next.kaiserapps.com")!, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session { self.session = session; self.cookieStorage = session.configuration.httpCookieStorage }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpShouldSetCookies = true
            cookieStorage = config.httpCookieStorage
            self.session = URLSession(configuration: config, delegate: SameOriginRedirects(origin: baseURL), delegateQueue: nil)
        }
    }

    public func restoreCookies(_ data: Data) throws {
        let values = try decoder.decode([[String: String]].self, from: data)
        for value in values {
            let properties = Dictionary(uniqueKeysWithValues: value.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: properties),
                  cookie.domain == baseURL.host || cookie.domain == ".\(baseURL.host ?? "")",
                  cookie.isSecure else { throw StrettoError.message("The saved session cookie is invalid.") }
            cookieStorage?.setCookie(cookie)
        }
    }

    public func cookieData() throws -> Data {
        let cookies = cookieStorage?.cookies(for: baseURL) ?? []
        let values: [[String: String]] = cookies.map { cookie in
            var value = [HTTPCookiePropertyKey.name.rawValue: cookie.name, HTTPCookiePropertyKey.value.rawValue: cookie.value,
                         HTTPCookiePropertyKey.domain.rawValue: cookie.domain, HTTPCookiePropertyKey.path.rawValue: cookie.path,
                         HTTPCookiePropertyKey.secure.rawValue: "TRUE"]
            if let expires = cookie.expiresDate { value[HTTPCookiePropertyKey.expires.rawValue] = expires.description }
            return value
        }
        return try JSONEncoder().encode(values)
    }

    public func clearCookies() {
        for cookie in cookieStorage?.cookies ?? [] { cookieStorage?.deleteCookie(cookie) }
    }

    public func json(path: String, method: String = "GET", body: [String: JSONValue]? = nil) async throws -> JSONValue {
        let data = try await request(path: path, method: method, data: body.map { try JSONEncoder().encode($0) })
        if data.isEmpty { return .object([:]) }
        return try decoder.decode(JSONValue.self, from: data)
    }

    private func request(path: String, method: String = "GET", data: Data? = nil) async throws -> Data {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.scheme == baseURL.scheme else { throw StrettoError.message("Invalid Stretto API path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StrettoError.message("Stretto returned an invalid response.") }
        let object: [String: JSONValue]
        if let value = try? decoder.decode([String: JSONValue].self, from: responseData) { object = value } else { object = [:] }
        if object["error"]?.string == "version mismatch" { throw StrettoError.conflict }
        let message = object["errorMessage"]?.string ?? object["error"]?.string ?? object["message"]?.string
        if http.statusCode == 403 && path != "/login" && path != "/createaccount" { throw StrettoError.unauthenticated }
        guard (200..<300).contains(http.statusCode) else {
            throw StrettoError.message(message ?? "Stretto request failed (HTTP \(http.statusCode)).")
        }
        if object["success"]?.bool == false { throw StrettoError.message(message ?? "Stretto could not complete the request.") }
        return responseData
    }

    public func checkLogin() async throws -> String? {
        do {
            let data = try await request(path: "/checklogin", method: "POST")
            struct Response: Decodable { let loggedIn: Bool; let email: String? }
            let result = try decoder.decode(Response.self, from: data)
            return result.loggedIn ? result.email : nil
        } catch StrettoError.unauthenticated { return nil }
    }

    public func login(email: String, password: String, register: Bool = false) async throws {
        _ = try await json(path: register ? "/createaccount" : "/login", method: "POST",
                           body: ["email": .string(email), "password": .string(password)])
    }
    public func logout() async throws { _ = try await request(path: "/logout", method: "POST"); clearCookies() }
    public func forgotPassword(email: String) async throws {
        _ = try await json(path: "/forgotpassword", method: "POST", body: ["email": .string(email)])
    }
    public func completeReset(email: String, password: String, token: String) async throws {
        _ = try await json(path: "/completereset", method: "POST", body: ["email": .string(email), "password": .string(password), "token": .string(token)])
    }
    public func exchange(code: String, verifier: String, state: String, spotify: Bool = false) async throws -> JSONValue {
        try await json(path: spotify ? "/native/spotify/exchange" : "/native/exchange", method: "POST",
                       body: ["code": .string(code), "code_verifier": .string(verifier), "state": .string(state)])
    }
    public func configuration() async throws -> PublicConfiguration {
        try decoder.decode(PublicConfiguration.self, from: await request(path: "/native/config"))
    }
    public func latestVersion() async throws -> Double {
        struct Response: Decodable { let version: Double }
        return try decoder.decode(Response.self, from: await request(path: "/latestversion")).version
    }
    public func latestData() async throws -> Library { try decoder.decode(Library.self, from: await request(path: "/latestdata")) }
    public func upload(_ library: Library) async throws -> Double {
        struct Response: Decodable { let version: Double }
        return try decoder.decode(Response.self, from: await request(path: "/uploaddata", method: "POST", data: JSONEncoder().encode(library))).version
    }
    public func artists(path: String = "/artists/followed/raw") async throws -> [Artist] {
        try decoder.decode([Artist].self, from: await request(path: path))
    }
    public func follow(_ artist: Artist, remove: Bool = false) async throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(artist))
        _ = try await json(path: remove ? "/artists/unfollow" : "/artists/follow", method: "POST", body: ["artist": value])
    }
}
