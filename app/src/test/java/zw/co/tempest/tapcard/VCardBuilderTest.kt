package zw.co.tempest.tapcard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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

    @Test fun multipleCardsKeepIndependentIdentitiesAndDetails() {
        val personal = CardProfile(label = "Personal", name = "Dylan", email = "personal@example.com")
        val work = personal.copy(
            id = CardProfile().id,
            label = "Work",
            email = "work@example.com",
            theme = "blue"
        )

        assertNotEquals(personal.id, work.id)
        assertEquals("personal@example.com", personal.email)
        assertEquals("work@example.com", work.email)
        assertEquals("green", personal.theme)
        assertEquals("blue", work.theme)
    }

    @Test fun publishedCardUsesHostedRecipientPage() {
        val profile = CardProfile(publicSlug = "dylankoshita", website = "example.com", isPublished = true)
        assertEquals("https://cards.example.com/c/dylankoshita", profile.sharingUri("https://cards.example.com"))
        assertEquals("https://example.com", profile.sharingUri(""))
    }

    @Test fun richerContactDetailsAreIncludedInVCard() {
        val result = VCardBuilder.build(CardProfile(
            name = "Dylan",
            bio = "Founder and builder",
            instagram = "instagram.com/dylan",
            whatsapp = "+263 77 123 4567",
            bookingUrl = "cal.example.com/dylan"
        ))
        assertTrue(result.contains("NOTE:Founder and builder"))
        assertTrue(result.contains("https://wa.me/263771234567"))
        assertTrue(result.contains("TYPE=instagram:https://instagram.com/dylan"))
    }
}
