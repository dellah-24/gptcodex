package zw.co.tempest.tapcard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class SubscriptionStateTest {
    @Test fun planLimitsAreApplied() {
        assertEquals(1, SubscriptionState().maxCards)
        assertEquals(10, SubscriptionState("pro", "active", currentPeriodEnd = "2099-01-01T00:00:00Z").maxCards)
        assertEquals(50, SubscriptionState("business", "trialing", trialEndsAt = "2099-01-01T00:00:00Z").maxCards)
    }

    @Test fun paidAccessHasASevenDayOfflineGracePeriod() {
        val expiry = Instant.parse("2026-11-20T00:00:00Z").toEpochMilli()
        val state = SubscriptionState("pro", "active", currentPeriodEnd = "2026-11-20T00:00:00Z")
        assertTrue(state.isEntitled(expiry + 6L * 24 * 60 * 60 * 1000))
        assertFalse(state.isEntitled(expiry + 8L * 24 * 60 * 60 * 1000))
    }

    @Test fun cancelledPaidPlanFallsBackToFree() {
        assertEquals("free", SubscriptionState("business", "cancelled", currentPeriodEnd = "2099-01-01T00:00:00Z").effectivePlan)
    }
}
