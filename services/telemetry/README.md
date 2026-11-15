# Homespun telemetry

A Cloudflare Worker that receives Homespun's **opt-in** analytics events, MetricKit payloads and
bug reports. It runs at `https://telemetry.homespun.photos` and stores data in D1 (SQL) and R2
(objects). Bug reports are also emailed to the developer through Email Routing.

## What is collected, and why

Nothing is sent unless the user turns sharing on in the app (bug reports only when the user sends
one). The goal is to learn whether setup, backup and freeing up space work for real users, and to
find crashes and hangs.

- **Analytics events**: allowlisted event names with a few allowlisted properties (counts,
  rounded sizes and durations, outcomes, setup choices, error domains and codes), plus the app
  version/build/channel and the device model, OS version and family. Events are tied to a random
  install id that the app replaces when the user stops sharing.
- **MetricKit**: Apple's daily performance metrics and crash/hang diagnostics (call stacks of
  app and system binaries, termination reasons). No user content.
- **Bug reports**: the message the user writes, an optional reply email, and optional
  diagnostics the app attaches. Emailed to the developer and kept for replies.

Never sent or stored: photos, videos, file names, album names, server addresses, pairing codes,
account identifiers. IP addresses are used only transiently as rate-limit keys and are not
stored; per-request invocation logs are turned off (`wrangler.jsonc`).

Retention (by time received, enforced by a daily cron): events 400 days, MetricKit payloads 365
days, reports 730 days. `DELETE /v1/installs/<install>` removes everything for an install
immediately (the app calls it when the user stops sharing).

## API (v1)

All requests are HTTPS JSON. Every endpoint except health needs the header
`X-Homespun-Key: homespun-app-v1` (the `APP_KEY` var in `wrangler.jsonc`; a public noise filter,
not a secret). Errors are `{"error": "<short reason>"}`. Checks run in this order:

| Status | When |
| --- | --- |
| 404 | Unknown path (paths are exact; no trailing slash) |
| 405 | Wrong method (`Allow` header names the right one) |
| 401 | Missing or wrong `X-Homespun-Key` |
| 429 | Per-IP rate limit hit (`Retry-After: 60`): 60 requests/minute; reports also 2/minute |
| 415 | `Content-Type` is not `application/json` (parameters such as `; charset=utf-8` are fine) |
| 413 | Body over the endpoint's limit |
| 400 | Invalid UTF-8/JSON, or a schema violation (the reason names the first problem, e.g. `events[3].props: "foo" is not allowed for "setup.step"`) |

Unknown fields are rejected everywhere (400), so nothing unexpected is ever stored.

Common objects:

- `install`: lowercase UUID string, e.g. `"3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b"`.
- `app`: `{"version": string ≤16, "build": string ≤16, "channel": "debug" | "testflight" | "appstore"}`
- `device`: `{"model": string ≤32 (e.g. "iPhone18,1"), "os": string ≤16 (e.g. "27.2"), "family": "iphone" | "duo"}`

Strings in `app` and `device` may not contain control characters.

### `POST /v1/events` (≤ 64 KB) → 202 `{"accepted": n}`

```json
{
  "install": "3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b",
  "app": {"version": "1.0", "build": "42", "channel": "testflight"},
  "device": {"model": "iPhone18,1", "os": "27.2", "family": "iphone"},
  "events": [
    {"name": "app.launch", "time": "2026-11-15T21:40:00Z", "props": {"cold": true}},
    {"name": "analytics.optin", "time": "2026-11-15T21:40:00Z", "props": {}}
  ]
}
```

- 1–100 events. `time` is ISO 8601 with a zone (`Z` or `±hh:mm`; fractional seconds optional) and
  is stored in UTC (`2026-11-15T21:40:00.000Z`). `props` may be omitted (same as `{}`).
- Prop values: integers from −1e12 to 1e12, booleans, or strings of at most 64 characters
  matching `^[A-Za-z0-9._:-]*$`. Floats, nulls, objects and arrays are rejected.
- If any event is invalid the whole batch is rejected (400) and nothing is stored. Each event
  becomes one row in `events`.

Allowlist (edit [`src/allowlist.ts`](src/allowlist.ts)):

| Event | Allowed prop keys |
| --- | --- |
| `app.launch` | `cold` |
| `setup.step` | `step` |
| `setup.choice` | `question`, `answer` |
| `setup.done` | `outcome` |
| `pair.result` | `method`, `outcome`, `error` |
| `server.info` | `kind`, `mode`, `version`, `arch` |
| `run.finished` | `trigger`, `items`, `bytes`, `duration`, `backedUp`, `compacted`, `failed`, `kept`, `notYet` |
| `freeup.finished` | `items`, `bytes`, `first` |
| `feature.used` | `feature`, `detail` |
| `premium.event` | `event`, `outcome` |
| `error` | `domain`, `code`, `where` |
| `analytics.optin` | (none) |
| `report.sent` | `withDiagnostics` |
| `crash.marker` | `foreground` |

### `POST /v1/metrics` (≤ 512 KB) and `POST /v1/diagnostics` (≤ 1 MB) → 202 `{"accepted": 1}`

```json
{"install": "…", "app": {…}, "device": {…}, "payload": { MXMetricPayload / MXDiagnosticPayload jsonRepresentation }}
```

The request JSON is stored verbatim in R2 at `metrics/YYYY/MM/DD/<install>/<id>.json` or
`diagnostics/…` (UTC date received) and indexed in the `payloads` table. Diagnostics get a
`summary` (missing keys are tolerated):

```json
{"crashDiagnostics": 1, "hangDiagnostics": 0, "cpuExceptionDiagnostics": 0,
 "diskWriteExceptionDiagnostics": 0, "appLaunchDiagnostics": 0,
 "firstCrash": {"exceptionType": 1, "signal": 11,
                "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11", "appVersion": "1.0"}}
```

`firstCrash` holds whichever of those fields the first crash's `diagnosticMetaData` has, and is
absent when there is none.

### `POST /v1/reports` (≤ 2 MB) → 201 `{"id": "HS-7KQ2MX"}`

```json
{"install": "…" or null, "app": {…}, "device": {…},
 "message": "1–5000 characters", "email": "optional@example.com", "diagnostics": {optional object}}
```

- `install`, `email` and `diagnostics` may be omitted or `null`; a blank `email` counts as none.
  `message` must contain non-whitespace and is counted in user-visible characters (like Swift's
  `String.count`). `email` must look like an address (`x@y.z` without spaces, the same rule as
  the app's form) and be at most 254 characters.
- The id is `HS-` plus 6 symbols from `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (no 0/O/1/I/L).
- Stored verbatim in R2 at `reports/<id>.json` and in the `reports` table with status `new`.
- Emailed from `Homespun Reports <reports@homespun.photos>` to the `REPORT_TO` secret, with
  `Reply-To` set to the user's email when given (unless it contains characters such as `,` or
  `<`; then it only appears in the body), subject `[Homespun <id>] <first 60 characters of
  the message on one line>`, and a plain-text body with the message, app and device info, the
  email, the R2 key, and the pretty-printed diagnostics (first 20,000 characters). If sending
  fails, the report is still stored, the failure is logged, and the response is still 201.

### `DELETE /v1/installs/<install>` → 204

Deletes all events, payloads (rows and R2 objects) and reports (rows and R2 objects) of the
install. Also 204 when nothing exists. 400 if `<install>` is not a lowercase UUID.

### `GET /v1/health` → 200 `{"ok": true}`

No key needed.

### Scheduled (daily, 03:17 UTC)

Deletes events received more than 400 days ago, payloads older than 365 days and reports older
than 730 days (R2 objects first, then rows). Work is chunked to stay within Workers Free limits;
leftovers are removed on the next run.

## Develop and test

Requires Node.js 22.12 or later (Wrangler 4, Vitest 5). Everything runs locally with Miniflare (D1, R2, rate limits and
a simulated `send_email`); no Cloudflare account is needed.

```bash
cd services/telemetry
npm ci
npm test              # vitest in the Workers runtime (@cloudflare/vitest-plugin)
npm run typecheck     # wrangler types && tsc

# Local server on http://localhost:8787 (emails are written to .wrangler/tmp, not sent):
echo 'REPORT_TO=you@example.com' > .dev.vars
npx wrangler d1 migrations apply homespun-telemetry --local
npm run dev
curl localhost:8787/v1/health
curl -H 'X-Homespun-Key: homespun-app-v1' -H 'Content-Type: application/json' \
  -d '{"install":"3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b","app":{"version":"1.0","build":"1","channel":"debug"},"device":{"model":"iPhone18,1","os":"27.2","family":"iphone"},"events":[{"name":"analytics.optin","time":"2026-11-15T21:40:00Z","props":{}}]}' \
  localhost:8787/v1/events
npx wrangler dev --test-scheduled   # then: curl 'localhost:8787/cdn-cgi/handler/scheduled'
```

## Deploy (owner)

1. **Credentials.** Either run `npx wrangler login` (browser), or create an API token
   (My Profile → API Tokens → Create custom token) and export `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_ACCOUNT_ID`. Token permissions:
   - Account: **Workers Scripts: Edit**, **D1: Edit**, **Workers R2 Storage: Edit**,
     **Account Settings: Read**; add **Email Routing Addresses: Read** if a deploy complains about
     the `send_email` binding.
   - Zone `homespun.photos`: **Workers Routes: Edit**, **DNS: Edit** (for the custom domain).
2. **Email Routing** (dashboard → homespun.photos → Email → Email Routing). Enable it and accept
   the MX/SPF/DKIM DNS records. Add your inbox as a destination address and click the
   verification link Cloudflare sends. Create the rule `support@homespun.photos` → your inbox.
   The Worker sends as `reports@homespun.photos` and can only send to **verified destination
   addresses**, so `REPORT_TO` must be that verified inbox (not `support@`). Sending to verified
   addresses is free on every plan.
3. **D1.** `npx wrangler d1 create homespun-telemetry`, then put the printed `database_id` into
   `wrangler.jsonc` (it is not secret; commit it).
4. **R2.** Enable R2 once in the dashboard if you never have, then
   `npx wrangler r2 bucket create homespun-telemetry`.
5. **Schema.** `npx wrangler d1 migrations apply homespun-telemetry --remote`
   (also run this before deploying any future migration).
6. **Secret.** `npx wrangler secret put REPORT_TO` and enter the verified inbox address. Wrangler
   offers to create the Worker if it does not exist yet. (`wrangler.jsonc` lists `REPORT_TO` as
   required, so deploys fail until it is set; alternatively pass `--secrets-file` to the first
   `wrangler deploy`.)
7. **Rate limit namespaces.** `namespace_id` `4701` and `4702` must be unique in the account;
   change them if another Worker already uses those numbers.
8. **Deploy.** `npx wrangler deploy`, then
   `curl https://homespun-telemetry.<your-subdomain>.workers.dev/v1/health`. The Workers Free
   plan works, but its 10 ms CPU limit can be tight for parsing 1–2 MB diagnostics and reports;
   if those uploads fail with CPU-limit errors (1102) in the logs, move to Workers Paid.
9. **Custom domain.** Uncomment the `routes` entry in `wrangler.jsonc` and deploy again.
   Wrangler creates the proxied DNS record and certificate for `telemetry.homespun.photos` (there
   must be no existing DNS record with that name). Check
   `curl https://telemetry.homespun.photos/v1/health`. Optionally add `"workers_dev": false`
   afterwards.
10. **Check email.** Send a test report (see the local `curl` above, against
    `/v1/reports` with a `message`) and confirm it arrives. Delivery failures appear in the
    Worker's logs (`wrangler tail` or the dashboard) as `report HS-…: email failed: <code>`.

## Querying

Use `npx wrangler d1 execute homespun-telemetry --remote --command "<SQL>"` (add `--json` for
machine-readable output). Examples:

```sql
-- Events and active installs per day (last 30 days)
SELECT substr(received, 1, 10) AS day, count(*) AS events, count(DISTINCT install) AS installs
FROM events WHERE received >= date('now', '-30 days') GROUP BY day ORDER BY day DESC;

-- Event counts by name this week
SELECT name, count(*) AS n FROM events WHERE time >= date('now', '-7 days') GROUP BY name ORDER BY n DESC;

-- Setup funnel
SELECT json_extract(props, '$.step') AS step, count(DISTINCT install) AS installs
FROM events WHERE name = 'setup.step' GROUP BY step ORDER BY installs DESC;

-- Backup runs by app version
SELECT app_version, count(*) AS runs, sum(json_extract(props, '$.failed')) AS failed_items
FROM events WHERE name = 'run.finished' GROUP BY app_version ORDER BY app_version DESC;

-- Crashes and hangs by the app version that crashed
SELECT json_extract(summary, '$.firstCrash.appVersion') AS version,
       sum(json_extract(summary, '$.crashDiagnostics')) AS crashes,
       sum(json_extract(summary, '$.hangDiagnostics')) AS hangs
FROM payloads WHERE kind = 'diagnostics' GROUP BY version ORDER BY version DESC;

-- Most common crash signatures
SELECT json_extract(summary, '$.firstCrash.exceptionType') AS exception,
       json_extract(summary, '$.firstCrash.signal') AS signal,
       json_extract(summary, '$.firstCrash.terminationReason') AS reason, count(*) AS n
FROM payloads WHERE kind = 'diagnostics' AND json_extract(summary, '$.crashDiagnostics') > 0
GROUP BY 1, 2, 3 ORDER BY n DESC LIMIT 20;

-- Latest reports, and marking one handled
SELECT id, received, app_version, channel, model, email, substr(message, 1, 80) AS message
FROM reports ORDER BY received DESC LIMIT 20;
UPDATE reports SET status = 'done' WHERE id = 'HS-7KQ2MX';
```

Fetch a stored payload or report with
`npx wrangler r2 object get homespun-telemetry/<r2_key> --remote --file out.json`.

## Layout

- `src/index.ts`: routing, key check, rate limits, cron entry point.
- `src/allowlist.ts`: the event allowlist.
- `src/events.ts`, `src/payloads.ts`, `src/reports.ts`, `src/installs.ts`, `src/retention.ts`:
  one file per endpoint or job; `src/validate.ts` and `src/http.ts` hold the shared checks.
- `migrations/`: D1 schema (`wrangler d1 migrations`).
- `test/`: vitest specs and MetricKit fixtures.
