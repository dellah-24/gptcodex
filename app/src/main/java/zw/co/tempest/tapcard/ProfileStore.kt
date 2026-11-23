package zw.co.tempest.tapcard

import android.content.Context

class ProfileStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load() = CardProfile(
        name = prefs.getString("name", "") ?: "",
        title = prefs.getString("title", "") ?: "",
        company = prefs.getString("company", "") ?: "",
        phone = prefs.getString("phone", "") ?: "",
        email = prefs.getString("email", "") ?: "",
        website = prefs.getString("website", "") ?: "",
        linkedIn = prefs.getString("linkedin", "") ?: "",
        address = prefs.getString("address", "") ?: ""
    )

    fun save(profile: CardProfile) {
        prefs.edit()
            .putString("name", profile.name)
            .putString("title", profile.title)
            .putString("company", profile.company)
            .putString("phone", profile.phone)
            .putString("email", profile.email)
            .putString("website", profile.website)
            .putString("linkedin", profile.linkedIn)
            .putString("address", profile.address)
            .apply()
    }

    companion object { const val PREFS = "tapcard_profile" }
}
