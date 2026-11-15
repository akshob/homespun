// SPDX-License-Identifier: AGPL-3.0-only

declare namespace Cloudflare {
	interface GlobalProps {
		mainModule: typeof import("../src/index");
	}
	interface Env {
		/** Test-only binding set in vitest.config.ts. */
		TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
	}
}
