package zw.co.tempest.tapcard

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class SupabaseClient {
    data class AuthResult(
        val userId: String,
        val email: String,
        val accessToken: String,
        val refreshToken: String,
        val emailConfirmationRequired: Boolean = false
    )

    val isConfigured: Boolean
        get() = BuildConfig.SUPABASE_URL.startsWith("https://") && BuildConfig.SUPABASE_ANON_KEY.isNotBlank()

    fun signIn(email: String, password: String): AuthResult = authRequest(
        "/auth/v1/token?grant_type=password",
        JSONObject().put("email", email).put("password", password)
    )

    fun signUp(email: String, password: String): AuthResult = authRequest(
        "/auth/v1/signup",
        JSONObject().put("email", email).put("password", password)
    )

    fun refresh(refreshToken: String): AuthResult = authRequest(
        "/auth/v1/token?grant_type=refresh_token",
        JSONObject().put("refresh_token", refreshToken)
    )

    fun fetchSubscription(userId: String, accessToken: String): SubscriptionState {
        val response = request(
            method = "GET",
            path = "/rest/v1/tapcard_subscriptions?select=plan,status,trial_ends_at,current_period_end&user_id=eq.$userId&limit=1",
            accessToken = accessToken
        )
        val array = JSONArray(response)
        if (array.length() == 0) return SubscriptionState(verifiedAtMillis = System.currentTimeMillis())
        val value = array.getJSONObject(0)
        return SubscriptionState(
            plan = value.optString("plan", "free"),
            status = value.optString("status", "active"),
            trialEndsAt = value.optNullableString("trial_ends_at"),
            currentPeriodEnd = value.optNullableString("current_period_end"),
            verifiedAtMillis = System.currentTimeMillis()
        )
    }

    fun uploadEvents(events: JSONArray, accessToken: String) {
        request("POST", "/rest/v1/tapcard_analytics_events", accessToken, events.toString(), "return=minimal")
    }

    private fun authRequest(path: String, body: JSONObject): AuthResult {
        val value = JSONObject(request("POST", path, body = body.toString()))
        val user = value.optJSONObject("user") ?: value
        val accessToken = value.optString("access_token")
        return AuthResult(
            userId = user.optString("id"),
            email = user.optString("email", body.optString("email")),
            accessToken = accessToken,
            refreshToken = value.optString("refresh_token"),
            emailConfirmationRequired = accessToken.isBlank()
        )
    }

    private fun request(
        method: String,
        path: String,
        accessToken: String? = null,
        body: String? = null,
        prefer: String? = null
    ): String {
        check(isConfigured) { "Cloud service is not configured in this build." }
        val connection = (URL(BuildConfig.SUPABASE_URL.trimEnd('/') + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 15_000
            setRequestProperty("apikey", BuildConfig.SUPABASE_ANON_KEY)
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Accept", "application/json")
            if (!accessToken.isNullOrBlank()) setRequestProperty("Authorization", "Bearer $accessToken")
            if (!prefer.isNullOrBlank()) setRequestProperty("Prefer", prefer)
            if (body != null) {
                doOutput = true
                outputStream.bufferedWriter(Charsets.UTF_8).use { it.write(body) }
            }
        }
        val code = connection.responseCode
        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
        val response = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        connection.disconnect()
        if (code !in 200..299) {
            val message = runCatching { JSONObject(response).optString("msg").ifBlank { JSONObject(response).optString("message") } }.getOrNull()
            throw IllegalStateException(message?.ifBlank { null } ?: "Cloud request failed ($code).")
        }
        return response
    }

    private fun JSONObject.optNullableString(name: String): String? =
        if (isNull(name)) null else optString(name).ifBlank { null }
}
