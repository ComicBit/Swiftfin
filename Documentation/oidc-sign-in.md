# Native OIDC sign-in

Swiftfin can sign in to a Jellyfin server through any OIDC provider that the
server's SSO plugin exposes over its native bridge. The flow is provider
agnostic: the server drives the OIDC exchange and returns a normal Jellyfin
`AuthenticationResult`. Swiftfin never handles an OIDC token, a client secret,
or a provider credential.

Tailscale's `tsidp` is the first provider Swiftfin ships an adapter for, and the
only one validated end to end so far — see
[Tailscale adapter research](tailscale-adapter-research.md). An adapter is
presentation only, so a server offering any other OIDC provider signs in today
without app changes.

## Flow

1. `GET /sso/OID/native/providers` lists the provider names enabled on the
   server. An error or an empty list means the server has no native bridge, and
   Swiftfin offers no OIDC sign-in.
2. `GET /sso/OID/native/start/{provider}?state=<client-state>&code_challenge=<S256>`
   is opened in an `ASWebAuthenticationSession`. The server validates the
   bounded client inputs, creates a short-lived transaction, and redirects to
   the provider.
3. The provider's callback returns to the server, which validates the OIDC code,
   issuer, audience, nonce, PKCE/state, and its configured role/claim policy.
4. The server redirects to the fixed `swiftfin://auth/callback` carrying a
   one-time opaque server state in `code` plus the original client state. No
   token is ever placed in the URL.
5. `POST /sso/OID/native/Auth/{provider}` sends that server state, the client
   state, the PKCE verifier, and the usual Jellyfin device metadata. It returns
   Jellyfin's `AuthenticationResult`, stored exactly like a username/password or
   Quick Connect sign-in.

Swiftfin rejects a callback whose scheme, host, path, or `state` does not match
what it started, or that repeats a query item.

`OIDCService` owns every step. `OIDCWebAuthenticationSession` presents the web
sign-in and only exists where `ASWebAuthenticationSession` does, so
`OIDCService.isSupported` is false on tvOS and no providers are discovered or
offered there.

## Adapter model

| Type | Responsibility |
| --- | --- |
| `OIDCProvider` | A provider advertised by a server: its server-configured `name`, plus the display title and system image resolved from its adapter. |
| `OIDCProviderAdapter` | Branding for a provider name Swiftfin recognizes. Adapters never change the sign-in flow. |

A provider with no adapter is still offered, presented by its server-configured
name with a generic key symbol. Adapted providers are listed first.

### Adding an adapter

1. Add a constant to `OIDCProviderAdapter` with a Swiftfin `id`, the
   `displayTitle` to show, a `systemImage`, and the lowercased server provider
   names it claims.
2. Add that constant to `OIDCProviderAdapter.allCases`.

Nothing else changes: discovery, sign-in, and the sign-in UI read branding
through `OIDCProvider`.

## Bootstrap links

`swiftfin://server?url=...` and `jellyfin://connect?url=...` preseed the connect
flow with a server endpoint. An optional `provider=<name>` starts that provider's
sign-in as soon as the server's public identity is verified. `ServerBootstrapLink`
accepts only `http`/`https` server URLs and provider names of letters, digits,
`-`, and `_`.

A bootstrap link must never carry a Jellyfin access token, an OIDC token or
client secret, or a provider credential such as a Tailscale auth key. The server
URL and a provider name are sufficient, and both are safe to hand to a user.

## Server requirements

The native bridge is not part of Jellyfin core. A server owner must install and
configure an SSO plugin that exposes `sso/OID/native/*` and registers
`swiftfin://auth/callback` for its OIDC client. Without it, Swiftfin falls back
to username/password and Quick Connect, which need no server plugin.
