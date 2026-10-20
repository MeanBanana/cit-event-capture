// Argus Shield admin console (root administrator only).
//
//   sign in  username (or email) + password -> Supabase Auth; then
//            current_admin() must say admin_type 'root', otherwise the
//            session is ended at once ("only the root administrator").
//   list     list_admins()                         (root only, checked in SQL)
//   create   Edge Function create-admin            (root only, checked there;
//            with a temporary password the new admin must change at their
//            first sign-in to the app)
//   station  set_admin_station(userid, station)    (root only, checked in SQL)
//
// Every rule is enforced by the database / Edge Function; the checks here
// only give clear messages.

(function () {
  "use strict";

  const cfg = window.ARGUS_CONFIG || {};
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: { persistSession: true, autoRefreshToken: true },
  });

  const $ = (id) => document.getElementById(id);
  const views = { login: $("login-view"), console: $("console-view") };
  let admins = [];
  let me = null;

  // ------------------------------------------------------------ helpers
  function show(view) {
    views.login.hidden = view !== "login";
    views.console.hidden = view !== "console";
  }

  function setError(el, message) {
    el.textContent = message || "";
    el.hidden = !message;
  }

  let toastTimer;
  function toast(message) {
    const el = $("toast");
    el.textContent = message;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (el.hidden = true), 3200);
  }

  function busy(button, isBusy, label) {
    if (isBusy) {
      button.dataset.label = button.textContent;
      button.textContent = label;
      button.disabled = true;
    } else {
      button.textContent = button.dataset.label || button.textContent;
      button.disabled = false;
    }
  }

  /** Readable message from a Supabase / Edge Function error. */
  async function messageOf(error, fallback) {
    if (!error) return fallback;
    try {
      // Edge Function errors carry the response: { error: "..." }
      if (error.context && typeof error.context.json === "function") {
        const body = await error.context.json();
        if (body && body.error) return body.error;
      }
    } catch (_) { /* not JSON */ }
    if (error.message && !/^Edge Function returned/i.test(error.message)) return error.message;
    return fallback;
  }

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null) continue;
      if (k === "class") node.className = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v);
    }
    for (const child of children) {
      if (child == null) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  const dateFmt = new Intl.DateTimeFormat("en-ZA", { day: "numeric", month: "short", year: "numeric" });
  const timeFmt = new Intl.DateTimeFormat("en-ZA", { hour: "2-digit", minute: "2-digit" });
  function when(value) {
    if (!value) return null;
    const d = new Date(value);
    return isNaN(d) ? null : d;
  }
  function relative(value) {
    const d = when(value);
    if (!d) return "Never";
    const days = Math.floor((Date.now() - d.getTime()) / 86400000);
    if (days <= 0) return "Today, " + timeFmt.format(d);
    if (days === 1) return "Yesterday";
    if (days < 30) return days + " days ago";
    return dateFmt.format(d);
  }

  function initials(a) {
    return [(a.firstname || "")[0], (a.surname || "")[0]].filter(Boolean).join("").toUpperCase() || "?";
  }

  // ------------------------------------------------------------ sign in
  async function emailFor(identifier) {
    if (identifier.includes("@")) return identifier;
    const { data, error } = await sb.rpc("email_for_username", { p_username: identifier });
    if (error) throw new Error("Could not reach the server. Check your connection and try again.");
    return data || null;
  }

  /** The signed-in account if it is the root admin; otherwise signs out. */
  async function requireRoot() {
    const { data, error } = await sb.rpc("current_admin");
    if (error) throw new Error(await messageOf(error, "Could not check your account."));
    if (!data || data.admin_type !== "root") {
      await sb.auth.signOut();
      throw new Error("Only the root administrator can sign in to this console.");
    }
    return data;
  }

  $("login-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const id = $("login-id").value.trim();
    const password = $("login-password").value;
    const errorBox = $("login-error");
    setError(errorBox, "");
    if (!id || !password) {
      setError(errorBox, "Enter your username and password.");
      return;
    }
    const button = $("login-button");
    busy(button, true, "Signing in…");
    try {
      const email = await emailFor(id);
      if (!email) throw new Error("Wrong username or password.");
      const { error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw new Error("Wrong username or password.");
      me = await requireRoot();
      $("login-password").value = "";
      await openConsole();
    } catch (e) {
      setError(errorBox, e.message || "Could not sign in.");
    } finally {
      busy(button, false);
    }
  });

  $("signout").addEventListener("click", async () => {
    await sb.auth.signOut();
    me = null;
    admins = [];
    show("login");
    $("login-id").focus();
  });

  document.querySelectorAll("[data-toggle-password]").forEach((button) => {
    button.addEventListener("click", () => {
      const input = $(button.dataset.togglePassword);
      const hidden = input.type === "password";
      input.type = hidden ? "text" : "password";
      button.textContent = hidden ? "Hide" : "Show";
    });
  });

  // ------------------------------------------------------------ console
  async function openConsole() {
    $("me-name").textContent = me.name || me.username;
    show("console");
    await loadAdmins();
  }

  async function loadAdmins() {
    const status = $("list-status");
    status.textContent = "Loading…";
    status.hidden = false;
    $("admins-table").hidden = true;
    const { data, error } = await sb.rpc("list_admins");
    if (error) {
      status.textContent = await messageOf(error, "Could not load the admins.");
      return;
    }
    admins = data || [];
    renderStats();
    renderStations();
    renderList();
  }

  function renderStats() {
    const normal = admins.filter((a) => a.admin_type !== "root");
    const stations = new Set(normal.map((a) => a.admin_station).filter((s) => s && s !== "Unassigned"));
    const unassigned = normal.filter((a) => a.admin_station === "Unassigned").length;
    const box = $("stats");
    box.replaceChildren(
      stat(normal.length, normal.length === 1 ? "Station admin" : "Station admins"),
      stat(stations.size, stations.size === 1 ? "Station" : "Stations"),
      stat(unassigned, "Without a station"),
    );
  }

  function stat(value, label) {
    return el("div", { class: "stat" },
      el("div", { class: "stat-value" }, value),
      el("div", { class: "stat-label" }, label));
  }

  function renderStations() {
    const names = [...new Set(admins.map((a) => a.admin_station).filter((s) => s && s !== "Unassigned"))].sort();
    $("station-list").replaceChildren(...names.map((n) => el("option", { value: n })));
  }

  function renderList() {
    const q = $("search").value.trim().toLowerCase();
    const rows = admins.filter((a) =>
      !q || [a.firstname, a.surname, a.username, a.email, a.admin_station]
        .some((v) => (v || "").toLowerCase().includes(q)));
    const status = $("list-status");
    const table = $("admins-table");
    if (!rows.length) {
      status.textContent = admins.length
        ? "No admin matches your search."
        : "No station admins yet. Use “+ New admin” to add the first one.";
      status.hidden = false;
      table.hidden = true;
      return;
    }
    status.hidden = true;
    table.hidden = false;
    $("admins-body").replaceChildren(...rows.map(row));
  }

  function row(a) {
    const isRoot = a.admin_type === "root";
    const created = when(a.datecreated);
    return el("tr", null,
      el("td", { "data-label": "Name" },
        el("div", { class: "person" },
          el("div", { class: "avatar", "aria-hidden": "true" }, initials(a)),
          el("div", null,
            el("div", { class: "person-name" }, `${a.firstname || ""} ${a.surname || ""}`.trim()),
            el("div", { class: "sub" }, "@" + a.username)))),
      el("td", { "data-label": "Email" }, a.email || "–",
        a.phonenumber ? el("div", { class: "sub" }, a.phonenumber) : null),
      el("td", { "data-label": "Station" },
        a.admin_station === "Unassigned"
          ? el("span", { class: "unassigned" }, "Not set")
          : a.admin_station),
      el("td", { "data-label": "Type" },
        el("span", { class: "badge " + (isRoot ? "root" : "normal") }, isRoot ? "Root" : "Station admin")),
      el("td", { "data-label": "Created" },
        created ? dateFmt.format(created) : "–",
        a.createdby_name ? el("div", { class: "sub" }, "by " + a.createdby_name) : null),
      el("td", { "data-label": "Last sign-in" }, relative(a.last_sign_in_at)),
      el("td", { class: "actions-col" },
        el("button", { class: "link", type: "button", onclick: () => openStation(a) }, "Change station")));
  }

  $("search").addEventListener("input", renderList);
  $("refresh").addEventListener("click", loadAdmins);

  // ------------------------------------------------------------ dialogs
  document.querySelectorAll("dialog [data-close]").forEach((button) =>
    button.addEventListener("click", () => button.closest("dialog").close()));

  // New admin
  const newDialog = $("new-dialog");
  const newForm = $("new-form");

  $("new-admin").addEventListener("click", () => {
    newForm.reset();
    $("new-password").type = "password";
    document.querySelector('[data-toggle-password="new-password"]').textContent = "Show";
    setError($("new-error"), "");
    newForm.hidden = false;
    $("new-done").hidden = true;
    newDialog.showModal();
    newForm.elements.firstname.focus();
  });

  // an old message goes away as soon as the form is being corrected
  newForm.addEventListener("input", () => setError($("new-error"), ""));
  $("login-form").addEventListener("input", () => setError($("login-error"), ""));
  $("station-form").addEventListener("input", () => setError($("station-error"), ""));

  // Letters and digits without look-alikes (0/O, 1/l/I), so the password
  // can be read out or typed over without mistakes.
  const PASSWORD_LETTERS = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ";
  const PASSWORD_DIGITS = "23456789";

  /** A random 12-character temporary password with letters and digits. */
  function generatePassword(length = 12) {
    const all = PASSWORD_LETTERS + PASSWORD_DIGITS;
    const pick = (chars) => {
      // rejection sampling, so every character is equally likely
      const limit = 256 - (256 % chars.length);
      const byte = new Uint8Array(1);
      do crypto.getRandomValues(byte); while (byte[0] >= limit);
      return chars[byte[0] % chars.length];
    };
    while (true) {
      let password = "";
      for (let i = 0; i < length; i++) password += pick(all);
      if (/[A-Za-z]/.test(password) && /\d/.test(password)) return password;
    }
  }

  $("new-generate").addEventListener("click", () => {
    const input = $("new-password");
    input.value = generatePassword();
    input.type = "text"; // show it, so it can be noted down
    const toggle = document.querySelector('[data-toggle-password="new-password"]');
    if (toggle) toggle.textContent = "Hide";
    setError($("new-error"), "");
  });

  $("done-copy").addEventListener("click", async () => {
    const text = [
      "Argus Shield sign-in",
      "Username: " + $("done-username").textContent,
      "Temporary password: " + $("done-password").textContent,
      "You will be asked to choose your own password when you first sign in.",
    ].join("\n");
    try {
      await navigator.clipboard.writeText(text);
      toast("Copied the sign-in details.");
    } catch (_) {
      toast("Could not copy. Select the details and copy them yourself.");
    }
  });

  /** Same rules as the Edge Function, for instant messages. */
  function validate(v) {
    if (!v.firstname || !v.surname) return "Enter the first name and surname.";
    if (!v.station) return "Enter the police station.";
    if (!/^[A-Za-z0-9_.]{3,30}$/.test(v.username)) return "Username must be 3-30 letters, numbers, _ or .";
    if (v.phone && !/^\d{9}$/.test(v.phone)) return "Phone number must be the 9 digits after +27 (no initial 0).";
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.email)) return "Enter a valid email address.";
    if (v.password.length < 8 || v.password.length > 72 || !/[A-Za-z]/.test(v.password) || !/\d/.test(v.password)) {
      return "The temporary password needs 8-72 characters, with letters and numbers. Use Generate for a strong one.";
    }
    return null;
  }

  newForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const f = newForm.elements;
    const values = {
      firstname: f.firstname.value.trim(),
      surname: f.surname.value.trim(),
      station: f.station.value.trim(),
      username: f.username.value.trim(),
      phone: f.phone.value.replace(/\s+/g, "").replace(/^0/, ""),
      email: f.email.value.trim().toLowerCase(),
      password: f.password.value,
    };
    const errorBox = $("new-error");
    const problem = validate(values);
    setError(errorBox, problem);
    if (problem) return;

    const button = $("new-submit");
    busy(button, true, "Creating…");
    try {
      const { error } = await sb.functions.invoke("create-admin", { body: values });
      if (error) throw new Error(await messageOf(error, "The account could not be created. Try again."));
      $("done-text").textContent =
        `${values.firstname} ${values.surname} is now the admin for ${values.station}.`;
      $("done-username").textContent = values.username;
      $("done-email").textContent = values.email;
      $("done-password").textContent = values.password;
      newForm.hidden = true;
      $("new-done").hidden = false;
      loadAdmins();
    } catch (e) {
      setError(errorBox, e.message);
    } finally {
      busy(button, false);
    }
  });

  // Change station
  const stationDialog = $("station-dialog");
  let editing = null;

  function openStation(a) {
    editing = a;
    $("station-who").textContent = `${a.firstname} ${a.surname} (@${a.username})`;
    $("station-input").value = a.admin_station === "Unassigned" ? "" : a.admin_station;
    setError($("station-error"), "");
    stationDialog.showModal();
    $("station-input").focus();
  }

  $("station-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const station = $("station-input").value.trim();
    const errorBox = $("station-error");
    if (!station) {
      setError(errorBox, "Enter the police station.");
      return;
    }
    const button = $("station-submit");
    busy(button, true, "Saving…");
    try {
      const { error } = await sb.rpc("set_admin_station", { p_userid: editing.userid, p_station: station });
      if (error) throw new Error(await messageOf(error, "Could not save the station."));
      stationDialog.close();
      toast("Station updated");
      loadAdmins();
    } catch (e) {
      setError(errorBox, e.message);
    } finally {
      busy(button, false);
    }
  });

  // ------------------------------------------------------------ start
  sb.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT" && !views.console.hidden) show("login");
  });

  (async function start() {
    const { data } = await sb.auth.getSession();
    if (data && data.session) {
      try {
        me = await requireRoot();
        await openConsole();
        return;
      } catch (e) {
        setError($("login-error"), e.message);
      }
    }
    show("login");
  })();
})();
