// The "Choose your password" page (set-password.html).
//
// Opened from an emailed link. The link uses the implicit flow, so the
// session sits right in the URL (#access_token=...&type=recovery). That means
// it works on any device, unlike the app's own reset links which use PKCE and
// only work on the phone that asked.
//
// supabase-js picks the session up from the URL, the person types a new
// password, we call auth.updateUser and sign them out again so they can sign
// in on the app.
//
// persistSession is off, so this never leaves anyone signed in and doesn't
// interfere with the console's own session.

(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);

  function setError(el, message) {
    el.textContent = message || "";
    el.hidden = !message;
  }

  // Supabase also reports used/expired links in the URL, e.g.
  // #error=access_denied&error_code=otp_expired&error_description=...
  const params = new URLSearchParams(location.hash.slice(1) || location.search.slice(1));
  const linkError = params.get("error_code") || params.get("error");

  const cfg = window.ARGUS_CONFIG || {};
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: true,
      flowType: "implicit",
    },
  });

  function badLink(code) {
    $("checking").hidden = true;
    $("password-form").hidden = true;
    setError($("link-error"), code === "otp_expired"
      ? "This link has expired or was already used. Open Argus Shield, tap \"Forgot password?\" " +
        "and enter your email to get a new one."
      : "This link isn't valid. Open Argus Shield, tap \"Forgot password?\" and enter your email " +
        "to get a new one.");
  }

  document.querySelectorAll("[data-toggle-password]").forEach((button) => {
    button.addEventListener("click", () => {
      const input = $(button.dataset.togglePassword);
      const hidden = input.type === "password";
      input.type = hidden ? "text" : "password";
      button.textContent = hidden ? "Hide" : "Show";
    });
  });

  const form = $("password-form");
  form.addEventListener("input", () => setError($("password-error"), ""));

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const password = $("password").value;
    const errorBox = $("password-error");
    if (password.length < 8 || !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
      setError(errorBox, "Use at least 8 characters, with letters and numbers.");
      return;
    }
    if (password !== $("password-again").value) {
      setError(errorBox, "The two passwords are not the same.");
      return;
    }

    const button = $("password-submit");
    button.disabled = true;
    button.textContent = "Saving…";
    try {
      const { error } = await sb.auth.updateUser({ password });
      if (error) {
        if (error.code === "same_password") throw new Error("Choose a password you haven't used before.");
        if (error.code === "weak_password") throw new Error("That password is too weak. Choose a longer one.");
        if (error.status === 401 || error.status === 403) {
          throw new Error("This link has expired. Open Argus Shield, tap \"Forgot password?\" to get a new one.");
        }
        throw new Error(error.message || "Could not save the password. Try again.");
      }
      await sb.auth.signOut({ scope: "local" });
      form.hidden = true;
      $("password-done").hidden = false;
    } catch (e) {
      setError(errorBox, e.message);
      button.disabled = false;
      button.textContent = "Save password";
    }
  });

  (async function start() {
    if (linkError) return badLink(params.get("error_code"));
    const { data } = await sb.auth.getSession();
    // we have the tokens in memory now, so get them out of the address bar
    history.replaceState(null, "", location.pathname);
    const session = data && data.session;
    if (!session) return badLink(null);
    $("checking").hidden = true;
    $("password-who").textContent = `Account: ${session.user.email}`;
    form.hidden = false;
    $("password").focus();
  })();
})();
