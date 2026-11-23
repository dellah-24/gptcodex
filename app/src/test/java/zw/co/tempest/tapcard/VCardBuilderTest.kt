package zw.co.tempest.tapcard

import org.junit.Assert.assertTrue
import org.junit.Test

class VCardBuilderTest {
    @Test fun producesVCard3AndEscapesFields() {
        val result = VCardBuilder.build(CardProfile(name = "Dylan, K", company = "Tempest; Technologies", phone = "+263 77 000 0000"))
        assertTrue(result.startsWith("BEGIN:VCARD\r\nVERSION:3.0"))
        assertTrue(result.contains("FN:Dylan\\, K"))
        assertTrue(result.contains("ORG:Tempest\\; Technologies"))
        assertTrue(result.endsWith("END:VCARD\r\n"))
    }

    @Test fun normalizesWebsiteScheme() {
        val profile = CardProfile(website = "example.co.zw/card")
        assertTrue(profile.primaryUri() == "https://example.co.zw/card")
    }
}
