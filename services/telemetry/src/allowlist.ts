// SPDX-License-Identifier: AGPL-3.0-only

/**
 * Analytics events the app may send, and the property keys each one may carry.
 * Every key is optional. Values must be integers (-1e12...1e12), booleans, or strings of at
 * most 64 characters matching ^[A-Za-z0-9._:-]*$. A batch with anything else is rejected.
 *
 * To add or change an event, edit this table, update README.md and the app, and deploy.
 */
export const EVENT_ALLOWLIST: Readonly<Record<string, readonly string[]>> = {
	"app.launch": ["cold"],
	"setup.step": ["step"],
	"setup.choice": ["question", "answer"],
	"setup.done": ["outcome"],
	"pair.result": ["method", "outcome", "error"],
	"server.info": ["kind", "mode", "version", "arch"],
	"run.finished": ["trigger", "items", "bytes", "duration", "backedUp", "compacted", "failed", "kept", "notYet"],
	"freeup.finished": ["items", "bytes", "first"],
	"feature.used": ["feature", "detail"],
	"premium.event": ["event", "outcome"],
	"error": ["domain", "code", "where"],
	"analytics.optin": [],
	"report.sent": ["withDiagnostics"],
	"crash.marker": ["foreground"],
};
