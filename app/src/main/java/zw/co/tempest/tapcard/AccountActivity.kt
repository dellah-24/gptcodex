package zw.co.tempest.tapcard

import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.activity.ComponentActivity
import zw.co.tempest.tapcard.databinding.ActivityAccountBinding
import java.util.concurrent.Executors

class AccountActivity : ComponentActivity() {
    private lateinit var binding: ActivityAccountBinding
    private lateinit var session: SessionStore
    private val client = SupabaseClient()
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAccountBinding.inflate(layoutInflater)
        setContentView(binding.root)
        session = SessionStore(this)

        binding.signInButton.setOnClickListener { authenticate(create = false) }
        binding.createAccountButton.setOnClickListener { authenticate(create = true) }
        binding.refreshButton.setOnClickListener { refreshSubscription(showResult = true) }
        binding.signOutButton.setOnClickListener {
            session.signOut()
            AnalyticsTracker(this).track("signed_out")
            render()
        }
        render()
        if (session.isSignedIn) refreshSubscription(showResult = false)
    }

    private fun authenticate(create: Boolean) {
        val email = binding.emailInput.text?.toString()?.trim().orEmpty()
        val password = binding.passwordInput.text?.toString().orEmpty()
        if (!android.util.Patterns.EMAIL_ADDRESS.matcher(email).matches()) {
            binding.emailInput.error = "Enter a valid email address"
            return
        }
        if (password.length < 8) {
            binding.passwordInput.error = "Use at least 8 characters"
            return
        }
        setBusy(true, if (create) "Creating your account…" else "Signing in…")
        executor.execute {
            runCatching { if (create) client.signUp(email, password) else client.signIn(email, password) }
                .onSuccess { result ->
                    runOnUiThread {
                        if (result.emailConfirmationRequired) {
                            setBusy(false, "Check your email to confirm the account, then sign in.")
                        } else {
                            session.saveAuth(result.userId, result.email, result.accessToken, result.refreshToken)
                            AnalyticsTracker(this).track(if (create) "account_created" else "signed_in")
                            render()
                            refreshSubscription(showResult = false)
                        }
                    }
                }
                .onFailure { error -> runOnUiThread { setBusy(false, error.message ?: "Authentication failed.") } }
        }
    }

    private fun refreshSubscription(showResult: Boolean) {
        val userId = session.userId ?: return
        val token = session.accessToken ?: return
        setBusy(true, "Checking subscription…")
        executor.execute {
            runCatching { client.fetchSubscription(userId, token) }
                .recoverCatching {
                    val refreshed = client.refresh(session.refreshToken ?: throw it)
                    session.saveAuth(refreshed.userId, refreshed.email, refreshed.accessToken, refreshed.refreshToken)
                    client.fetchSubscription(refreshed.userId, refreshed.accessToken)
                }
                .onSuccess { value ->
                    session.saveSubscription(value)
                    AnalyticsTracker(this).flush()
                    runOnUiThread {
                        render()
                        if (showResult) toast("Subscription updated")
                    }
                }
                .onFailure { error ->
                    runOnUiThread {
                        render()
                        binding.statusText.text = "Using the last verified plan offline. ${error.message.orEmpty()}"
                    }
                }
        }
    }

    private fun render() {
        val subscription = session.subscription()
        binding.planTitle.text = "${subscription.displayName()} plan"
        binding.planDetails.text = when (subscription.effectivePlan) {
            "business" -> "Up to 50 cards • admin-managed access • priority support"
            "pro" -> "Up to 10 cards • cloud usage analytics • themes"
            else -> "1 card • offline NFC • QR • vCard export"
        }
        binding.authForm.visibility = if (session.isSignedIn) View.GONE else View.VISIBLE
        binding.refreshButton.visibility = if (session.isSignedIn) View.VISIBLE else View.GONE
        binding.signOutButton.visibility = if (session.isSignedIn) View.VISIBLE else View.GONE
        binding.statusText.text = when {
            !client.isConfigured -> "Cloud accounts are disabled in this build. Add SUPABASE_URL and SUPABASE_ANON_KEY when building."
            session.isSignedIn -> "Signed in as ${session.email}. Plan access is cached for seven days for offline use."
            else -> "Sign in to sync your subscription across devices."
        }
        setButtonsEnabled(client.isConfigured)
    }

    private fun setBusy(busy: Boolean, message: String) {
        binding.statusText.text = message
        setButtonsEnabled(!busy && client.isConfigured)
    }

    private fun setButtonsEnabled(enabled: Boolean) {
        binding.signInButton.isEnabled = enabled
        binding.createAccountButton.isEnabled = enabled
        binding.refreshButton.isEnabled = enabled
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
}
