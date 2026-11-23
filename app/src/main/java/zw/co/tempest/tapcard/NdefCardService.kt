package zw.co.tempest.tapcard

import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.cardemulation.HostApduService
import android.os.Bundle

class NdefCardService : HostApduService() {
    private enum class FileSelected { NONE, CC, NDEF }
    private var selected = FileSelected.NONE

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        val command = commandApdu ?: return STATUS_FAILED
        if (command.size >= SELECT_AID_PREFIX.size && command.copyOfRange(0, SELECT_AID_PREFIX.size).contentEquals(SELECT_AID_PREFIX)) {
            selected = FileSelected.NONE
            return STATUS_OK
        }
        if (command.contentEquals(SELECT_CC)) {
            selected = FileSelected.CC
            return STATUS_OK
        }
        if (command.contentEquals(SELECT_NDEF)) {
            selected = FileSelected.NDEF
            return STATUS_OK
        }
        if (command.size >= 5 && command[0] == 0x00.toByte() && command[1] == 0xB0.toByte()) {
            val offset = ((command[2].toInt() and 0xFF) shl 8) or (command[3].toInt() and 0xFF)
            val requested = command[4].toInt() and 0xFF
            val file = when (selected) {
                FileSelected.CC -> CAPABILITY_CONTAINER
                FileSelected.NDEF -> ndefFile()
                FileSelected.NONE -> return STATUS_FAILED
            }
            if (offset > file.size) return STATUS_FAILED
            val end = minOf(file.size, offset + requested)
            return file.copyOfRange(offset, end) + STATUS_OK
        }
        return STATUS_FAILED
    }

    override fun onDeactivated(reason: Int) { selected = FileSelected.NONE }

    private fun ndefFile(): ByteArray {
        val uri = ProfileStore(this).load().primaryUri()
        val message = NdefMessage(arrayOf(NdefRecord.createUri(uri))).toByteArray()
        return byteArrayOf((message.size shr 8).toByte(), message.size.toByte()) + message
    }

    companion object {
        private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        private val SELECT_AID_PREFIX = hex("00A4040007D2760000850101")
        private val SELECT_CC = hex("00A4000C02E103")
        private val SELECT_NDEF = hex("00A4000C02E104")
        private val STATUS_OK = hex("9000")
        private val STATUS_FAILED = hex("6A82")
        private val CAPABILITY_CONTAINER = hex("000F2000FF00FF0406E1040FFF0000")
    }
}
