package zw.co.tempest.tapcard

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

class ProfileStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(): CardProfile {
        val cards = loadAll()
        val activeId = prefs.getString(KEY_ACTIVE, null)
        return cards.firstOrNull { it.id == activeId } ?: cards.first()
    }

    fun loadAll(): List<CardProfile> {
        val raw = prefs.getString(KEY_CARDS, null)
        if (raw.isNullOrBlank()) return migrateLegacy()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) add(fromJson(array.getJSONObject(index)))
            }.ifEmpty { listOf(CardProfile()) }
        }.getOrElse { migrateLegacy() }
    }

    fun save(profile: CardProfile) {
        val cards = loadAll().toMutableList()
        val index = cards.indexOfFirst { it.id == profile.id }
        if (index >= 0) cards[index] = profile else cards.add(profile)
        persist(cards, profile.id)
        clearLegacyFields()
    }

    fun create(label: String): CardProfile {
        require(loadAll().size < MAX_CARDS) { "A maximum of $MAX_CARDS cards is supported." }
        val card = CardProfile(label = label.trim().ifBlank { "New card" })
        val cards = loadAll() + card
        persist(cards, card.id)
        return card
    }

    fun duplicate(profile: CardProfile): CardProfile {
        require(loadAll().size < MAX_CARDS) { "A maximum of $MAX_CARDS cards is supported." }
        val copy = profile.copy(id = CardProfile().id, label = "${profile.label} copy")
        persist(loadAll() + copy, copy.id)
        return copy
    }

    fun delete(id: String): CardProfile {
        val cards = loadAll()
        require(cards.size > 1) { "Keep at least one card." }
        val remaining = cards.filterNot { it.id == id }
        val next = remaining.first()
        persist(remaining, next.id)
        return next
    }

    fun setActive(id: String): CardProfile {
        val card = loadAll().firstOrNull { it.id == id } ?: load()
        prefs.edit().putString(KEY_ACTIVE, card.id).apply()
        return card
    }

    fun isSharingEnabled(): Boolean = prefs.getBoolean("nfc_sharing_enabled", false)

    fun setSharingEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("nfc_sharing_enabled", enabled).apply()
    }

    private fun migrateLegacy(): List<CardProfile> {
        val card = CardProfile(
            name = prefs.getString("name", "") ?: "",
            title = prefs.getString("title", "") ?: "",
            company = prefs.getString("company", "") ?: "",
            phone = prefs.getString("phone", "") ?: "",
            email = prefs.getString("email", "") ?: "",
            website = prefs.getString("website", "") ?: "",
            linkedIn = prefs.getString("linkedin", "") ?: "",
            address = prefs.getString("address", "") ?: ""
        )
        persist(listOf(card), card.id)
        clearLegacyFields()
        return listOf(card)
    }

    private fun persist(cards: List<CardProfile>, activeId: String) {
        val array = JSONArray()
        cards.forEach { array.put(toJson(it)) }
        prefs.edit().putString(KEY_CARDS, array.toString()).putString(KEY_ACTIVE, activeId).apply()
    }

    private fun toJson(card: CardProfile) = JSONObject()
        .put("id", card.id)
        .put("label", card.label)
        .put("name", card.name)
        .put("title", card.title)
        .put("company", card.company)
        .put("phone", card.phone)
        .put("email", card.email)
        .put("website", card.website)
        .put("linkedin", card.linkedIn)
        .put("address", card.address)
        .put("theme", card.theme)

    private fun fromJson(json: JSONObject) = CardProfile(
        id = json.optString("id").ifBlank { CardProfile().id },
        label = json.optString("label", "Personal"),
        name = json.optString("name"),
        title = json.optString("title"),
        company = json.optString("company"),
        phone = json.optString("phone"),
        email = json.optString("email"),
        website = json.optString("website"),
        linkedIn = json.optString("linkedin"),
        address = json.optString("address"),
        theme = json.optString("theme", "green")
    )

    private fun clearLegacyFields() {
        prefs.edit().remove("name").remove("title").remove("company").remove("phone")
            .remove("email").remove("website").remove("linkedin").remove("address").apply()
    }

    companion object {
        const val PREFS = "tapcard_profile"
        const val MAX_CARDS = 10
        private const val KEY_CARDS = "cards_json_v2"
        private const val KEY_ACTIVE = "active_card_id"
    }
}
