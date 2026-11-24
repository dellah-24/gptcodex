package zw.co.tempest.tapcard

import java.util.UUID

data class CardProfile(
    val id: String = UUID.randomUUID().toString(),
    val publicSlug: String = newSlug(),
    val label: String = "Personal",
    val name: String = "",
    val title: String = "",
    val company: String = "",
    val phone: String = "",
    val email: String = "",
    val website: String = "",
    val linkedIn: String = "",
    val instagram: String = "",
    val whatsapp: String = "",
    val bookingUrl: String = "",
    val bio: String = "",
    val address: String = "",
    val theme: String = "green",
    val isPublished: Boolean = false
) {
    fun sharingUri(publicBaseUrl: String): String = if (isPublished && publicBaseUrl.startsWith("https://")) {
        "${publicBaseUrl.trimEnd('/')}/c/$publicSlug"
    } else primaryUri()

    fun primaryUri(): String = when {
        website.isNotBlank() -> normalizeUrl(website)
        linkedIn.isNotBlank() -> normalizeUrl(linkedIn)
        email.isNotBlank() -> "mailto:${email.trim()}"
        phone.isNotBlank() -> "tel:${phone.filter { it.isDigit() || it == '+' }}"
        else -> "https://tempesttechnologies.co.zw"
    }

    companion object {
        fun newSlug(): String = UUID.randomUUID().toString().replace("-", "").take(12)

        fun normalizeUrl(value: String): String {
            val clean = value.trim()
            return if (clean.startsWith("http://") || clean.startsWith("https://")) clean else "https://$clean"
        }
    }
}
