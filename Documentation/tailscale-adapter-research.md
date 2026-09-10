# Tailscale adapter research: discovery and Jellyfin bootstrap

This is the evidence behind Swiftfin's first OIDC adapter. The provider-agnostic
architecture it produced is documented in [Native OIDC sign-in](oidc-sign-in.md);
everything below is specific to Tailscale and its `tsidp` identity provider.

**Status:** implementation complete for the selected bootstrap/native bridge path; the live bridge is deployed and smoke-tested.  
**Evidence date:** 2026-09-09.  
**Question:** Can Swiftfin automatically discover a Jellyfin server and a Tailscale `tsidp` instance for arbitrary users when the users' tailnets and DNS names differ, and what bootstrap/auth design is safe and implementable?

## Executive conclusion

**No—not for arbitrary users without bootstrap information and cooperation from the server/tailnet owner.** Jellyfin's built-in discovery is a UDP broadcast that is explicitly local-subnet-only. Tailscale MagicDNS resolves names for devices that the requesting node is already allowed to reach; it is not a public directory of every tailnet or a cross-tailnet discovery protocol. A node also belongs to only one tailnet at a time, and the installed Tailscale iOS client does not provide the Tailscale CLI. Tailscale's control-plane API can enumerate devices, but it requires privileged, secret-bearing credentials that must not be shipped in Swiftfin.

The implementable security boundary is therefore:

1. The server owner publishes or hands the user a stable HTTPS endpoint (a Tailscale FQDN, a normal DNS name, or a one-time bootstrap link/QR code).
2. The user independently joins or receives access to the relevant tailnet/machine, if the endpoint is tailnet-only.
3. Swiftfin validates Jellyfin's public server identity at that endpoint.
4. Swiftfin uses Jellyfin's existing authentication contract. Quick Connect is the native, passwordless option: an already-authenticated Jellyfin client authorizes a short code, and Swiftfin receives a Jellyfin access token.

`tsidp` can provide OIDC identity to an OIDC-capable application, but it is experimental and its OIDC/STS tokens are **not automatically Jellyfin access tokens**. Direct `tsidp` login in Swiftfin would require a Jellyfin OIDC-capable plugin or a trusted broker that maps OIDC identity to a Jellyfin session. Jellyfin's core API and the current Swiftfin code expose username/password and Quick Connect, not a generic OIDC-token-to-Jellyfin-token exchange.

## Facts from the repository (current Swiftfin behavior)

### Discovery is local Jellyfin UDP broadcast

* The Swiftfin connection screen repeatedly calls `JellyfinClient.discover()` and turns each returned server URL/name/ID into a `ServerState` (`Shared/ViewModels/ConnectToServerViewModel.swift:175-191`).
* Swiftfin's own connection documentation says automatic discovery uses UDP port `7359`, cannot change that port, and requires the server and device to be on the same network with mDNS/UDP broadcast available (`Documentation/common_issues.md:70-75`).
* Jellyfin's official networking documentation defines `7359/UDP` as **Client Discovery**, says the client sends a broadcast, and says the reply includes server name, IP address, and ID. The same document says these auto-discovery services do not work outside the local subnet: [Jellyfin Networking](https://jellyfin.org/docs/general/post-install/networking/#port-bindings).

**Implication:** Tailscale routing does not turn Jellyfin's LAN broadcast into cross-tailnet discovery. A Tailscale server may be reachable by unicast HTTP(S) while remaining invisible to `JellyfinClient.discover()`.

### Swiftfin's authenticated connection contract

* Manual onboarding normalizes the entered URL, sends `GET /System/Info/Public`, requires a server name and ID, follows a server redirect when appropriate, and stores the resulting URL/server identity (`Shared/ViewModels/ConnectToServerViewModel.swift:56-112`).
* Endpoint failover tests each stored URL by fetching public system information and rejects a response whose server ID does not match the stored server (`Shared/Services/ServerConnectionManager.swift:69-95,99-148`).
* The client configuration sends a Swiftfin client/device identity and an optional Jellyfin `accessToken` (`Shared/Extensions/JellyfinAPI/JellyfinClient.swift:18-41`).
* Username/password login calls the Jellyfin SDK's `signIn(username:password:)`, then requires `accessToken`, user data, user ID, and user name before storing the user. Quick Connect login calls `signIn(quickConnectSecret:)` and consumes the same resulting access-token shape. Both share one event path with OIDC sign-in (`Shared/ViewModels/UserSignInViewModel.swift`).
* Quick Connect UI displays the server-generated code and waits for the SDK's authenticated event (`Shared/Views/QuickConnectView.swift:12-75`).

### Existing deep links were not onboarding links

`DeepLink` accepts `swiftfin://` or `jellyfin://` URLs containing an existing `serverID`, `userID`, and item/library destination. It does **not** encode a server URL or a tailnet/`tsidp` endpoint (`Shared/Services/DeepLink.swift`). Before this feature, `UserSessionManager.handleOpenURL` only looked those IDs up in local storage and reported missing-server/missing-user errors.

**Implication:** the deep-link format could not bootstrap a first-time arbitrary server, so `ServerBootstrapLink` was added as a separate transport that `handleOpenURL` checks first (`Shared/Services/ServerBootstrapLink.swift`, `Shared/Services/UserSession/UserSessionManager.swift`).

## Tailscale facts

### Tailnets, users, and cross-tailnet access

* A tailnet is a private collection of users, devices, and resources. Devices receive Tailscale IP addresses and are connected according to tailnet access policy: [What is a tailnet?](https://tailscale.com/docs/concepts/tailnet).
* A node belongs to one tailnet at a time. A device can have registrations for multiple tailnets, but the user selects which tailnet is active; the active node has that tailnet's node key and access map: [Tailscale identity — switching between tailnets](https://tailscale.com/docs/concepts/tailscale-identity#switching-between-tailnets).
* An owner/admin/IT admin can invite an arbitrary user with a one-time URL. Unused invites expire after 30 days; accepting requires the user to sign in and download/use the Tailscale client: [Invite any user](https://tailscale.com/docs/features/sharing/how-to/invite-any-user).
* Device sharing is narrower than joining a tailnet: it exposes only the selected machine to the individual recipient, not the recipient's entire tailnet. Shared machines are quarantined by default, use a different IP in the recipient tailnet, and are reachable through their full FQDN: [Share your machines with other users](https://tailscale.com/docs/features/sharing).
* Cross-tailnet access is therefore an explicit owner-mediated relationship (invite or share), not an anonymous lookup. The sharing documentation says a machine-share link should be treated like a password because it grants access to a machine.

**What “arbitrary users” means here:** users can be from unrelated identity providers/tailnets, but they still need an owner-issued invite/share or a public endpoint. A user merely having the Tailscale app installed does not confer access to another tailnet.

### MagicDNS limitations

* MagicDNS automatically registers DNS names for devices **in your network**. A device's FQDN is its machine name plus the tailnet DNS name, for example `host.example.ts.net`: [MagicDNS](https://tailscale.com/docs/features/magicdns).
* A machine name is canonical within a Tailscale network and determines its MagicDNS URL. Renaming a machine changes the MagicDNS name: [Machine names](https://tailscale.com/docs/concepts/machine-names).
* Shared machines require the full FQDN; the short machine name is not available from the recipient tailnet. MagicDNS settings are per-tailnet, although a recipient can reach a shared machine's FQDN when permitted: [Sharing — MagicDNS](https://tailscale.com/docs/features/sharing#sharing-and-magicdns).
* Tailscale HTTPS also requires MagicDNS and publishes machine names in Certificate Transparency, so an owner should avoid sensitive machine names: [Enabling HTTPS](https://tailscale.com/docs/how-to/set-up-https-certificates).

**Result:** differing tailnet DNS names do not prevent access once the owner supplies the correct FQDN and Tailscale has granted access. They do prevent Swiftfin from deriving the remote FQDN from only the local tailnet context. MagicDNS is name resolution plus policy-gated reachability, not a global cross-tailnet directory.

### Tailscale Services and endpoints

* Tailscale Services publish an internal resource as a stable service name/TailVIP and route to one or more hosts, decoupling the service from a particular device: [Tailscale Services](https://tailscale.com/docs/features/tailscale-services).
* Defining a service requires an active tailnet and Owner/Admin/Network admin permissions. A service host must use a tag-based identity; a user-authenticated device cannot be a service host. The current service setup supports TCP endpoints, with admin approval or auto-approval before a host becomes active.
* A service is accessed through its MagicDNS name or IP only by users/devices with the necessary access permissions. Grants can target a service selector such as `svc:web-server`, and can constrain ports with `ip`: [Grants](https://tailscale.com/docs/features/access-control/grants).

**Security/design meaning:** a Tailscale Service is a useful owner-configured stable endpoint for Jellyfin, but its name is still inside the owner's tailnet access-control boundary. It does not solve first contact for a user who has no access to that tailnet, nor does it provide a public “find all Jellyfin services” registry.

### Tailscale API and local client capabilities

* The Tailscale API requires an access token generated by an Owner, Admin, IT admin, or Network admin. Generated API tokens are case-sensitive, expire in 1–90 days, and can be revoked: [Tailscale API — Authentication](https://tailscale.com/docs/reference/tailscale-api#authentication).
* OAuth clients are also admin-created credentials. Their scopes restrict API endpoints; for example, `devices:core` can read/write the device list. The OAuth client secret must be stored securely, and issued API access tokens expire after one hour: [OAuth clients](https://tailscale.com/docs/features/oauth-clients).
* The API documentation's examples include `GET /api/v2/tailnet/:tailnet/devices` for device enumeration, but obtaining that list still requires the API/OAuth credential and the corresponding tailnet permissions.
* The official CLI documentation explicitly says there is no CLI support for iOS or Android: [Tailscale CLI](https://tailscale.com/docs/reference/tailscale-cli#using-the-tailscale-cli). The official iOS installation flow is installing the app, approving a VPN configuration, enabling notifications, and logging in through a supported SSO identity provider: [Install Tailscale on iOS](https://tailscale.com/docs/install/ios).

**Security conclusion:** Swiftfin must not embed a tailnet API token, OAuth client secret, or reusable auth key. A backend broker could hold such a credential, but that broker becomes a new privileged control-plane component and must be operated by the tailnet owner. The installed Tailscale iOS app should be treated as providing network connectivity after the user authenticates it, not as a supported Swiftfin peer-enumeration API.

## `tsidp` OIDC facts

* `tsidp` is an **experimental** OIDC/OAuth server. An application performs OIDC discovery, redirects the user to `tsidp`, and `tsidp` uses Tailscale LocalAPI `whois` to identify the calling Tailscale user. It returns an OIDC ID token and access token; the application validates the ID-token signature and may call `userinfo`: [tsidp](https://tailscale.com/docs/features/tsidp#how-it-works).
* Deployment requires a tailnet, Owner/Admin/Network admin permissions, a tailnet device running `tsidp`, MagicDNS, HTTPS, and a policy-file application-capability grant. Admin UI and dynamic client registration are denied by default until a `tailscale.com/cap/tsidp` grant permits them: [tsidp prerequisites and capability grant](https://tailscale.com/docs/features/tsidp#prerequisites), [tsidp configuration](https://tailscale.com/docs/features/tsidp#configure-your-tailnet).
* The documented deployment uses a persistent state directory, a tailnet hostname such as `idp.<tailnet>.ts.net`, and an auth key or OAuth client secret to pre-approve the `tsidp` node. Without persistent state, dynamic OIDC clients and sessions are lost on restart: [tsidp deployment](https://tailscale.com/docs/features/tsidp#deploy-a-tsidp-instance), [tsidp configuration reference](https://tailscale.com/docs/reference/tsidp-configuration).
* An owner creates an OIDC client by registering redirect URIs and receives a client ID and secret. The secret is shown only at creation/regeneration time: [tsidp — Create an OIDC client](https://tailscale.com/docs/features/tsidp#create-an-oidc-client).
* `tsidp` has an optional STS mode for OAuth 2.0 Token Exchange (RFC 8693), disabled by default: [tsidp configuration flags](https://tailscale.com/docs/reference/tsidp-configuration#tsidp-configuration-flags).

**Important boundary:** the documented `tsidp` flow yields OIDC/OAuth assertions for an OIDC-capable relying application. It does not state that a Jellyfin access token is produced. The Jellyfin core API's authentication result has an `AccessToken`, `User`, `SessionInfo`, and `ServerId`, but those are returned by Jellyfin's own authentication endpoints: [Jellyfin `AuthenticationResult`](https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Controller/Authentication/AuthenticationResult.cs). A `tsidp` ID/access token therefore cannot be sent to Swiftfin as if it were a Jellyfin access token without an explicit Jellyfin plugin/broker integration.

## Jellyfin authentication facts

### Core username/password and token response

Jellyfin's official controller exposes `POST /Users/AuthenticateByName`. It reads client/device metadata, calls `AuthenticateNewSession`, and returns an `AuthenticationResult` containing the Jellyfin access token and user/session/server information. The same controller exposes `POST /Users/AuthenticateWithQuickConnect`, which calls the Quick Connect manager and returns its authorized authentication result: [Jellyfin `UserController`](https://raw.githubusercontent.com/jellyfin/jellyfin/master/Jellyfin.Api/Controllers/UserController.cs).

The official OpenAPI document is available at [Jellyfin stable OpenAPI](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json). Its security definitions distinguish Jellyfin `CustomAuthentication` from the public discovery endpoints; a third-party OIDC token is not implicitly one of those Jellyfin credentials.

### Quick Connect

* Jellyfin's official documentation describes Quick Connect as a temporary code that lets a new client sign in without entering a username/password. Device A displays a six-character code; an already-authenticated Device B enters and authorizes it: [Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/).
* The server controller exposes `GET QuickConnect/Enabled`, `POST QuickConnect/Initiate`, `GET QuickConnect/Connect?secret=...`, and authenticated `POST QuickConnect/Authorize?code=...&userId=...`: [Jellyfin `QuickConnectController`](https://raw.githubusercontent.com/jellyfin/jellyfin/master/Jellyfin.Api/Controllers/QuickConnectController.cs).
* Jellyfin's `QuickConnectResult` contains a secret, six-character user-facing code, request metadata, and an `Authenticated` state: [QuickConnectResult](https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Model/QuickConnect/QuickConnectResult.cs). The controller's `AuthenticateWithQuickConnect` returns the authorized request's Jellyfin `AuthenticationResult`.
* The official documentation lists Swiftfin iOS as supporting both Quick Connect login and authorization. This matches the current Swiftfin code paths above.

### OIDC plugins and the native-client gap

Jellyfin supports optional plugins, including an **Authentication** category. Its official plugin documentation lists LDAP as an authentication provider and explains that plugins are server-installed extensions: [Jellyfin Plugins](https://jellyfin.org/docs/general/server/plugins/). The evidence in this note does not establish an official Jellyfin-core OIDC endpoint or a stable official plugin contract that turns a `tsidp` token into a native client access token.

Therefore:

* Browser SSO through an OIDC plugin/proxy may authenticate a browser session, but it is not automatically the same as Swiftfin's Jellyfin `AccessToken`.
* A Jellyfin OIDC plugin or broker would need to validate issuer/audience/signature/nonce/PKCE as appropriate, map the OIDC subject to a Jellyfin user, and deliberately issue or obtain a Jellyfin session token. That is a server-side integration decision, not something Swiftfin can infer from Tailscale DNS.
* If the server owner does not install/configure such an integration, Quick Connect remains the supported cross-device bootstrap path.

## QR codes, deep links, and bootstrap information

### Facts

* The current Swiftfin deep-link parser requires an existing server ID and user ID, and routes only to a media destination (`Shared/Services/DeepLink.swift:11-33`).
* The URL handler resolves a bootstrap link first, and otherwise looks those IDs up in local storage and rejects missing server/user records (`Shared/Services/UserSession/UserSessionManager.swift`).
* Tailscale user invites and machine-share links are owner-generated, expiring access artifacts. Tailscale says share links should be treated like passwords: [Sharing](https://tailscale.com/docs/features/sharing), [Invite any user](https://tailscale.com/docs/features/sharing/how-to/invite-any-user).

### Recommendation

A future QR/deep-link bootstrap should carry the least privilege needed to start onboarding, for example:

```text
https://swiftfin.example/bootstrap?v=1&server=https%3A%2F%2Fjellyfin.example%2F&serverId=<expected-id>&nonce=<one-time-value>
```

The link should not contain a Jellyfin access token, Tailscale API credential, OAuth client secret, or reusable Tailscale auth key. Swiftfin should fetch public system information over HTTPS, compare the returned server ID with the expected value when present, then invoke Quick Connect or normal Jellyfin login. If a tailnet invite/share is needed, it should be a separate owner-issued flow opened in the Tailscale app/browser, not a secret silently embedded in a QR code.

## What is impossible without user-provided/bootstrap information

1. **Discovering an unknown Jellyfin server across arbitrary tailnets via Jellyfin discovery:** impossible by design; UDP/7359 broadcast is local-subnet-only.
2. **Deriving a remote tailnet's DNS suffix from the local Tailscale app state:** not supported. MagicDNS names encode the owning tailnet's DNS name, and the iOS app documentation does not expose a Swiftfin-readable peer/service directory.
3. **Enumerating all peers/services with no owner credential:** impossible through the Tailscale API. Device enumeration requires a privileged API/OAuth credential; putting one in a client would disclose control-plane authority.
4. **Reaching a tailnet-only `tsidp` from an unconnected user:** impossible until the user joins/is invited to the relevant tailnet or receives an explicitly shared/public endpoint and the network policy allows access.
5. **Treating a `tsidp` ID/access token as a Jellyfin API token:** unsupported by the documented Jellyfin core API. A server-side OIDC plugin/broker must perform the mapping, or the user must use Jellyfin's own login/Quick Connect.
6. **Using Swiftfin's existing deep-link format to add a first-time server:** impossible; it requires a stored `serverID` and `userID` and has no server URL bootstrap field.
7. **Guaranteeing one URL for all tailnets without an owner-controlled rendezvous:** impossible. The alternatives are user-provided endpoint/QR, owner-issued tailnet access, a publicly reachable DNS endpoint, or a privileged broker.

## Architecture options (ranked)

Scores are relative: **5 = strongest/best**. “Feasibility” includes compatibility with current Swiftfin/Jellyfin behavior and required server changes; “security” assumes the stated deployment is followed.

| Rank | Architecture | Feasibility | Security | Required bootstrap/owner work | Main risks/limitations |
| --- | --- | ---: | ---: | --- | --- |
| **1** | **Explicit HTTPS endpoint + Jellyfin Quick Connect** | **5/5** | **5/5** | Owner gives the user a stable HTTPS URL (normal DNS or tailnet FQDN). User reaches it, Swiftfin verifies `/System/Info/Public`, then displays/polls Quick Connect; an already-authenticated Jellyfin device authorizes the code. | Still requires the user to receive the endpoint and have network reachability. Quick Connect must be enabled and the user must control an already-authenticated device. |
| **2** | **Owner-issued Tailscale invite/share + QR containing the FQDN** | **4/5** | **5/5** | Owner invites the user to the tailnet or shares only the Jellyfin host; user installs/logs into Tailscale and accepts. QR/deep link carries the exact FQDN and optional expected Jellyfin server ID. | Owner approval and Tailscale installation are unavoidable. Shared machines have restricted cross-tailnet semantics and full-FQDN requirements. Swiftfin should not attempt to manage Tailscale account state. |
| **3** | **`tsidp` OIDC plus a Jellyfin OIDC plugin or owner broker** | **2/5** | **4/5** if hardened | Owner runs experimental `tsidp`, enables MagicDNS/HTTPS, writes capability grants, registers an OIDC client, and installs/configures a Jellyfin OIDC integration that maps claims to Jellyfin users/tokens. Swiftfin needs a documented native-client callback/token contract; otherwise use Quick Connect after browser authentication. | `tsidp` is experimental; dynamic registration and admin UI are policy-gated; persistent state and client secrets are required. OIDC tokens are not Jellyfin access tokens by default. A plugin/broker expands the trusted computing base and may only support browser SSO. |
| **4** | **Owner-operated discovery broker using Tailscale API/OAuth** | **2/5** | **2/5** direct; **3/5** with a carefully isolated broker | Owner operates a service with narrowly scoped Tailscale OAuth/API credentials, enumerates approved devices/services, probes Jellyfin public info, and returns only an allowlisted endpoint plus expected server ID. Swiftfin authenticates to the broker with a short-lived user/bootstrap token. | Direct client API credentials are unacceptable. Even a broker is a privileged control-plane service, must protect/revoke credentials, must define tenant isolation and allowlists, and still cannot grant network reachability by itself. |
| **5** | **Public Tailscale Funnel/public DNS with automatic probing** | **3/5** for reachability | **1/5** by default | Owner exposes a public endpoint and gives Swiftfin a URL; optionally puts an auth gateway in front. | Public exposure changes the threat model, creates scanning/abuse risk, and does not solve Jellyfin user authentication. This is not a safe default for an app feature; use only with an owner-controlled hardened gateway and explicit opt-in. |

### Recommended cutover

1. Ship/standardize an explicit bootstrap input rather than claiming arbitrary automatic discovery. Accept a URL or QR/deep link containing a server endpoint and optional expected Jellyfin server ID.
2. Probe only that endpoint over HTTPS and preserve Swiftfin's existing server-ID verification and access-token storage model.
3. Offer Quick Connect as the default passwordless sign-in path. Keep username/password as the normal fallback.
4. Document that tailnet-only URLs require the user to be connected to the owner's tailnet or an explicitly shared machine. Do not silently assume that the Tailscale iOS app can enumerate peers.
5. Treat `tsidp` as an optional server-admin integration, not as a universal discovery mechanism. Require a separately documented Jellyfin plugin/broker contract before adding OIDC UI or token exchange.
6. Never embed Tailscale API tokens, OAuth client secrets, auth keys, Jellyfin access tokens, or long-lived invite secrets in Swiftfin or static QR codes.

## Live validation on the configured Jellyfin host

The configured server was probed over its existing HTTPS Tailscale hostname after a controlled
Community SSO binary replacement and Jellyfin restart:

* `GET /System/Info/Public` succeeds and returns the expected Jellyfin server identity.
* `GET /sso/OID/GetNames` returns `["tsidp"]`.
* `GET /sso/OID/native/providers` returns `["tsidp"]`.
* `GET /sso/OID/native/start/tsidp` returns `302` to the configured `tsidp` issuer with a
  server-side authorization-code + PKCE request.
* The complete native callback and exchange smoke test returned `swiftfin://auth/callback`, then
  `POST /sso/OID/native/Auth/tsidp` returned HTTP 200 with Jellyfin's normal
  `AuthenticationResult`. The temporary smoke session was logged out with HTTP 204.

Jellyfin logs confirm that the deployed `SSO-Auth` assembly loaded successfully alongside the
existing Community SSO dependencies. No OIDC client secret, access token, or Tailscale credential
was written to the repository or package.

### Implemented native bridge contract

The compatible Community SSO plugin source now contains an offline-built native bridge for the configured
`tsidp` provider. The bridge deliberately reuses the plugin's existing OIDC validation, role gates, identity
mapping, and Jellyfin session minting:

1. `GET /sso/OID/native/providers` returns enabled OpenID provider names. Swiftfin offers every returned provider, listing the ones it has an adapter for first.
2. `GET /sso/OID/native/start/{provider}?state=<client-state>&code_challenge=<S256>` validates the bounded
   client inputs, creates a short-lived server transaction, and redirects to the configured OIDC provider.
3. The current `tsidp` client callback remains `/sso/OID/redirect/{provider}`, so no additional redirect URI
   registration is required for the configured client. The existing callback validates the OIDC code, issuer,
   audience, nonce, PKCE/state, and configured role/claim policy through the plugin's normal pipeline.
4. A successful native callback redirects only to the fixed `swiftfin://auth/callback` URI with an opaque,
   one-time server state in `code` plus the original client state. It never places an OIDC token or Jellyfin
   access token in the URL.
5. `POST /sso/OID/native/Auth/{provider}` accepts the server state, client state, PKCE verifier, and existing
   Jellyfin device metadata. It atomically consumes the ready transaction and returns Jellyfin's normal
   `AuthenticationResult`.

Swiftfin now accepts owner-issued `swiftfin://server?url=...&provider=...` or
`jellyfin://connect?url=...&provider=...` bootstrap links, probes the supplied Jellyfin endpoint using its
existing server identity checks, discovers the native providers, opens `ASWebAuthenticationSession`, verifies
the fixed callback and state, and exchanges the one-time server state through the native endpoint. None of
those steps is Tailscale specific: `tsidp` is only the provider name this server advertises, and
`OIDCProviderAdapter.tailscale` supplies its display name and symbol. The native bridge uses S256 PKCE and
does not require a Tailscale API credential in Swiftfin.

The package targets Jellyfin 12 / .NET 10 and passed an offline `dotnet build` with zero warnings and
errors. The staged package was deployed into the existing
`Community SSO for Jellyfin_5.0.0.73` plugin directory after backing up the live directory:

```text
/tmp/community-sso-live-backup.tar.gz
SHA-256: 9e74e73373ffb25ef4237e254fed0f405f0aa1c35855965d8cae37f05f089398
```

Jellyfin was restarted only after the viewer confirmed the interruption was safe. The container is
healthy, and the plugin manager reports Community SSO loaded.

### Source for the live plugin behavior

* [SSO plugin OIDC challenge/callback](https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/main/SSO-Auth/Api/SSOController.cs)
* [SSO plugin browser credential handoff](https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/main/SSO-Auth/WebResponse.cs)
* [SSO plugin documented OIDC API](https://github.com/9p4/jellyfin-plugin-sso#openid)

## Source index

### Repository sources

* [Swiftfin local discovery and manual connection](../Shared/ViewModels/ConnectToServerViewModel.swift#L56-L112) and [discovery loop](../Shared/ViewModels/ConnectToServerViewModel.swift#L175-L191)
* [Swiftfin connection probing/server-ID check](../Shared/Services/ServerConnectionManager.swift#L69-L148)
* [Swiftfin client/device/access-token configuration](../Shared/Extensions/JellyfinAPI/JellyfinClient.swift#L18-L41)
* [Swiftfin sign-in paths](../Shared/ViewModels/UserSignInViewModel.swift) and [native OIDC service](../Shared/Services/OIDC/OIDCService.swift)
* [Swiftfin Quick Connect UI](../Shared/Views/QuickConnectView.swift#L12-L75)
* [Swiftfin deep-link parser](../Shared/Services/DeepLink.swift) and [bootstrap/deep-link URL handling](../Shared/Services/UserSession/UserSessionManager.swift)
* [Swiftfin local discovery limitations](../Documentation/common_issues.md#L70-L75)

### Official Tailscale sources

* [Install Tailscale on iOS](https://tailscale.com/docs/install/ios)
* [Tailscale CLI (no iOS/Android CLI)](https://tailscale.com/docs/reference/tailscale-cli#using-the-tailscale-cli)
* [What is a tailnet?](https://tailscale.com/docs/concepts/tailnet)
* [Tailscale identity](https://tailscale.com/docs/concepts/tailscale-identity)
* [MagicDNS](https://tailscale.com/docs/features/magicdns)
* [Machine names](https://tailscale.com/docs/concepts/machine-names)
* [Sharing machines across tailnets](https://tailscale.com/docs/features/sharing)
* [Invite any user](https://tailscale.com/docs/features/sharing/how-to/invite-any-user)
* [Tailscale Services](https://tailscale.com/docs/features/tailscale-services)
* [Grants](https://tailscale.com/docs/features/access-control/grants)
* [Tailscale API](https://tailscale.com/docs/reference/tailscale-api)
* [OAuth clients](https://tailscale.com/docs/features/oauth-clients)
* [tsidp](https://tailscale.com/docs/features/tsidp)
* [tsidp configuration](https://tailscale.com/docs/reference/tsidp-configuration)
* [Enabling HTTPS](https://tailscale.com/docs/how-to/set-up-https-certificates)

### Official Jellyfin sources

* [Jellyfin Networking](https://jellyfin.org/docs/general/post-install/networking/)
* [Jellyfin Quick Connect documentation](https://jellyfin.org/docs/general/server/quick-connect/)
* [Jellyfin Plugins](https://jellyfin.org/docs/general/server/plugins/)
* [Jellyfin UserController](https://raw.githubusercontent.com/jellyfin/jellyfin/master/Jellyfin.Api/Controllers/UserController.cs)
* [Jellyfin QuickConnectController](https://raw.githubusercontent.com/jellyfin/jellyfin/master/Jellyfin.Api/Controllers/QuickConnectController.cs)
* [Jellyfin QuickConnectResult](https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Model/QuickConnect/QuickConnectResult.cs)
* [Jellyfin IQuickConnect](https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Controller/QuickConnect/IQuickConnect.cs)
* [Jellyfin AuthenticationResult](https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Controller/Authentication/AuthenticationResult.cs)
* [Jellyfin stable OpenAPI](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json)
