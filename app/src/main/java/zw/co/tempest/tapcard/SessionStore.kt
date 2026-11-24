package zw.co.tempest.tapcard

import android.content.Context

class SessionStore(context: Context) {
    private val prefs = context.getSharedPreferences("tapcard_commercial", Context.MODE_PRIVATE)
    private val vault = TokenVault(context)

    val userId: String? get() = prefs.getString("user_id", null)
    val email: String? get() = prefs.getString("email", null)
    val accessToken: String? get() = vault.get("access_token")
    val refreshToken: String? get() = vault.get("refresh_token")
    val isSignedIn: Boolean get() = !userId.isNullOrBlank() && !accessToken.isNullOrBlank()

    fun saveAuth(userId: String, email: String, accessToken: String, refreshToken: String) {
        prefs.edit().putString("user_id", userId).putString("email", email).apply()
        vault.put("access_token", accessToken)
        vault.put("refresh_token", refreshToken)
    }

    fun saveSubscription(value: SubscriptionState) {
        prefs.edit()
            .putString("plan", value.plan)
            .putString("subscription_status", value.status)
            .putString("trial_ends_at", value.trialEndsAt)
            .putString("period_end", value.currentPeriodEnd)
            .putLong("verified_at", value.verifiedAtMillis)
            .apply()
    }

    fun subscription() = SubscriptionState(
        plan = prefs.getString("plan", "free") ?: "free",
        status = prefs.getString("subscription_status", "active") ?: "active",
        trialEndsAt = prefs.getString("trial_ends_at", null),
        currentPeriodEnd = prefs.getString("period_end", null),
        verifiedAtMillis = prefs.getLong("verified_at", 0L)
    )

    fun signOut() {
        vault.clear()
        prefs.edit().clear().apply()
    }
}
