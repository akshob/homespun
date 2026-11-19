# Security

Report vulnerabilities through this repository's **Security → Report a vulnerability**
(GitHub private vulnerability reporting). Do not include tokens, private keys or personal
photos in a public issue.

## Connections and pairing

Homespun Server accepts only HTTPS, with TLS 1.2 or newer and forward-secret cipher suites.
The app pins SHA-256 of the server key's DER SubjectPublicKeyInfo, or uses system trust for
an HTTPS proxy with a publicly trusted certificate. It never falls back to plaintext.
Bonjour names and TXT records are display hints, not authentication.
For address changes, they only order rediscovery candidates. The app probes without a bearer
token and requires its stored SPKI pin before moving URL-keyed credentials or retrying the
authenticated request. A same-name server with another key is refused. Rediscovery is limited
to once a minute; ordinary HTTP errors never trigger it.

Before sending a pairing code or bearer token, the app authenticates the connection using
the fingerprint in a pairing link, a commit-then-reveal six-digit comparison on both
screens, a PBKDF2-HMAC-SHA256 code proof, or a proof of an existing pairing. Compare the
numbers before clicking Allow, then confirm the match on the iPhone. The installation ID
is sent only in the final, pinned completion request after both approvals; an advertiser
cannot obtain it by claiming approval on its own. Codes expire two minutes after their first challenge and
permit at most three challenges; challenges also expire and are rate limited.

Existing pairings upgrade over TLS without transmitting their token until the key is
verified. A replacement key must prove it holds the pairing; success updates the pin and
shows a notice. A changed key with an invalid pairing proof blocks transfers and Free Up Space.
Network failures, timeouts, rate limits and temporary server failures retain the old pin,
do not block Automatic Mode, and retry after 60 seconds with exponential backoff capped at
15 minutes. App activation and background preparation also retry when due. Certificate renewal
keeps the key. An unreadable identity stops the server instead of silently replacing it.
The permanent verification endpoint does not rotate tokens.
An existing HTTPS proxy pairing without pins retains system trust only after the proxy's
certificate validates and the backend proves its token. An existing pin is never weakened
to system trust; pin replacement still binds the proof to the observed TLS key.

Pairing also sends a random, device-only installation ID and the last confirmed device name.
The server stores only a hash of the ID and compares matching hashes in constant time. This
is a record-matching key, **not a secret or proof of ownership**: reclaiming a record still
requires the complete owner-approved pairing protocol over authenticated TLS. Only an active,
non-revoked matching record is reused. Re-pairing replaces its token hash, invalidating the
old token, but retains its name, folder and asset/event relationships. Explicitly revoked and
legacy records without an install ID are not silently reclaimed.

## Boundaries and residual risks

- TLS protects originals, compact copies, tokens and API integrity against passive
  observers and active network impersonation. Verification and the deletion gate remain
  separate: encryption alone never permits deleting an original.
- A token intercepted before HTTPS was introduced can forge the upgrade proof. Compare
  Server Check's fingerprint with `homespun-server certificate` once after upgrading.
- Typed codes have a short offline guessing window. PBKDF2 uses 600,000 rounds, the first
  challenge burns the code in two minutes, and online challenges are limited. Scanning a
  current fingerprint-bearing QR code avoids that guessing risk.
- A six-digit approval has a one-in-a-million impersonation chance per human-approved
  attempt. Clicking Allow without comparing the numbers defeats that protection.
- Every pinned URLSession must complete a tokenless probe on that same session and observe a
  matching server-trust challenge before its first token-bearing request. Authorization is
  attached only after that session's delegate gate succeeds, including on retries. Concurrent requests
  share the probe; success is cached only for that session's lifetime. A resumed connection
  that skips the initial challenge fails closed without sending the token. All later trust
  challenges still enforce the pin. URLSession has no supported public switch for disabling
  TLS resumption or pausing a request to add a header during its handshake, so the delegate's
  per-session gate is used instead of relying on a physical-device cache-isolation assumption.
- TLS cannot protect a compromised phone or server account, someone who reads the data
  folder, network denial of service, or traffic sizes and timing. Back up `homespun.db*`,
  settings and `tls/` privately, with the originals. The private key is in
  `<data>/tls/identity.pem` (0600 inside a 0700 directory).
  File fsync and atomic publication remain mandatory. If a network filesystem rejects directory
  fsync with EINVAL, ENOTSUP or EROFS, the server logs a warning and continues: file contents have
  been synced, but crash durability of the directory entry depends on that filesystem.
- A proxy terminating TLS is trusted with the data. Keep any unverified HTTPS backend hop
  on loopback or another trusted private path, not across an untrusted network.
