package wtf.openstrap.openstrap_edge

import org.junit.Test

class WeightImportBridgeTest {
    @Test
    fun unchangedHistoryAccessAllowsCompleteSnapshot() {
        requireStableWeightSnapshotAccess(true, false, false)
        requireStableWeightSnapshotAccess(true, true, true)
    }

    @Test(expected = SecurityException::class)
    fun removedReadAccessRejectsSnapshot() {
        requireStableWeightSnapshotAccess(false, true, true)
    }

    @Test(expected = SecurityException::class)
    fun removedHistoryAccessRejectsSnapshot() {
        requireStableWeightSnapshotAccess(true, false, true)
    }

    @Test(expected = SecurityException::class)
    fun addedHistoryAccessRejectsSnapshot() {
        requireStableWeightSnapshotAccess(true, true, false)
    }
}
