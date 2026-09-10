//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Swiftfin presentation for an OIDC provider it recognizes by name.
///
/// Sign in is identical for every OIDC provider: the server's SSO plugin drives
/// the exchange and Swiftfin only carries PKCE state and the fixed callback. An
/// adapter therefore adds branding and ordering, never behavior - a provider
/// without an adapter still signs in, presented by its server-configured name.
///
/// Supporting another provider is a new constant plus an `allCases` entry.
struct OIDCProviderAdapter: Identifiable, Hashable {

    /// Stable Swiftfin identifier for this adapter.
    let id: String

    let displayTitle: String

    let systemImage: String

    /// Lowercased server provider names this adapter claims.
    let providerNames: Set<String>
}

extension OIDCProviderAdapter {

    /// Tailscale's `tsidp` identity provider.
    static let tailscale = OIDCProviderAdapter(
        id: "tailscale",
        displayTitle: "Tailscale",
        systemImage: "network.badge.shield.half.filled",
        providerNames: ["tsidp", "tailscale"]
    )

    /// Every adapter, in the order that adapted providers are offered.
    static let allCases: [OIDCProviderAdapter] = [.tailscale]

    /// The adapter claiming `providerName`, or `nil` when Swiftfin has none.
    static func adapter(for providerName: String) -> OIDCProviderAdapter? {
        let providerName = providerName.lowercased()

        return allCases.first { $0.providerNames.contains(providerName) }
    }
}
