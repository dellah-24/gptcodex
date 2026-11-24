package zw.co.tempest.tapcard

import android.content.Intent
import android.nfc.NfcAdapter
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.FileProvider
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import zw.co.tempest.tapcard.databinding.ActivityMainBinding
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var binding: ActivityMainBinding
    private lateinit var store: ProfileStore
    private var profile = CardProfile()
    private var nfcAdapter: NfcAdapter? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        store = ProfileStore(this)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
        profile = store.load()
        populateForm(profile)
        render(profile)

        binding.saveButton.setOnClickListener {
            val candidate = profileFromForm()
            if (candidate.name.isBlank()) {
                binding.nameInput.error = "Add your name"
                return@setOnClickListener
            }
            profile = candidate
            store.save(profile)
            render(profile)
            activateCard()
            if (profile.website.isBlank() && profile.linkedIn.isBlank()) {
                MaterialAlertDialogBuilder(this)
                    .setTitle("Add a profile link")
                    .setMessage("Your NFC card is active, but adding a website or public profile URL gives the other phone a complete card page to open.")
                    .setPositiveButton("OK", null)
                    .show()
            } else toast("Card saved and NFC sharing activated")
        }
        binding.shareButton.setOnClickListener { shareVCard() }
        binding.nfcStatus.setOnClickListener {
            if (nfcAdapter != null && nfcAdapter?.isEnabled != true) {
                startActivity(Intent(Settings.ACTION_NFC_SETTINGS))
            }
        }
    }

    override fun onResume() {
        super.onResume()
        activateCard()
    }

    override fun onPause() {
        store.setSharingEnabled(false)
        super.onPause()
    }

    private fun activateCard() {
        profile = store.load()
        val active = profile.name.isNotBlank() && nfcAdapter?.isEnabled == true
        store.setSharingEnabled(active)
        updateNfcStatus()
    }

    private fun updateNfcStatus() {
        binding.nfcStatus.text = when {
            nfcAdapter == null -> "This phone does not support NFC • QR sharing is available"
            nfcAdapter?.isEnabled != true -> "NFC is off • tap here to open NFC settings"
            profile.name.isBlank() -> "Complete and save your card to activate NFC"
            profile.website.isBlank() && profile.linkedIn.isBlank() -> "NFC is live • add a public profile URL for the best tap experience"
            else -> "NFC card is live • tap another unlocked phone against this one"
        }
    }

    private fun shareVCard() {
        profile = profileFromForm()
        store.save(profile)
        val filename = "${profile.name.ifBlank { "tapcard" }.replace(Regex("[^A-Za-z0-9_-]"), "-")}.vcf"
        val directory = File(cacheDir, "cards").apply { mkdirs() }
        val file = File(directory, filename).apply { writeText(VCardBuilder.build(profile), Charsets.UTF_8) }
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

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
}
