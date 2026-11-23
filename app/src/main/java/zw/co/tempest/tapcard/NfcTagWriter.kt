package zw.co.tempest.tapcard

import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable

object NfcTagWriter {
    fun message(profile: CardProfile): NdefMessage {
        val uri = profile.primaryUri()
        val records = if (profile.website.isNotBlank() || profile.linkedIn.isNotBlank()) {
            arrayOf(NdefRecord.createUri(uri))
        } else {
            arrayOf(NdefRecord.createMime("text/vcard", VCardBuilder.build(profile).toByteArray(Charsets.UTF_8)))
        }
        return NdefMessage(records)
    }

    fun write(tag: Tag, profile: CardProfile): Result<Int> = runCatching {
        val payload = message(profile)
        val bytes = payload.toByteArray().size
        val ndef = Ndef.get(tag)
        if (ndef != null) {
            ndef.connect()
            try {
                require(ndef.isWritable) { "This NFC tag is read-only." }
                require(ndef.maxSize >= bytes) { "This tag needs $bytes bytes but has only ${ndef.maxSize}. Use a larger tag or add a website URL." }
                ndef.writeNdefMessage(payload)
            } finally { ndef.close() }
            bytes
        } else {
            val formatable = NdefFormatable.get(tag) ?: error("This tag does not support NDEF formatting.")
            formatable.connect()
            try { formatable.format(payload) } finally { formatable.close() }
            bytes
        }
    }
}
