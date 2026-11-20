// SPDX-License-Identifier: Apache-2.0
import Testing

@Suite(.serialized, .enabled(if: SnapshotEnvironment.shouldRun,
                             "Snapshots use the pinned CI Xcode/runtime; record references only in CI."))
@MainActor
struct SnapshotTests {}
