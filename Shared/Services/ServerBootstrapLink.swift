//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

struct ServerBootstrapLink: Equatable {
    let serverURL: URL
    let provider: String?

    init?(_ url: URL) {
        guard ["swiftfin", "jellyfin"].contains(url.scheme?.lowercased()),
              ["server", "connect"].contains(url.host?.lowercased())
        else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let serverURLString = components?.queryItems?.first(where: { $0.name == "url" })?.value,
              let serverURL = URL(string: serverURLString),
              ["http", "https"].contains(serverURL.scheme?.lowercased()),
              serverURL.host != nil
        else { return nil }

        if let provider = components?.queryItems?.first(where: { $0.name == "provider" })?.value,
           !provider.isEmpty,
           provider.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        {
            self.provider = provider
        } else {
            self.provider = nil
        }

        self.serverURL = serverURL
    }
}
