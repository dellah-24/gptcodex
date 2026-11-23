package zw.co.tempest.tapcard

data class CardProfile(
    val name: String = "",
    val title: String = "",
    val company: String = "",
    val phone: String = "",
    val email: String = "",
    val website: String = "",
    val linkedIn: String = "",
    val address: String = ""
) {
    fun primaryUri(): String = when {
        website.isNotBlank() -> normalizeUrl(website)
        linkedIn.isNotBlank() -> normalizeUrl(linkedIn)
        email.isNotBlank() -> "mailto:${email.trim()}"
        phone.isNotBlank() -> "tel:${phone.filter { it.isDigit() || it == '+' }}"
        else -> "https://tempesttechnologies.co.zw"
    }

    companion object {
        fun normalizeUrl(value: String): String {
            val clean = value.trim()
            return if (clean.startsWith("http://") || clean.startsWith("https://")) clean else "https://$clean"
        }
    }
}
