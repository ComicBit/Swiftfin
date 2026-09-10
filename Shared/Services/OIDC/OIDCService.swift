//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CryptoKit
import Foundation
import Get
import JellyfinAPI
import Logging
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Native OIDC sign-in against a server's Jellyfin SSO plugin.
///
/// The flow is provider agnostic. Swiftfin asks the server which OIDC providers
/// are enabled, opens the server's start endpoint in a web authentication
/// session with a PKCE challenge, validates the fixed callback, then exchanges
/// the one-time server state for a normal Jellyfin `AuthenticationResult`.
/// Swiftfin never handles an OIDC token or a provider credential, so no
/// provider-specific code is required to sign in.
@MainActor
final class OIDCService {

    enum Error: Swift.Error {
        case invalidCallback
        case invalidStartURL
        case missingCode
        case notSupported
        case stateMismatch
        case unsupportedProvider
    }

    private struct AuthRequest: Encodable {

        let data: String
        let state: String
        let codeVerifier: String
        let deviceID: String
        let deviceName: String
        let appName: String
        let appVersion: String

        enum CodingKeys: String, CodingKey {
            case data = "Data"
            case state = "State"
            case codeVerifier = "CodeVerifier"
            case deviceID = "DeviceID"
            case deviceName = "DeviceName"
            case appName = "AppName"
            case appVersion = "AppVersion"
        }
    }

    /// The plugin's native bridge endpoints.
    private enum Path {
        static let providers = "sso/OID/native/providers"

        static func start(_ provider: OIDCProvider) -> String {
            "sso/OID/native/start/\(provider.name)"
        }

        static func auth(_ provider: OIDCProvider) -> String {
            "sso/OID/native/Auth/\(provider.name)"
        }
    }

    /// The fixed callback the plugin redirects to. Never carries a token.
    private enum Callback {
        static let scheme = "swiftfin"
        static let host = "auth"
        static let path = "/callback"
    }

    static let shared = OIDCService()

    /// Whether this platform can present a provider's web sign-in. Compile-time
    /// constant, so discovery and sign-in can be skipped before any isolation.
    nonisolated static var isSupported: Bool {
        #if os(iOS) || os(macOS)
        true
        #else
        false
        #endif
    }

    #if os(iOS) || os(macOS)
    private let webAuthentication = OIDCWebAuthenticationSession()
    #endif

    private let logger = Logger.swiftfin()

    private init() {}

    /// The OIDC providers enabled on `server`, adapted providers first.
    ///
    /// Empty when this platform cannot present web sign-in, or when the server
    /// has no SSO plugin exposing the native bridge.
    func providers(for server: ServerState) async -> [OIDCProvider] {
        guard Self.isSupported else { return [] }

        do {
            let request = Request<[String]>(path: Path.providers)
            let names = try await server.client.send(request).value

            var adapted: [OIDCProvider] = []
            var unadapted: [OIDCProvider] = []

            for name in names where name.isNotEmpty {
                let provider = OIDCProvider(name: name)

                if provider.adapter == nil {
                    unadapted.append(provider)
                } else {
                    adapted.append(provider)
                }
            }

            return adapted + unadapted
        } catch {
            logger.debug(
                "Unable to retrieve OIDC providers",
                metadata: ["error": .string(error.localizedDescription)]
            )

            return []
        }
    }

    /// Signs in through `provider` and returns the server's authentication result.
    func authenticate(
        server: ServerState,
        provider: OIDCProvider
    ) async throws -> AuthenticationResult {
        guard Self.isSupported else {
            throw Error.notSupported
        }

        guard provider.name.isNotEmpty else {
            throw Error.unsupportedProvider
        }

        let state = Self.randomString(length: 32)
        let verifier = Self.randomString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var startComponents = URLComponents(
            url: server.effectiveServerURL.appendingPathComponent(Path.start(provider)),
            resolvingAgainstBaseURL: false
        )
        startComponents?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]

        guard let startURL = startComponents?.url else {
            throw Error.invalidStartURL
        }

        let code = try await callbackCode(startingAt: startURL, state: state)

        let request = Request<AuthenticationResult>(
            path: Path.auth(provider),
            method: .post,
            body: AuthRequest(
                data: code,
                state: state,
                codeVerifier: verifier,
                deviceID: "\(UIDevice.platform)_\(UIDevice.vendorUUIDString)",
                deviceName: Self.deviceName,
                appName: "Swiftfin",
                appVersion: Self.appVersion
            )
        )

        return try await server.client.send(request).value
    }

    /// Presents the provider's web sign-in and returns the one-time server
    /// state from the validated callback.
    private func callbackCode(
        startingAt startURL: URL,
        state: String
    ) async throws -> String {
        #if os(iOS) || os(macOS)
        let callbackURL = try await webAuthentication.callbackURL(
            startingAt: startURL,
            callbackScheme: Callback.scheme
        )

        guard let components = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ),
            components.scheme == Callback.scheme,
            components.host == Callback.host,
            components.path == Callback.path
        else {
            throw Error.invalidCallback
        }

        var query = [String: String]()
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else {
                throw Error.invalidCallback
            }

            query[item.name] = value
        }

        guard query["state"] == state else {
            throw Error.stateMismatch
        }

        guard let code = query["code"], code.isNotEmpty else {
            throw Error.missingCode
        }

        return code
        #else
        throw Error.notSupported
        #endif
    }

    private static var deviceName: String {
        UIDevice.current.name
            .folding(options: .diacriticInsensitive, locale: .current)
            .unicodeScalars
            .filter { CharacterSet.urlQueryAllowed.contains($0) }
            .description
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.1"
    }

    private static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in
            alphabet[Int.random(in: alphabet.indices, using: &generator)]
        })
    }

    private static func base64URL(_ digest: Data) -> String {
        digest
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: ["="])
    }
}
