package zw.co.tempest.tapcard

import java.time.Instant

data class SubscriptionState(
    val plan: String = "free",
    val status: String = "active",
    val trialEndsAt: String? = null,
    val currentPeriodEnd: String? = null,
    val verifiedAtMillis: Long = 0L
) {
    val effectivePlan: String
        get() = if (isEntitled()) plan.lowercase() else "free"

    val maxCards: Int
        get() = when (effectivePlan) {
            "business" -> 50
            "pro" -> 10
            else -> 1
        }

    fun isEntitled(nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (plan.equals("free", true)) return true
        if (status !in setOf("active", "trialing")) return false
        val expires = parseMillis(if (status == "trialing") trialEndsAt else currentPeriodEnd)
        if (expires != null) return nowMillis <= expires + OFFLINE_GRACE_MILLIS
        return verifiedAtMillis > 0 && nowMillis <= verifiedAtMillis + OFFLINE_GRACE_MILLIS
    }

    fun displayName(): String = effectivePlan.replaceFirstChar { it.uppercase() }

    private fun parseMillis(value: String?): Long? = runCatching {
        value?.let(Instant::parse)?.toEpochMilli()
    }.getOrNull()

    companion object {
        const val OFFLINE_GRACE_MILLIS = 7L * 24 * 60 * 60 * 1000
    }
}
