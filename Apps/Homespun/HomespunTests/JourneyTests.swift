// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

/// One message at a time: the accessory shows the highest state on the ladder (DESIGN §16.4).
@Test func accessoryShowsTheHighestStateOnly() {
    var inputs = AccessoryLadder.Inputs()
    #expect(AccessoryLadder.pick(inputs) == nil)

    inputs.paired = true
    inputs.readyCount = 37
    inputs.readyBytes = 4_200_000_000
    #expect(AccessoryLadder.pick(inputs) == .ready(count: 37, bytes: 4_200_000_000))
    // What the last backup finished with comes before everything else that's ready.
    inputs.finished = (12, 1_400_000_000, ["a"])
    #expect(AccessoryLadder.pick(inputs) == .finished(count: 12, bytes: 1_400_000_000, originals: ["a"]))
    // Almost full, with something real to free, outranks a finished backup.
    inputs.phoneFreeBytes = 1_000_000_000
    #expect(AccessoryLadder.pick(inputs) == .almostFull(bytes: 4_200_000_000))
    // Running work outranks space; a blocking problem outranks everything.
    inputs.backingUp = (3, 12, "IMG_2041.HEIC")
    #expect(AccessoryLadder.pick(inputs) == .backingUp(done: 3, total: 12, current: "IMG_2041.HEIC"))
    inputs.unreachable = "polonium"
    #expect(AccessoryLadder.pick(inputs) == .unreachable("polonium"))
    // Not paired: an unreachable name means nothing.
    inputs.paired = false
    #expect(AccessoryLadder.pick(inputs) == .backingUp(done: 3, total: 12, current: "IMG_2041.HEIC"))

    // New since the last backup: only with at least 50 items and 3 days, and nothing more urgent.
    var calm = AccessoryLadder.Inputs()
    calm.paired = true
    calm.newSinceBackup = (49, 5)
    #expect(AccessoryLadder.pick(calm) == nil)
    calm.newSinceBackup = (312, 2)
    #expect(AccessoryLadder.pick(calm) == nil)
    calm.newSinceBackup = (312, 3)
    #expect(AccessoryLadder.pick(calm) == .newPhotos(count: 312))
    // Not almost full when there's little to free: iOS warns already.
    calm.phoneFreeBytes = 100_000_000
    calm.readyBytes = 100_000_000
    calm.readyCount = 2
    #expect(AccessoryLadder.pick(calm) == .ready(count: 2, bytes: 100_000_000))
}

/// The Premium moment: once, after real value (1 GB freed) and repeated manual backups.
@Test func premiumMomentWaitsForRealValue() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let twoDays = [now.addingTimeInterval(-3 * day), now.addingTimeInterval(-1 * day)]
    #expect(Journey.premiumMomentDue(owned: false, freedBytes: 1_200_000_000, manualBackupDays: twoDays, dismissed: false, now: now))
    #expect(!Journey.premiumMomentDue(owned: true, freedBytes: 1_200_000_000, manualBackupDays: twoDays, dismissed: false, now: now))
    #expect(!Journey.premiumMomentDue(owned: false, freedBytes: 900_000_000, manualBackupDays: twoDays, dismissed: false, now: now))
    #expect(!Journey.premiumMomentDue(owned: false, freedBytes: 1_200_000_000, manualBackupDays: twoDays, dismissed: true, now: now))
    // Two backups on one day, or one of them too long ago, isn't a habit yet.
    #expect(!Journey.premiumMomentDue(owned: false, freedBytes: 2_000_000_000, manualBackupDays: [now, now], dismissed: false, now: now))
    #expect(!Journey.premiumMomentDue(owned: false, freedBytes: 2_000_000_000,
                                      manualBackupDays: [now.addingTimeInterval(-20 * day), now], dismissed: false, now: now))
}
