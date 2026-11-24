package zw.co.tempest.tapcard

import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.nfc.NfcAdapter
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.View
import android.widget.EditText
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.FileProvider
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import zw.co.tempest.tapcard.databinding.ActivityMainBinding
import java.io.File
import java.util.concurrent.Executors

class MainActivity : ComponentActivity() {
    private lateinit var binding: ActivityMainBinding
    private lateinit var store: ProfileStore
    private lateinit var session: SessionStore
    private lateinit var analytics: AnalyticsTracker
    private val cloud = SupabaseClient()
    private val executor = Executors.newSingleThreadExecutor()
    private var profile = CardProfile()
    private var nfcAdapter: NfcAdapter? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        store = ProfileStore(this)
        session = SessionStore(this)
        analytics = AnalyticsTracker(this)
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
            analytics.track("card_saved", profile.id)
            render(profile)
            activateCard()
            if (profile.isPublished) syncCardToCloud(profile, published = true, showResult = false)
            if (!profile.isPublished && profile.website.isBlank() && profile.linkedIn.isBlank()) {
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
        binding.publishButton.setOnClickListener { togglePublishedProfile() }
        binding.shareLinkButton.setOnClickListener { sharePublicLink() }
        binding.accountButton.setOnClickListener { startActivity(Intent(this, AccountActivity::class.java)) }
        binding.nfcStatus.setOnClickListener {
            if (nfcAdapter != null && nfcAdapter?.isEnabled != true) {
                startActivity(Intent(Settings.ACTION_NFC_SETTINGS))
            }
        }
    }

    override fun onResume() {
        super.onResume()
        activateCard()
        updatePlanStatus()
        analytics.track("app_opened", profile.id)
        analytics.flush()
        if (session.isSignedIn && cloud.isConfigured) {
            store.loadAll().filter { it.isPublished }.forEach {
                syncCardToCloud(it, published = true, showResult = false)
            }
        }
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
            profile.isPublished -> "NFC is live • opens your hosted contact and lead-capture page"
            profile.website.isBlank() && profile.linkedIn.isBlank() -> "NFC is live • publish a recipient profile for the best tap experience"
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
        analytics.track("vcard_shared", profile.id)
    }

    private fun sharePublicLink() {
        val url = profile.sharingUri(BuildConfig.PUBLIC_PROFILE_BASE_URL)
        if (!profile.isPublished || !url.startsWith("https://")) {
            toast("Publish this card first")
            return
        }
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, "Connect with ${profile.name}: $url")
        }, "Share public card"))
        analytics.track("public_link_shared", profile.id)
    }

    private fun togglePublishedProfile() {
        val candidate = profileFromForm()
        if (candidate.name.isBlank()) {
            binding.nameInput.error = "Add your name"
            return
        }
        if (!session.isSignedIn) {
            toast("Sign in before publishing a profile")
            startActivity(Intent(this, AccountActivity::class.java))
            return
        }
        if (!candidate.isPublished && session.subscription().effectivePlan == "free") {
            toast("Hosted profiles are available on Pro and Business plans")
            startActivity(Intent(this, AccountActivity::class.java))
            return
        }
        if (!cloud.isConfigured || !BuildConfig.PUBLIC_PROFILE_BASE_URL.startsWith("https://")) {
            toast("Hosted profiles are not configured in this build")
            return
        }
        profile = candidate
        store.save(profile)
        syncCardToCloud(profile, published = !profile.isPublished, showResult = true)
    }

    private fun syncCardToCloud(card: CardProfile, published: Boolean, showResult: Boolean) {
        val userId = session.userId ?: return
        val token = session.accessToken ?: return
        if (showResult) {
            binding.publishButton.isEnabled = false
            binding.publishButton.text = if (published) "Publishing…" else "Unpublishing…"
        }
        executor.execute {
            runCatching { cloud.upsertCard(card, userId, token, published) }
                .recoverCatching {
                    val refreshed = cloud.refresh(session.refreshToken ?: throw it)
                    session.saveAuth(refreshed.userId, refreshed.email, refreshed.accessToken, refreshed.refreshToken)
                    cloud.upsertCard(card, refreshed.userId, refreshed.accessToken, published)
                }
                .onSuccess {
                    runOnUiThread {
                        val updated = card.copy(isPublished = published)
                        store.save(updated, makeActive = false)
                        if (profile.id == updated.id) {
                            profile = updated
                            render(updated)
                            activateCard()
                        }
                        analytics.track(if (published) "card_published" else "card_unpublished", card.id)
                        if (showResult) toast(if (published) "Public profile is live" else "Public profile unpublished")
                    }
                }
                .onFailure { error -> runOnUiThread {
                    render(profile)
                    if (showResult) toast(error.message ?: "Could not update public profile")
                } }
        }
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
            runCatching { store.create(label, session.subscription().maxCards) }
                .onSuccess {
                    switchTo(it)
                    analytics.track("card_created", it.id)
                    toast("New card created")
                }
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
        runCatching { store.duplicate(profileFromForm(), session.subscription().maxCards) }
            .onSuccess {
                switchTo(it)
                analytics.track("card_duplicated", it.id)
                toast("Card duplicated")
            }
            .onFailure { toast(it.message ?: "Could not duplicate card") }
    }

    private fun deleteCard() {
        if (profile.isPublished) {
            toast("Unpublish this card before deleting it")
            return
        }
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
        analytics.track("card_theme_changed", profile.id)
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
        analytics.track("card_selected", card.id)
    }

    private fun updatePlanStatus() {
        val value = session.subscription()
        val account = session.email?.let { " • $it" }.orEmpty()
        binding.accountButton.text = "${value.displayName()} plan • ${value.maxCards} card limit$account"
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
        instagram = binding.instagramInput.text?.toString()?.trim().orEmpty(),
        whatsapp = binding.whatsappInput.text?.toString()?.trim().orEmpty(),
        bookingUrl = binding.bookingInput.text?.toString()?.trim().orEmpty(),
        bio = binding.bioInput.text?.toString()?.trim().orEmpty(),
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
        instagramInput.setText(value.instagram)
        whatsappInput.setText(value.whatsapp)
        bookingInput.setText(value.bookingUrl)
        bioInput.setText(value.bio)
        addressInput.setText(value.address)
    }

    private fun render(value: CardProfile) = with(binding) {
        cardSwitcherButton.text = "${value.label} ▾"
        publishButton.isEnabled = true
        publishButton.text = if (value.isPublished) "Unpublish recipient profile" else "Publish recipient profile"
        shareLinkButton.visibility = if (value.isPublished && BuildConfig.PUBLIC_PROFILE_BASE_URL.startsWith("https://")) View.VISIBLE else View.GONE
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
        previewUrl.text = value.sharingUri(BuildConfig.PUBLIC_PROFILE_BASE_URL)
        val qrContent = if (value.isPublished && BuildConfig.PUBLIC_PROFILE_BASE_URL.startsWith("https://")) {
            value.sharingUri(BuildConfig.PUBLIC_PROFILE_BASE_URL)
        } else VCardBuilder.build(value)
        qrCode.setImageBitmap(QrCodeGenerator.create(qrContent))
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
