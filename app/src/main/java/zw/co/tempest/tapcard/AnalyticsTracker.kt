package zw.co.tempest.tapcard

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors

class AnalyticsTracker(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("tapcard_analytics", Context.MODE_PRIVATE)
    private val session = SessionStore(appContext)
    private val client = SupabaseClient()
    private val executor = Executors.newSingleThreadExecutor()

    fun track(name: String, cardId: String? = null, metadata: JSONObject = JSONObject()) {
        synchronized(QUEUE_LOCK) {
            val queued = readQueue()
            val event = JSONObject()
                .put("local_event_id", UUID.randomUUID().toString())
                .put("event_name", name)
                .put("install_id", installId())
                .put("card_id", cardId)
                .put("metadata", metadata)
                .put("created_at", java.time.Instant.now().toString())
            queued.put(event)
            val trimmed = JSONArray()
            val start = (queued.length() - MAX_QUEUED_EVENTS).coerceAtLeast(0)
            for (index in start until queued.length()) trimmed.put(queued.getJSONObject(index))
            prefs.edit().putString(KEY_QUEUE, trimmed.toString()).apply()
        }
        flush()
    }

    fun flush() {
        if (!client.isConfigured || !session.isSignedIn) return
        executor.execute {
            val token = session.accessToken ?: return@execute
            val userId = session.userId ?: return@execute
            val batch = synchronized(QUEUE_LOCK) { readQueue() }
            if (batch.length() == 0) return@execute
            val uploadedIds = mutableSetOf<String>()
            val payload = JSONArray()
            for (index in 0 until batch.length()) {
                val source = batch.getJSONObject(index)
                uploadedIds += source.optString("local_event_id")
                payload.put(JSONObject(source.toString()).apply {
                    remove("local_event_id")
                    put("user_id", userId)
                })
            }
            runCatching { client.uploadEvents(payload, token) }
                .recoverCatching {
                    val refreshed = client.refresh(session.refreshToken ?: throw it)
                    session.saveAuth(refreshed.userId, refreshed.email, refreshed.accessToken, refreshed.refreshToken)
                    client.uploadEvents(payload, refreshed.accessToken)
                }
                .onSuccess {
                    synchronized(QUEUE_LOCK) {
                        val current = readQueue()
                        val remaining = JSONArray()
                        for (index in 0 until current.length()) {
                            val item = current.getJSONObject(index)
                            if (item.optString("local_event_id") !in uploadedIds) remaining.put(item)
                        }
                        prefs.edit().putString(KEY_QUEUE, remaining.toString()).apply()
                    }
                }
        }
    }

    private fun readQueue(): JSONArray = runCatching {
        JSONArray(prefs.getString(KEY_QUEUE, "[]"))
    }.getOrDefault(JSONArray())

    private fun installId(): String {
        prefs.getString(KEY_INSTALL_ID, null)?.let { return it }
        return UUID.randomUUID().toString().also { prefs.edit().putString(KEY_INSTALL_ID, it).apply() }
    }

    companion object {
        private const val KEY_QUEUE = "event_queue"
        private const val KEY_INSTALL_ID = "install_id"
        private const val MAX_QUEUED_EVENTS = 100
        private val QUEUE_LOCK = Any()
    }
}
