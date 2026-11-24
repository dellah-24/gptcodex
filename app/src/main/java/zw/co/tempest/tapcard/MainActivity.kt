package zw.co.tempest.tapcard

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.nfc.NfcAdapter
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.widget.EditText
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
        binding.cardSwitcherButton.setOnClickListener { showCardPicker() }
        binding.newCardButton.setOnClickListener { createCard() }
        binding.cardMenuButton.setOnClickListener { showCardMenu() }
        binding.cardColorButton.setOnClickListener { cycleCardColour() }
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

    private fun showCardPicker() {
        saveCurrentSilently()
        val cards = store.loadAll()
        val labels = cards.map { card ->
            listOf(card.label, card.name).filter { it.isNotBlank() }.joinToString(" — ")
        }.toTypedArray()
        val selected = cards.indexOfFirst { it.id == profile.id }.coerceAtLeast(0)
        MaterialAlertDialogBuilder(this)
            .setTitle("Choose active NFC card")
            .setSingleChoiceItems(labels, selected) { dialog, index ->
                switchTo(store.setActive(cards[index].id))
                dialog.dismiss()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun createCard() {
        promptForLabel("New card", "Work") { label ->
            runCatching { store.create(label) }
                .onSuccess { switchTo(it); toast("New card created") }
                .onFailure { toast(it.message ?: "Could not create card") }
        }
    }

    private fun showCardMenu() {
        saveCurrentSilently()
        MaterialAlertDialogBuilder(this)
            .setTitle(profile.label)
            .setItems(arrayOf("Rename card", "Duplicate card", "Delete card")) { _, index ->
                when (index) {
                    0 -> renameCard()
                    1 -> duplicateCard()
                    2 -> deleteCard()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun renameCard() {
        promptForLabel("Rename card", profile.label) { label ->
            profile = profile.copy(label = label)
            store.save(profile)
            render(profile)
        }
    }

    private fun duplicateCard() {
        runCatching { store.duplicate(profileFromForm()) }
            .onSuccess { switchTo(it); toast("Card duplicated") }
            .onFailure { toast(it.message ?: "Could not duplicate card") }
    }

    private fun deleteCard() {
        if (store.loadAll().size <= 1) {
            toast("Create another card before deleting this one")
            return
        }
        MaterialAlertDialogBuilder(this)
            .setTitle("Delete ${profile.label}?")
            .setMessage("This removes only this locally stored card. Other cards are not changed.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Delete") { _, _ ->
                runCatching { store.delete(profile.id) }
                    .onSuccess { switchTo(it); toast("Card deleted") }
                    .onFailure { toast(it.message ?: "Could not delete card") }
            }
            .show()
    }

    private fun cycleCardColour() {
        val keys = THEMES.keys.toList()
        val next = keys[(keys.indexOf(profile.theme).coerceAtLeast(0) + 1) % keys.size]
        profile = profileFromForm().copy(theme = next)
        store.save(profile)
        render(profile)
    }

    private fun promptForLabel(title: String, initial: String, action: (String) -> Unit) {
        val input = EditText(this).apply {
            setText(initial)
            selectAll()
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS
            setPadding(dp(24), dp(8), dp(24), dp(8))
        }
        MaterialAlertDialogBuilder(this)
            .setTitle(title)
            .setView(input)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Save") { _, _ -> action(input.text.toString().trim().ifBlank { "Card" }) }
            .show()
    }

    private fun switchTo(card: CardProfile) {
        profile = card
        populateForm(card)
        render(card)
        activateCard()
    }

    private fun saveCurrentSilently() {
        profile = profileFromForm()
        store.save(profile)
    }

    private fun profileFromForm() = profile.copy(
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
        cardSwitcherButton.text = "${value.label} ▾"
        cardColorButton.text = "Card colour: ${THEMES[value.theme]?.name ?: "Green"}"
        val theme = THEMES[value.theme] ?: THEMES.getValue("green")
        cardPreview.background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.parseColor(theme.start), Color.parseColor(theme.end))
        ).apply { cornerRadius = dp(28).toFloat() }
        cardPreview.setPadding(dp(24), dp(24), dp(24), dp(24))
        previewName.text = value.name.ifBlank { "Your Name" }
        previewRole.text = listOf(value.title, value.company).filter { it.isNotBlank() }.joinToString(" • ").ifBlank { "Role • Company" }
        previewContact.text = listOf(value.phone, value.email).filter { it.isNotBlank() }.joinToString(" • ").ifBlank { "phone • email" }
        previewUrl.text = value.primaryUri()
        qrCode.setImageBitmap(QrCodeGenerator.create(VCardBuilder.build(value)))
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private data class CardTheme(val name: String, val start: String, val end: String)

    companion object {
        private val THEMES = linkedMapOf(
            "green" to CardTheme("Green", "#08755C", "#064D3F"),
            "blue" to CardTheme("Blue", "#1769AA", "#0D3D73"),
            "purple" to CardTheme("Purple", "#7048A8", "#3E2868"),
            "charcoal" to CardTheme("Charcoal", "#38464A", "#182326")
        )
    }
}
