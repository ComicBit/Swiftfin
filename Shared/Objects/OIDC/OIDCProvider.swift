//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// An OIDC provider offered by a server's Jellyfin SSO plugin.
struct OIDCProvider: Identifiable, Hashable, Displayable, SystemImageable {

    /// System image for a provider without an adapter.
    private static let genericSystemImage = "person.badge.key.fill"

    /// The provider name as configured on the server, used verbatim in the
    /// plugin's native sign-in paths.
    let name: String

    /// The adapter recognizing `name`, or `nil` when Swiftfin has no branding
    /// for this provider.
    let adapter: OIDCProviderAdapter?

    var id: String {
        name
    }

    var displayTitle: String {
        adapter?.displayTitle ?? name
    }

    var systemImage: String {
        adapter?.systemImage ?? Self.genericSystemImage
    }

    init(name: String) {
        self.name = name
        self.adapter = OIDCProviderAdapter.adapter(for: name)
    }
}
