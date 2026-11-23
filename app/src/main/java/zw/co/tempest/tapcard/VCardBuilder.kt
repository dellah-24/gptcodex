package zw.co.tempest.tapcard

object VCardBuilder {
    fun build(profile: CardProfile): String {
        val lines = mutableListOf("BEGIN:VCARD", "VERSION:3.0")
        lines += "FN:${escape(profile.name.ifBlank { "TapCard contact" })}"
        if (profile.name.isNotBlank()) lines += "N:${escape(profile.name)};;;;"
        if (profile.company.isNotBlank()) lines += "ORG:${escape(profile.company)}"
        if (profile.title.isNotBlank()) lines += "TITLE:${escape(profile.title)}"
        if (profile.phone.isNotBlank()) lines += "TEL;TYPE=CELL,VOICE,PREF:${escape(profile.phone)}"
        if (profile.email.isNotBlank()) lines += "EMAIL;TYPE=INTERNET,WORK:${escape(profile.email)}"
        if (profile.address.isNotBlank()) lines += "ADR;TYPE=WORK:;;${escape(profile.address)};;;;"
        if (profile.website.isNotBlank()) lines += "URL:${CardProfile.normalizeUrl(profile.website)}"
        if (profile.linkedIn.isNotBlank()) lines += "X-SOCIALPROFILE;TYPE=linkedin:${CardProfile.normalizeUrl(profile.linkedIn)}"
        lines += "END:VCARD"
        return lines.joinToString("\r\n") + "\r\n"
    }

    fun escape(value: String): String = value
        .replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
}
