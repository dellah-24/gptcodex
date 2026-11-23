package zw.co.tempest.tapcard

import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
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
    private var waitingForTag = false

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
        binding.writeNfcButton.setOnClickListener { beginNfcWrite() }
        binding.shareButton.setOnClickListener { shareVCard() }
        binding.hceButton.setOnClickListener { showHceHelp() }
    }

    override fun onPause() {
        super.onPause()
        nfcAdapter?.disableReaderMode(this)
    }

    override fun onResume() {
        super.onResume()
        if (waitingForTag) enableReaderMode()
    }

    override fun onTagDiscovered(tag: Tag) {
        val result = NfcTagWriter.write(tag, profile)
        runOnUiThread {
            waitingForTag = false
            nfcAdapter?.disableReaderMode(this)
            result.onSuccess { bytes ->
                binding.nfcStatus.text = "NFC tag written successfully • $bytes bytes"
                toast("Your digital card is now on the NFC tag")
            }.onFailure { error ->
                binding.nfcStatus.text = error.message ?: "Could not write this NFC tag"
                MaterialAlertDialogBuilder(this)
                    .setTitle("NFC write failed")
                    .setMessage(error.message ?: "Try another writable NDEF tag.")
                    .setPositiveButton("OK", null)
                    .show()
            }
        }
    }

    private fun beginNfcWrite() {
        profile = profileFromForm()
        store.save(profile)
        render(profile)
        val adapter = nfcAdapter
        when {
            adapter == null -> toast("This phone does not have NFC. Use the QR code instead.")
            !adapter.isEnabled -> MaterialAlertDialogBuilder(this)
                .setTitle("Turn on NFC")
                .setMessage("Enable NFC, return to TapCard ZW, then tap Write NFC tag again.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Open settings") { _, _ -> startActivity(Intent(Settings.ACTION_NFC_SETTINGS)) }
                .show()
            else -> {
                waitingForTag = true
                enableReaderMode()
                binding.nfcStatus.text = "Ready — hold a writable NFC tag against the back of this phone"
            }
        }
    }

    private fun enableReaderMode() {
        nfcAdapter?.enableReaderMode(
            this,
            this,
            NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V,
            null
        )
    }

    private fun showHceHelp() {
        profile = profileFromForm()
        store.save(profile)
        MaterialAlertDialogBuilder(this)
            .setTitle("Phone-to-phone NFC")
            .setMessage("Your phone can emulate a small NFC card containing your primary website or contact link. Keep the phone unlocked and NFC enabled, then hold the receiving phone near this device. Device support varies, so keep the QR code visible as the universal fallback.")
            .setNegativeButton("Close", null)
            .setPositiveButton("NFC settings") { _, _ -> startActivity(Intent(Settings.ACTION_NFC_SETTINGS)) }
            .show()
    }

    private fun shareVCard() {
        profile = profileFromForm()
        store.save(profile)
        val directory = File(cacheDir, "cards").apply { mkdirs() }
        val file = File(directory, "${profile.name.ifBlank { "tapcard" }.replace(Regex("[^A-Za-z0-9_-]"), "-")}.vcf")
        file.writeText(VCardBuilder.build(profile), Charsets.UTF_8)
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/vcard"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Share digital card"))
    }

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
        binding.nfcStatus.text = when {
            nfcAdapter == null -> "NFC is not available on this phone • QR sharing still works"
            nfcAdapter?.isEnabled == true -> "NFC ready • profile data stays on this device"
            else -> "NFC is turned off • QR sharing still works"
        }
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
}
