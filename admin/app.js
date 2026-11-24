const config = window.TAPCARD_CONFIG || {};
const configured = config.supabaseUrl && !config.supabaseUrl.includes("YOUR_PROJECT") && config.supabaseAnonKey && !config.supabaseAnonKey.includes("YOUR_PUBLIC");
const client = configured ? supabase.createClient(config.supabaseUrl, config.supabaseAnonKey) : null;
const $ = (id) => document.getElementById(id);
let users = [];

const escapeHtml = (value = "") => String(value).replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[c]);
const dateText = (value) => value ? new Intl.DateTimeFormat(undefined, {dateStyle:"medium"}).format(new Date(value)) : "—";
const toIso = (value) => value ? new Date(value).toISOString() : null;
const metricLabels = {total_users:"Total users",active_paid:"Active paid",trials:"Trials",past_due:"Past due",events_7d:"Events · 7 days",active_users_30d:"Active · 30 days",open_tickets:"Open tickets"};

async function requireAdmin() {
  const {data:{session}} = await client.auth.getSession();
  if (!session) return false;
  const {data, error} = await client.from("tapcard_profiles").select("role,email").eq("user_id", session.user.id).single();
  if (error || data?.role !== "admin") {
    await client.auth.signOut();
    throw new Error("This account does not have administrator access.");
  }
  return true;
}

async function loadDashboard() {
  $("dashboardMessage").textContent = "Refreshing platform data…";
  const [metricResult, userResult, eventResult, ticketResult] = await Promise.all([
    client.rpc("tapcard_admin_dashboard_metrics"),
    client.from("tapcard_admin_user_overview").select("*").order("created_at", {ascending:false}).limit(500),
    client.from("tapcard_analytics_events").select("event_name,user_id,created_at,metadata").order("created_at", {ascending:false}).limit(30),
    client.from("tapcard_support_tickets").select("id,subject,message,status,user_id,created_at").neq("status","resolved").order("created_at", {ascending:true}).limit(30)
  ]);
  const failure = [metricResult,userResult,eventResult,ticketResult].find(result => result.error);
  if (failure) throw failure.error;
  renderMetrics(metricResult.data || {});
  users = userResult.data || [];
  renderUsers(users);
  renderActivity(eventResult.data || []);
  renderTickets(ticketResult.data || []);
  $("dashboardMessage").textContent = `Updated ${new Date().toLocaleString()}`;
}

function renderMetrics(values) {
  $("metrics").innerHTML = Object.entries(metricLabels).map(([key,label]) => `<article class="metric"><span>${escapeHtml(label)}</span><strong>${Number(values[key] || 0).toLocaleString()}</strong></article>`).join("");
}

function renderUsers(values) {
  $("usersBody").innerHTML = values.map(user => `<tr>
    <td><strong>${escapeHtml(user.display_name || user.email)}</strong><small>${escapeHtml(user.email)}${user.company_name ? " · " + escapeHtml(user.company_name) : ""}</small></td>
    <td><span class="pill plan-${escapeHtml(user.plan)}">${escapeHtml(user.plan)}</span></td>
    <td>${escapeHtml(user.status)}</td><td>${dateText(user.trial_ends_at || user.current_period_end)}</td>
    <td>${user.last_active_at ? dateText(user.last_active_at) : "Never"}<small>${Number(user.event_count || 0).toLocaleString()} events</small></td>
    <td><button class="small edit-subscription" data-user="${escapeHtml(user.user_id)}">Manage</button></td>
  </tr>`).join("") || `<tr><td colspan="6">No customers found.</td></tr>`;
  document.querySelectorAll(".edit-subscription").forEach(button => button.addEventListener("click", () => openSubscription(button.dataset.user)));
}

function renderActivity(values) {
  $("activity").innerHTML = values.map(item => `<article><strong>${escapeHtml(item.event_name.replaceAll("_"," "))}</strong><span>${escapeHtml(item.user_id.slice(0,8))} · ${new Date(item.created_at).toLocaleString()}</span></article>`).join("") || "<p>No synced activity yet.</p>";
}

function renderTickets(values) {
  $("tickets").innerHTML = values.map(item => `<article><strong>${escapeHtml(item.subject)}</strong><span>${escapeHtml(item.status)} · ${dateText(item.created_at)}</span><p>${escapeHtml(item.message)}</p><button class="small resolve-ticket" data-ticket="${escapeHtml(item.id)}">Mark resolved</button></article>`).join("") || "<p>No open tickets.</p>";
  document.querySelectorAll(".resolve-ticket").forEach(button => button.addEventListener("click", async () => {
    button.disabled = true;
    const {error} = await client.from("tapcard_support_tickets").update({status:"resolved",updated_at:new Date().toISOString()}).eq("id",button.dataset.ticket);
    if (error) showError(error); else loadDashboard().catch(showError);
  }));
}

function openSubscription(userId) {
  const user = users.find(item => item.user_id === userId);
  if (!user) return;
  $("targetUserId").value = user.user_id;
  $("selectedUser").textContent = user.email;
  $("plan").value = user.plan;
  $("status").value = user.status;
  $("trialEnds").value = user.trial_ends_at ? user.trial_ends_at.slice(0,16) : "";
  $("periodEnd").value = user.current_period_end ? user.current_period_end.slice(0,16) : "";
  $("notes").value = "";
  $("subscriptionDialog").showModal();
}

function showError(error) { $("dashboardMessage").textContent = error?.message || String(error); }

$("loginForm").addEventListener("submit", async event => {
  event.preventDefault();
  if (!client) { $("loginMessage").textContent = "Configure Supabase in config.js before deployment."; return; }
  $("loginMessage").textContent = "Signing in…";
  const {error} = await client.auth.signInWithPassword({email:$("email").value.trim(),password:$("password").value});
  if (error) { $("loginMessage").textContent = error.message; return; }
  try { await showAuthenticated(); } catch (e) { $("loginMessage").textContent = e.message; }
});

$("signOut").addEventListener("click", async () => { await client.auth.signOut(); location.reload(); });
$("cancelDialog").addEventListener("click", () => $("subscriptionDialog").close());
$("userSearch").addEventListener("input", event => {
  const query = event.target.value.toLowerCase();
  renderUsers(users.filter(user => [user.email,user.display_name,user.company_name].some(value => (value || "").toLowerCase().includes(query))));
});
$("subscriptionForm").addEventListener("submit", async event => {
  event.preventDefault();
  const plan = $("plan").value;
  const status = $("status").value;
  const trial = toIso($("trialEnds").value);
  const period = toIso($("periodEnd").value);
  if (plan !== "free" && !trial && !period) { alert("Paid plans need a trial end or current period end date."); return; }
  const {error} = await client.rpc("tapcard_admin_set_subscription", {
    target_user_id:$("targetUserId").value,new_plan:plan,new_status:status,
    new_trial_ends_at:trial,new_period_end:period,admin_notes:$("notes").value
  });
  if (error) { alert(error.message); return; }
  $("subscriptionDialog").close();
  loadDashboard().catch(showError);
});

async function showAuthenticated() {
  await requireAdmin();
  $("loginPanel").classList.add("hidden");
  $("dashboard").classList.remove("hidden");
  $("signOut").classList.remove("hidden");
  await loadDashboard();
}

if (!configured) $("loginMessage").textContent = "Deployment setup required: configure the public Supabase URL and anon key.";
else requireAdmin().then(ok => { if (ok) showAuthenticated().catch(showError); }).catch(error => { $("loginMessage").textContent = error.message; });
