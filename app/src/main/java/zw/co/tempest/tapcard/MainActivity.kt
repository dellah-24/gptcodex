package zw.co.tempest.tapcard

import android.content.Intent
import android.net.Uri
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.FileProvider
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import zw.co.tempest.tapcard.databinding.ActivityMainBinding
import java.io.File

class MainActivity : ComponentActivity(), NfcAdapter.ReaderCallback {
    private lateinit var binding: ActivityMainBinding
    private lateinit var store: ProfileStore
    private var profile = CardProfile()
    private var nfcAdapter: NfcAdapter? = null
    private var waitingToReceive = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        store = ProfileStore(this)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
        profile = store.load()
        populateForm(profile)
        render(profile)
        updateNfcStatus()

        binding.saveButton.setOnClickListener {
            val candidate = profileFromForm()
            if (candidate.name.isBlank()) {
                binding.nameInput.error = "Add your name"
                return@setOnClickListener
            }
            profile = candidate
            store.save(profile)
            render(profile)
            toast("Card saved on this device")
        }
        binding.shareNfcButton.setOnClickListener { togglePhoneSharing() }
        binding.receiveNfcButton.setOnClickListener { beginReceiving() }
        binding.shareButton.setOnClickListener { shareVCard() }
    }

    override fun onPause() {
        super.onPause()
        if (waitingToReceive) nfcAdapter?.disableReaderMode(this)
    }

    override fun onResume() {
        super.onResume()
        if (waitingToReceive) enableReaderMode()
        updateNfcStatus()
    }

    override fun onTagDiscovered(tag: Tag) {
        val result = runCatching {
            val ndef = Ndef.get(tag) ?: error("The other phone did not expose an NDEF card.")
            ndef.connect()
            try { ndef.ndefMessage ?: ndef.cachedNdefMessage ?: error("No digital card was received.") }
            finally { ndef.close() }
        }
        runOnUiThread {
            waitingToReceive = false
            nfcAdapter?.disableReaderMode(this)
            result.onSuccess { message ->
                val vCard = message.records.firstOrNull { it.toMimeType()?.equals("text/vcard", true) == true }
                    ?.payload?.toString(Charsets.UTF_8)
                val uri = message.records.firstNotNullOfOrNull { record -> record.toUri()?.takeIf { it != Uri.EMPTY } }
                when {
                    !vCard.isNullOrBlank() -> showReceivedCard(vCard, uri)
                    uri != null -> showReceivedLink(uri)
                    else -> showReceiveError("The NFC message did not contain a TapCard contact.")
                }
            }.onFailure { showReceiveError(it.message ?: "Could not receive the NFC card.") }
        }
    }

    private fun togglePhoneSharing() {
        profile = profileFromForm()
        if (profile.name.isBlank()) {
            binding.nameInput.error = "Add your name before sharing"
            return
        }
        store.save(profile)
        render(profile)
        val adapter = nfcAdapter
        when {
            adapter == null -> toast("This phone does not support NFC. Use the QR code instead.")
            !adapter.isEnabled -> showEnableNfcDialog()
            else -> {
                waitingToReceive = false
                adapter.disableReaderMode(this)
                val enabled = !store.isSharingEnabled()
                store.setSharingEnabled(enabled)
                updateNfcStatus()
                if (enabled) {
                    MaterialAlertDialogBuilder(this)
                        .setTitle("Ready to share")
                        .setMessage("On the second phone, open TapCard ZW and tap Receive card. Keep both phones unlocked, then touch their NFC areas together.")
                        .setPositiveButton("Got it", null)
                        .show()
                }
            }
        }
    }

    private fun beginReceiving() {
        val adapter = nfcAdapter
        when {
            adapter == null -> toast("This phone does not support NFC. Scan the QR code instead.")
            !adapter.isEnabled -> showEnableNfcDialog()
            else -> {
                store.setSharingEnabled(false)
                waitingToReceive = true
                enableReaderMode()
                updateNfcStatus()
                MaterialAlertDialogBuilder(this)
                    .setTitle("Ready to receive")
                    .setMessage("On the sending phone, tap Share by NFC. Keep both phones unlocked, then touch their NFC areas together until this phone responds.")
                    .setNegativeButton("Cancel") { _, _ -> stopReceiving() }
                    .setPositiveButton("Keep listening", null)
                    .show()
            }
        }
    }

    private fun stopReceiving() {
        waitingToReceive = false
        nfcAdapter?.disableReaderMode(this)
        updateNfcStatus()
    }

    private fun enableReaderMode() {
        nfcAdapter?.enableReaderMode(
            this,
            this,
            NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B,
            Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250) }
        )
    }

    private fun showReceivedCard(vCard: String, uri: Uri?) {
        binding.nfcStatus.text = "Digital card received successfully"
        val dialog = MaterialAlertDialogBuilder(this)
            .setTitle("Card received")
            .setMessage("Save this person to contacts or open their primary link.")
            .setNegativeButton("Close", null)
            .setPositiveButton("Save contact") { _, _ -> openVCard(vCard) }
        if (uri != null) dialog.setNeutralButton("Open link") { _, _ -> openUri(uri) }
        dialog.show()
    }

    private fun showReceivedLink(uri: Uri) {
        binding.nfcStatus.text = "NFC link received"
        MaterialAlertDialogBuilder(this)
            .setTitle("Link received")
            .setMessage(uri.toString())
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Open") { _, _ -> openUri(uri) }
            .show()
    }

    private fun showReceiveError(message: String) {
        binding.nfcStatus.text = message
        MaterialAlertDialogBuilder(this)
            .setTitle("NFC transfer failed")
            .setMessage("$message\n\nKeep both phones unlocked and try touching their NFC areas together again.")
            .setPositiveButton("OK", null)
            .show()
    }

    private fun openVCard(vCard: String) {
        val file = cardFile("received-tapcard.vcf").apply { writeText(vCard, Charsets.UTF_8) }
        val content = FileProvider.getUriForFile(this, "$packageName.files", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(content, "text/vcard")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runCatching { startActivity(intent) }.onFailure { shareFile(file, "Save received contact") }
    }

    private fun openUri(uri: Uri) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, uri)) }
            .onFailure { toast("No app can open this link") }
    }

    private fun showEnableNfcDialog() {
        MaterialAlertDialogBuilder(this)
            .setTitle("Turn on NFC")
            .setMessage("Both phones need NFC enabled for tap sharing.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Open settings") { _, _ -> startActivity(Intent(Settings.ACTION_NFC_SETTINGS)) }
            .show()
    }

    private fun shareVCard() {
        profile = profileFromForm()
        store.save(profile)
        val filename = "${profile.name.ifBlank { "tapcard" }.replace(Regex("[^A-Za-z0-9_-]"), "-")}.vcf"
        val file = cardFile(filename).apply { writeText(VCardBuilder.build(profile), Charsets.UTF_8) }
        shareFile(file, "Share digital card")
    }

    private fun shareFile(file: File, title: String) {
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/vcard"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, title))
    }

    private fun cardFile(name: String): File = File(cacheDir, "cards").apply { mkdirs() }.resolve(name)

    private fun profileFromForm() = CardProfile(
        name = binding.nameInput.text?.toString()?.trim().orEmpty(),
        title = binding.titleInput.text?.toString()?.trim().orEmpty(),
        company = binding.companyInput.text?.toString()?.trim().orEmpty(),
        phone = binding.phoneInput.text?.toString()?.trim().orEmpty(),
        email = binding.emailInput.text?.toString()?.trim().orEmpty(),
        website = binding.websiteInput.text?.toString()?.trim().orEmpty(),
        linkedIn = binding.linkedinInput.text?.toString()?.trim().orEmpty(),
        address = binding.addressInput.text?.toString()?.trim().orEmpty()
    )

    private fun populateForm(value: CardProfile) = with(binding) {
        nameInput.setText(value.name)
        titleInput.setText(value.title)
        companyInput.setText(value.company)
        phoneInput.setText(value.phone)
        emailInput.setText(value.email)
        websiteInput.setText(value.website)
        linkedinInput.setText(value.linkedIn)
        addressInput.setText(value.address)
    }

    private fun render(value: CardProfile) = with(binding) {
        previewName.text = value.name.ifBlank { "Your Name" }
        previewRole.text = listOf(value.title, value.company).filter { it.isNotBlank() }.joinToString(" • ").ifBlank { "Role • Company" }
        previewContact.text = listOf(value.phone, value.email).filter { it.isNotBlank() }.joinToString(" • ").ifBlank { "phone • email" }
        previewUrl.text = value.primaryUri()
        qrCode.setImageBitmap(QrCodeGenerator.create(VCardBuilder.build(value)))
    }

    private fun updateNfcStatus() {
        val sharing = store.isSharingEnabled()
        binding.shareNfcButton.text = if (sharing) "Stop NFC sharing" else "Share by NFC"
        binding.nfcStatus.text = when {
            nfcAdapter == null -> "NFC is unavailable • QR sharing still works"
            nfcAdapter?.isEnabled != true -> "NFC is turned off • both phones need NFC enabled"
            waitingToReceive -> "Receiving mode active • touch the two phones together"
            sharing -> "Sharing mode active • touch the two unlocked phones together"
            else -> "NFC ready • choose Share or Receive"
        }
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
}
