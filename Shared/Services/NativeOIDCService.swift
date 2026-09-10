//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS) || os(macOS)
import AuthenticationServices
import CryptoKit
import Foundation
import Get
import JellyfinAPI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class NativeOIDCService: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum Error: Swift.Error {
        case invalidStartURL
        case invalidCallback
        case stateMismatch
        case missingCode
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

    static let shared = NativeOIDCService()

    private var authenticationSession: ASWebAuthenticationSession?

    override private init() {}

    func authenticate(
        server: ServerState,
        provider: String
    ) async throws -> AuthenticationResult {
        guard provider.isEmpty == false else {
            throw Error.unsupportedProvider
        }

        let state = Self.randomString(length: 32)
        let verifier = Self.randomString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var startComponents = URLComponents(
            url: server.effectiveServerURL.appendingPathComponent("sso/OID/native/start/\(provider)"),
            resolvingAgainstBaseURL: false
        )
        startComponents?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]

        guard let startURL = startComponents?.url else {
            throw Error.invalidStartURL
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Swift.Error>) in
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: "swiftfin"
            ) { [weak self] url, error in
                self?.authenticationSession = nil

                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: Error.invalidCallback)
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session

            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: Error.invalidStartURL)
                return
            }
        }

        guard let callbackComponents = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ),
            callbackComponents.scheme == "swiftfin",
            callbackComponents.host == "auth",
            callbackComponents.path == "/callback"
        else {
            throw Error.invalidCallback
        }

        var callbackQuery = [String: String]()
        for item in callbackComponents.queryItems ?? [] {
            guard callbackQuery[item.name] == nil, let value = item.value else {
                throw Error.invalidCallback
            }

            callbackQuery[item.name] = value
        }

        guard callbackQuery["state"] == state else {
            throw Error.stateMismatch
        }

        guard let code = callbackQuery["code"], code.isEmpty == false else {
            throw Error.missingCode
        }

        let request = Request<AuthenticationResult>(
            path: "sso/OID/native/Auth/\(provider)",
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

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow(frame: .zero)
        #elseif os(macOS)
        NSApplication.shared.keyWindow ?? NSWindow()
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
        Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: ["="])
    }
}
#else
import Foundation
import JellyfinAPI

@MainActor
final class NativeOIDCService {
    static let shared = NativeOIDCService()

    private init() {}

    func authenticate(server: ServerState, provider: String) async throws -> AuthenticationResult {
        throw URLError(.unsupportedURL)
    }
}
#endif
