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

Retention (by time received, enforced by a daily cron): events 400 days, MetricKit metrics 90
days, MetricKit diagnostics 365 days, reports 730 days. `DELETE /v1/installs/<install>` removes
everything for an install immediately (the app calls it when the person chooses Delete Shared Data).

The Worker also enforces a hard usage budget so the public app key can't run up a bill; see
[Budget](#budget).

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
| 503 | `{"error": "busy"}`: a daily budget is used up (events, or reports past the D1 write cap); `Retry-After` is the seconds until the next UTC day |

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
- 503 `{"error": "busy"}` when the batch would pass the day's event cap or 90% of the D1 write
  budget. Nothing is stored; the app keeps its queue and retries later.

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

Refusals are still 202, and the app does not retry them:

- `{"accepted": 0, "reason": "limit"}`: the install already sent 3 metrics or 20 diagnostics
  payloads this UTC day (guards against a buggy app).
- `{"accepted": 0, "reason": "budget"}`: storing it would pass 90% of an R2 cap or of the D1 write
  cap.

A stored diagnostics payload with crashes or hangs is also emailed to you; see
[Emails you receive](#emails-you-receive).

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
- Reports may use the R2 budget up to 100%. Past it (or if the R2 write fails) the report is kept
  in D1 only (`r2_key` is `''`), still emailed with the truncated diagnostics, and still 201.
  Past `REPORT_EMAILS_MAX_DAY` emails in a UTC day, reports are stored but not emailed (logged).
  Only past 100% of the D1 write cap is a report refused, with 503 `{"error": "busy"}`.

### `DELETE /v1/installs/<install>` → 204

Deletes all events, payloads (rows and R2 objects) and reports (rows and R2 objects) of the
install, and releases their bytes from the budget. Never refused by the budget. Also 204 when nothing exists. 400 if `<install>` is not a lowercase UUID.

### `GET /v1/health` → 200 `{"ok": true}`

No key needed.

### Scheduled (daily, 03:17 UTC)

1. Deletes metrics received more than 90 days ago, diagnostics older than 365 days, reports older
   than 730 days (R2 objects first, then rows) and events older than 400 days. One run spends at
   most a quarter of the daily D1 write cap on deletes and stays within Workers Free limits;
   leftovers are removed on later runs.
2. Deletes daily `usage` counters older than 40 days and monthly ones older than 13 months, and
   sets `r2.bytes` to the sum of `size` in `payloads` and `reports` (corrects any drift).
3. Sends budget alerts (see [Budget](#budget)).

## Emails you receive

All go to the `REPORT_TO` secret (a verified Email Routing destination).

- **Bug reports**, from `Homespun Reports <reports@homespun.photos>`, subject
  `[Homespun HS-XXXXXX] <message>`, with `Reply-To` set to the user's email (see
  `POST /v1/reports` above).
- **Crash and hang notices**, from `Homespun Reports <reports@homespun.photos>`, when
  `POST /v1/diagnostics` stores a payload with crashes or hangs, e.g.
  `[Homespun crash] 0.1.0 (202611151609) · iPhone19,4 · iOS 27.2.1 · SIGABRT` (`[Homespun hang] …
  · 3.25 sec` when there are only hangs). Version, build, device and OS come from the first
  crash's (or hang's) `diagnosticMetaData` when present, otherwise from the request's `app` and
  `device`. The plain-text body has only: the counts by kind, TestFlight or not, the termination
  reason, exception type/code and signal (named, e.g. `EXC_CRASH (10)`, `SIGABRT (6)`), the
  Objective-C exception (`exceptionName: composedMessage (class …)`) if present, the hang
  duration for hangs, the crashed (or hanging) thread's frames as
  `binaryName  +offset  (binaryUUID)` (depth-first, at most 60 lines), the R2 key and the install
  id. Symbolicate the offsets against the build's dSYM. At most one notice per install per UTC
  day and `CRASH_EMAILS_MAX_DAY` (20) a day in all; they also count against
  `REPORT_EMAILS_MAX_DAY`. Past those, payloads are stored silently. A failed send never fails the
  upload.
- **Budget alerts**, from `Homespun Telemetry <reports@homespun.photos>`; see
  [Budget](#budget).

## Budget

The app key is public, so anyone could post data. R2 bills beyond its free tier, and D1 and
Workers on the free plans simply stop working when a daily limit is reached (which would also
break bug reports). So the Worker counts its own usage in the D1 `usage` table and refuses work
before any free tier runs out.

Free tiers this is sized for:

| Service | Free tier | Beyond it |
| --- | --- | --- |
| R2 storage | 10 GB-month | $0.015 per GB-month |
| R2 Class A operations (writes) | 1M per month | $4.50 per million |
| R2 Class B operations (reads) | 10M per month | $0.36 per million |
| D1 | 100k rows written and 5M rows read per day, 5 GB | stops until 00:00 UTC |
| Workers | 100k requests per day | stops until 00:00 UTC |

Caps, as string vars in `wrangler.jsonc` (digits only; anything else falls back to the default):

| Var | Default | Counter in `usage` | Why |
| --- | --- | --- | --- |
| `R2_MAX_BYTES` | 8000000000 | `r2.bytes` (stored now) | 80% of 10 GB |
| `R2_MAX_PUTS_MONTH` | 800000 | `r2.puts.YYYY-MM` | 80% of 1M Class A |
| `R2_MAX_PUTS_DAY` | 25000 | `r2.puts.YYYY-MM-DD` | About a month's cap / 31, so one day can't use up the month |
| `R2_MAX_BYTES_DAY` | 250000000 | `r2.bytes.YYYY-MM-DD` (added that day) | The same for bytes |
| `EVENTS_MAX_DAY` | 20000 | `events.YYYY-MM-DD` | Each event row with its 3 indexes is about 4 D1 rows written |
| `REPORT_EMAILS_MAX_DAY` | 50 | `emails.YYYY-MM-DD` | Keeps a report or crash flood out of the inbox (report and crash emails together) |
| `CRASH_EMAILS_MAX_DAY` | 20 | `crashmail.YYYY-MM-DD` | Crash and hang notices; also at most one per install per day |
| `D1_MAX_WRITES_DAY` | 80000 | `d1.writes.YYYY-MM-DD` (estimate) | 80% of D1's 100k rows written per day |

The caps sit at 80% because counting is approximate: concurrent requests can overshoot a little,
and D1 rows written are estimated (4 per row inserted or deleted, 1 per counter). Days and
months are UTC. The D1 write cap covers what the event cap alone can't: a flood of metrics
uploads (about 9 rows written each) would otherwise exhaust D1 within the R2 caps.

What is refused, and when:

- **Metrics and diagnostics**: 202 `{"accepted": 0, "reason": "budget"}` once storing one would
  pass 90% of any R2 cap or of the D1 write cap, so reports keep the last 10%. Also
  `"reason": "limit"` after 3 metrics or 20 diagnostics payloads per install per UTC day.
- **Events**: 503 `{"error": "busy"}` once the day's events would pass `EVENTS_MAX_DAY` or the
  D1 writes 90% of their cap. The app keeps its queue and sends it later.
- **Reports**: use R2 up to 100% of the R2 caps; past that they are kept in D1 only and still
  emailed (the email carries the first 20,000 characters of the diagnostics) with 201. Past
  `REPORT_EMAILS_MAX_DAY` they are stored but not emailed. They are refused (503) only past 100%
  of the D1 write cap.
- **Deletes** (`DELETE /v1/installs/…`, retention) are never refused. They lower `r2.bytes` by
  the deleted sizes (R2 deletes are free).

Refused requests write nothing, except one marker per day (`events.full.…`, `d1.full.…`,
`r2.full.…`) for the alerts.

**Alerts.** After the daily cleanup the Worker emails `REPORT_TO` (from
`Homespun Telemetry <reports@homespun.photos>`; not counted as report emails):

- when stored R2 bytes or this month's R2 writes cross 50%, 75% or 90% of their caps, once per
  threshold and month (remembered as `alert.storage.75.YYYY-MM`, `alert.writes.90.YYYY-MM`),
  e.g. `[Homespun telemetry] R2 storage at 76% of its budget`;
- once a day if the previous day hit the event cap, the report or crash email caps, 90% of the
  D1 write cap, or an R2 cap (`[Homespun telemetry] Daily caps reached on 2026-11-14`).

Each alert lists all current counters and caps.

**Typical usage.** MetricKit delivers about one metrics payload per install per day, 10–30 KB.
1,000 sharing installs make about 30k R2 writes a month (3% of the free tier) and keep 1–3 GB
with the 90-day metrics retention. Diagnostics and reports are rare. In D1 that is about 9k rows
written a day for payloads, plus about 4 per event (10 events per install per day would be 40k).
The Worker never reads R2, so there are no Class B operations in normal operation; only your own
downloads with `wrangler r2 object get` count.

Things the budget can't cover:

- Workers Free allows 100k requests a day. A flood can use them up, and then every request,
  including reports, fails until 00:00 UTC. It costs nothing; Workers Paid would avoid it.
- Every request reads about 10 `usage` rows, which stays far below D1's 5M rows read per day.
  Your own queries count too: a query over the whole `events` table reads every row.
- Sustained growth: retention deletes cost D1 writes too, so at about 10k events a day for over
  a year (inserts plus the deletes 400 days later) D1 Free is too small. Move to Workers Paid and
  raise the caps.

**Changing caps.** Edit the vars in `wrangler.jsonc` and run `npx wrangler deploy`. (Vars changed
in the dashboard are replaced by the next deploy.) To see the counters:

```bash
npx wrangler d1 execute homespun-telemetry --remote --command "SELECT * FROM usage ORDER BY key"
```

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
5. **Schema.** `npx wrangler d1 migrations apply homespun-telemetry --remote` applies every
   migration not yet applied (`0001_init.sql`, `0002_budget.sql`, …). Run it before deploying
   code that needs a new migration.
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

-- Budget counters, and what R2 holds by kind
SELECT * FROM usage ORDER BY key;
SELECT kind, count(*) AS payloads, sum(size) AS bytes FROM payloads GROUP BY kind;

-- Latest reports, and marking one handled
SELECT id, received, app_version, channel, model, email, substr(message, 1, 80) AS message
FROM reports ORDER BY received DESC LIMIT 20;
UPDATE reports SET status = 'done' WHERE id = 'HS-7KQ2MX';
```

Reports kept without R2 have `r2_key = ''`. Fetch a stored payload or report with
`npx wrangler r2 object get homespun-telemetry/<r2_key> --remote --file out.json`.

## Layout

- `src/index.ts`: routing, key check, rate limits, cron entry point.
- `src/allowlist.ts`: the event allowlist.
- `src/budget.ts`: caps, `usage` counters and the refusal rules; `src/alerts.ts`: budget emails;
  `src/crashmail.ts`: crash and hang notices.
- `src/events.ts`, `src/payloads.ts`, `src/reports.ts`, `src/installs.ts`, `src/retention.ts`:
  one file per endpoint or job; `src/validate.ts` and `src/http.ts` hold the shared checks.
- `migrations/`: D1 schema (`wrangler d1 migrations`).
- `test/`: vitest specs and MetricKit fixtures.
