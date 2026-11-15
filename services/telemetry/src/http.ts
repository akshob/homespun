// SPDX-License-Identifier: AGPL-3.0-only

export const KB = 1024;
export const MB = 1024 * KB;

/** Thrown by handlers and validators; rendered as `{"error": message}` with `status`. */
export class HttpError extends Error {
	constructor(
		readonly status: number,
		message: string,
		readonly headers?: Record<string, string>,
	) {
		super(message);
	}
}

export function badRequest(message: string): never {
	throw new HttpError(400, message);
}

export function json(body: unknown, status = 200, headers?: Record<string, string>): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
	});
}

export function errorResponse(error: HttpError): Response {
	return json({ error: error.message }, error.status, error.headers);
}

export function isObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

export interface JsonBody {
	/** The body exactly as received (stored verbatim in R2). */
	text: string;
	value: Record<string, unknown>;
}

/** Reads a JSON object body of at most `maxBytes`, enforcing 415, 413 and 400 in that order. */
export async function readJsonBody(request: Request, maxBytes: number): Promise<JsonBody> {
	const type = (request.headers.get("Content-Type") ?? "").trim();
	if (!/^application\/json\s*(;|$)/i.test(type)) {
		throw new HttpError(415, "content type must be application/json");
	}
	const declared = request.headers.get("Content-Length");
	if (declared !== null && Number(declared) > maxBytes) {
		throw new HttpError(413, "body too large");
	}
	const bytes = await readLimited(request.body, maxBytes);
	let text: string;
	try {
		text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
	} catch {
		badRequest("body is not valid UTF-8");
	}
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		badRequest("body is not valid JSON");
	}
	if (!isObject(value)) badRequest("body must be a JSON object");
	return { text, value };
}

/** Reads the stream, failing with 413 as soon as it exceeds `maxBytes` (Content-Length may be absent). */
async function readLimited(body: ReadableStream<Uint8Array> | null, maxBytes: number): Promise<Uint8Array> {
	if (body === null) return new Uint8Array();
	const reader = body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		total += value.byteLength;
		if (total > maxBytes) {
			await reader.cancel().catch(() => {});
			throw new HttpError(413, "body too large");
		}
		chunks.push(value);
	}
	const out = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		out.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return out;
}
