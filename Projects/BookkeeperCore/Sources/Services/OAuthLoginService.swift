import Foundation

/// Handles OAuth authorization flows for Zoho:
/// - `login`: full browser-based consent flow for initial authentication
/// - `reauth`: refresh an existing token without opening the browser
public enum OAuthLoginService {

    public struct Tokens {
        public let accessToken: String
        public let refreshToken: String
    }

    /// Run the full OAuth login flow: open browser, wait for callback, exchange code, save tokens.
    public static func login(config: ZohoConfiguration, port: UInt16, configPath: String) async throws -> Tokens {
        let regionDomain = regionDomain(for: config.region)
        let redirectURI = "http://localhost:\(port)/callback"
        let tokenURL = "https://accounts.zoho.\(regionDomain)/oauth/v2/token"

        let authURL = buildAuthorizationURL(config: config, regionDomain: regionDomain, redirectURI: redirectURI)

        print("Starting OAuth login flow...")
        print()
        print("Make sure \(redirectURI) is registered as an")
        print("Authorized Redirect URI in your Zoho API Console.")
        print()
        print("Opening browser...")

        try openBrowser(url: authURL)

        print("Waiting for authorization callback on port \(port)...")
        print()

        let authCode = try await waitForAuthCallback(port: port)

        print("Received authorization code. Exchanging for tokens...")

        let tokens = try await exchangeCodeForTokens(
            code: authCode,
            clientId: config.clientId,
            clientSecret: config.clientSecret,
            redirectURI: redirectURI,
            tokenURL: tokenURL
        )

        try updateConfigFile(path: configPath, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)

        return tokens
    }

    /// Refresh the access token using the existing refresh token and save to config.json.
    public static func reauth(config: ZohoConfiguration, configPath: String) async throws -> Tokens {
        guard !config.refreshToken.isEmpty else {
            throw OAuthLoginError.tokenExchangeFailed("No refresh token in config. Run 'login' first.")
        }

        let regionDomain = regionDomain(for: config.region)
        let tokenURL = "https://accounts.zoho.\(regionDomain)/oauth/v2/token"

        print("Refreshing access token...")

        var components = URLComponents(string: tokenURL)!
        components.queryItems = [
            URLQueryItem(name: "refresh_token", value: config.refreshToken),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "client_secret", value: config.clientSecret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]

        guard let url = components.url else {
            throw OAuthLoginError.tokenExchangeFailed("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthLoginError.tokenExchangeFailed(body)
        }

        let json = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        let refreshToken = json.refreshToken ?? config.refreshToken
        let tokens = Tokens(accessToken: json.accessToken, refreshToken: refreshToken)

        try updateConfigFile(path: configPath, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)

        return tokens
    }

    // MARK: - Private

    private static func regionDomain(for region: String) -> String {
        switch region.lowercased() {
        case "eu": return "eu"
        case "in": return "in"
        case "au": return "com.au"
        default: return "com"
        }
    }

    private static func buildAuthorizationURL(config: ZohoConfiguration, regionDomain: String, redirectURI: String) -> URL {
        var components = URLComponents(string: "https://accounts.zoho.\(regionDomain)/oauth/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "scope", value: "ZohoBooks.fullaccess.all"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    private static func openBrowser(url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
    }

    private static func waitForAuthCallback(port: UInt16) async throws -> String {
        let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw OAuthLoginError.serverFailed("Could not create socket")
        }
        defer { close(serverSocket) }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw OAuthLoginError.serverFailed("Could not bind to port \(port)")
        }

        guard listen(serverSocket, 1) == 0 else {
            throw OAuthLoginError.serverFailed("Could not listen on port \(port)")
        }

        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else {
            throw OAuthLoginError.serverFailed("Could not accept connection")
        }
        defer { close(clientSocket) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        guard bytesRead > 0 else {
            throw OAuthLoginError.serverFailed("No data received")
        }

        let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        guard let requestLine = requestString.components(separatedBy: "\r\n").first,
              let urlPart = requestLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(urlPart)"),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            let errorHTML = """
                HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\
                <html><body><h1>Authorization Failed</h1><p>No authorization code received.</p></body></html>
                """
            _ = errorHTML.withCString { write(clientSocket, $0, strlen($0)) }
            throw OAuthLoginError.noCodeReceived
        }

        let successHTML = """
            HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\
            <html><body><h1>Authorization Successful!</h1>\
            <p>You can close this tab and return to the terminal.</p></body></html>
            """
        _ = successHTML.withCString { write(clientSocket, $0, strlen($0)) }

        return code
    }

    private static func exchangeCodeForTokens(
        code: String,
        clientId: String,
        clientSecret: String,
        redirectURI: String,
        tokenURL: String
    ) async throws -> Tokens {
        var components = URLComponents(string: tokenURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]

        guard let url = components.url else {
            throw OAuthLoginError.tokenExchangeFailed("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthLoginError.tokenExchangeFailed(body)
        }

        let json = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)

        guard let refreshToken = json.refreshToken else {
            throw OAuthLoginError.tokenExchangeFailed("No refresh token in response. Make sure access_type=offline and prompt=consent are set.")
        }

        return Tokens(accessToken: json.accessToken, refreshToken: refreshToken)
    }

    private static func updateConfigFile(path: String, accessToken: String, refreshToken: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)

        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var zoho = json["zoho"] as? [String: Any] else {
            throw OAuthLoginError.configUpdateFailed("Could not parse config.json")
        }

        if zoho["accessToken"] != nil {
            zoho["accessToken"] = accessToken
            zoho["refreshToken"] = refreshToken
        } else {
            zoho["access_token"] = accessToken
            zoho["refresh_token"] = refreshToken
        }

        json["zoho"] = zoho

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: fileURL)
    }
}

private struct TokenExchangeResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

public enum OAuthLoginError: LocalizedError {
    case serverFailed(String)
    case noCodeReceived
    case tokenExchangeFailed(String)
    case configUpdateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .serverFailed(let msg): return "Server error: \(msg)"
        case .noCodeReceived: return "No authorization code received from Zoho"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .configUpdateFailed(let msg): return "Config update failed: \(msg)"
        }
    }
}
