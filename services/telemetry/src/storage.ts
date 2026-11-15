// SPDX-License-Identifier: AGPL-3.0-only

/** R2 deletes at most 1000 keys per call. */
const R2_DELETE_LIMIT = 1000;

export async function deleteObjects(bucket: R2Bucket, keys: readonly string[]): Promise<void> {
	for (let start = 0; start < keys.length; start += R2_DELETE_LIMIT) {
		await bucket.delete(keys.slice(start, start + R2_DELETE_LIMIT));
	}
}
