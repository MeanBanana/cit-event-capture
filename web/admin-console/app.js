// Admin console for the root administrator.
//
// Sign in with username/email + password, then current_admin() has to come
// back as 'root' or we sign you straight out again. From there root can list
// admins, create new ones (create-admin, with a temp password they change on
// first sign-in), change an admin's station, remove admins (manage-admin),
// see all cases and delete closed ones, and switch the APK download on the
// website on or off.
//
// Nothing here is the actual security. The database and Edge Functions
// enforce every rule, the checks in this file are just there to give nicer
// messages.

(function () {
  "use strict";

  const cfg = window.ARGUS_CONFIG || {};
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: { persistSession: true, autoRefreshToken: true },
  });

  const $ = (id) => document.getElementById(id);
  const views = { login: $("login-view"), console: $("console-view") };
  let admins = [];
  let cases = null;          // only loaded the first time someone opens the Cases tab
  let caseFilter = "all";
  let me = null;

  // --- helpers
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

  /** Pull a readable message out of a Supabase or Edge Function error. */
  async function messageOf(error, fallback) {
    if (!error) return fallback;
    try {
      // Edge Function errors have the response body: { error: "..." }
      if (error.context && typeof error.context.json === "function") {
        const body = await error.context.json();
        if (body && body.error) return body.error;
      }
    } catch (_) { /* wasn't JSON */ }
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

  // --- sign in
  async function emailFor(identifier) {
    if (identifier.includes("@")) return identifier;
    const { data, error } = await sb.rpc("email_for_username", { p_username: identifier });
    if (error) throw new Error("Could not reach the server. Check your connection and try again.");
    return data || null;
  }

  /** Returns the signed-in account if it's root, otherwise signs out. */
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
    cases = null;
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

  // --- console
  async function openConsole() {
    $("me-name").textContent = me.name || me.username;
    show("console");
    openTab("admins");
    loadDownloadSwitch();
    await loadAdmins();
  }

  // --- app download switch
  // Turns the APK download on the website on or off (we're on free Supabase,
  // so it goes off when we demo to a big crowd). The website and the Netlify
  // guard in front of the APK both read the same setting.
  let downloadEnabled = null;

  function renderDownloadSwitch(state) {
    const box = $("download-switch");
    const badge = $("download-state");
    const note = $("download-note");
    const button = $("download-toggle");
    box.dataset.state = state;
    if (state === "loading" || state === "error") {
      badge.className = "badge normal";
      badge.textContent = state === "loading" ? "Checking…" : "Unknown";
      note.textContent = state === "loading"
        ? "Whether people can download the APK from the website."
        : "Could not check the setting. Try again.";
      button.className = "ghost";
      button.textContent = "Try again";
      button.disabled = state === "loading";
      return;
    }
    const on = state === "on";
    badge.className = "badge " + state;
    badge.textContent = on ? "On" : "Off";
    note.textContent = on
      ? "Anyone on an Android phone can download the APK from the website."
      : "The Download button on the website is switched off and the APK link is blocked.";
    button.className = on ? "danger" : "primary";
    button.textContent = on ? "Disable download" : "Enable download";
    button.disabled = false;
  }

  async function loadDownloadSwitch() {
    renderDownloadSwitch("loading");
    const { data, error } = await sb.rpc("apk_download_enabled");
    if (error) {
      downloadEnabled = null;
      renderDownloadSwitch("error");
      return;
    }
    downloadEnabled = data !== false;
    renderDownloadSwitch(downloadEnabled ? "on" : "off");
  }

  $("download-toggle").addEventListener("click", async () => {
    if (downloadEnabled === null) return loadDownloadSwitch();
    const button = $("download-toggle");
    const next = !downloadEnabled;
    busy(button, true, next ? "Enabling…" : "Disabling…");
    const { data, error } = await sb.rpc("set_apk_download_enabled", { p_enabled: next });
    if (error) {
      busy(button, false);
      toast(await messageOf(error, "Could not change the download setting."));
      return;
    }
    downloadEnabled = data !== false;
    renderDownloadSwitch(downloadEnabled ? "on" : "off");
    toast(downloadEnabled ? "App download enabled" : "App download disabled");
  });

  function openTab(name) {
    document.querySelectorAll(".tab").forEach((tab) => {
      if (tab.dataset.tab === name) tab.setAttribute("aria-current", "page");
      else tab.removeAttribute("aria-current");
    });
    $("admins-page").hidden = name !== "admins";
    $("cases-page").hidden = name !== "cases";
    if (name === "cases" && !cases) loadCases();
  }

  document.querySelectorAll(".tab").forEach((tab) =>
    tab.addEventListener("click", () => openTab(tab.dataset.tab)));

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
        el("button", { class: "link", type: "button", onclick: () => openStation(a) }, "Change station"),
        isRoot ? null
          : el("button", { class: "link danger-text", type: "button", onclick: () => openRemove(a) }, "Remove")));
  }

  $("search").addEventListener("input", renderList);
  $("refresh").addEventListener("click", loadAdmins);

  // --- cases
  // lifecycle stages in order (cases.status)
  const STAGES = [
    { key: "open", label: "Open" },
    { key: "under_review", label: "Under review" },
    { key: "closed", label: "Closed" },
  ];
  const stageLabel = (key) => (STAGES.find((s) => s.key === key) || { label: key }).label;
  const caseRef = (id) => "CASE-" + String(id).padStart(4, "0");

  async function loadCases() {
    const status = $("cases-status");
    status.textContent = "Loading…";
    status.hidden = false;
    $("cases-groups").replaceChildren();
    const { data, error } = await sb.rpc("root_list_cases");
    if (error) {
      status.textContent = await messageOf(error, "Could not load the cases.");
      return;
    }
    cases = data || [];
    renderCases();
  }

  function renderCaseFilter() {
    const count = (key) => cases.filter((c) => key === "all" || c.status === key).length;
    const options = [{ key: "all", label: "All" }, ...STAGES];
    $("case-filter").replaceChildren(...options.map((o) =>
      el("button", {
        type: "button",
        class: "segment" + (o.key === caseFilter ? " active" : ""),
        "aria-pressed": String(o.key === caseFilter),
        onclick: () => { caseFilter = o.key; renderCases(); },
      }, o.label, el("span", { class: "count" }, count(o.key)))));
  }

  function renderCases() {
    renderCaseFilter();
    const q = $("case-search").value.trim().toLowerCase();
    const digits = q.replace(/^case[\s#-]*/, "");
    const matches = cases.filter((c) =>
      (caseFilter === "all" || c.status === caseFilter) &&
      (!q || (c.title || "").toLowerCase().includes(q) ||
        (/^\d+$/.test(digits) && String(c.caseid) === String(Number(digits)))));
    const status = $("cases-status");
    const groups = $("cases-groups");
    if (!matches.length) {
      status.textContent = !cases.length ? "There are no cases yet."
        : q ? "No case matches your search."
        : `No ${stageLabel(caseFilter).toLowerCase()} cases.`;
      status.hidden = false;
      groups.replaceChildren();
      return;
    }
    status.hidden = true;
    // group by stage, in lifecycle order
    groups.replaceChildren(...STAGES
      .map((s) => ({ stage: s, rows: matches.filter((c) => c.status === s.key) }))
      .filter((g) => g.rows.length)
      .map((g) => el("section", { class: "case-group" },
        el("h2", { class: "group-head" },
          el("span", { class: "badge stage-" + g.stage.key }, g.stage.label),
          el("span", { class: "sub" }, g.rows.length + (g.rows.length === 1 ? " case" : " cases"))),
        el("ul", { class: "case-list" }, ...g.rows.map(caseCard)))));
  }

  // one case with all its details, looks the same wherever it's shown
  function caseCard(c) {
    const created = when(c.datecreated);
    const closed = when(c.dateclosed);
    const fact = (label, value, sub) => el("div", { class: "fact" },
      el("dt", null, label), el("dd", null, value, sub ? el("div", { class: "sub" }, sub) : null));
    return el("li", { class: "case-card stage-" + c.status },
      el("div", { class: "case-top" },
        el("div", null,
          el("div", { class: "case-title" }, c.title),
          el("div", { class: "sub" }, caseRef(c.caseid))),
        c.status === "closed"
          ? el("button", { class: "link danger-text", type: "button", onclick: () => openCaseDelete(c) }, "Delete")
          : null),
      c.description && c.description.trim()
        ? el("p", { class: "case-desc" }, c.description.trim())
        : el("p", { class: "case-desc none" }, "No description"),
      el("dl", { class: "facts" },
        fact("Submissions", c.incidentcount),
        fact("Investigators", c.investigators),
        fact("Created", created ? dateFmt.format(created) : "–", c.createdbyname ? "by " + c.createdbyname : null),
        c.status === "closed"
          ? fact("Closed", closed ? dateFmt.format(closed) : "–")
          : fact("Last activity", relative(c.lastactivity))));
  }

  $("case-search").addEventListener("input", () => cases && renderCases());
  $("case-refresh").addEventListener("click", loadCases);

  // --- dialogs
  document.querySelectorAll("dialog [data-close]").forEach((button) =>
    button.addEventListener("click", () => button.closest("dialog").close()));

  // new admin
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

  // clear the old error as soon as they start fixing the form
  newForm.addEventListener("input", () => setError($("new-error"), ""));
  $("login-form").addEventListener("input", () => setError($("login-error"), ""));
  $("station-form").addEventListener("input", () => setError($("station-error"), ""));

  // No look-alike characters (0/O, 1/l/I) so the password can be read out
  // over the phone or copied by hand without mistakes.
  const PASSWORD_LETTERS = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ";
  const PASSWORD_DIGITS = "23456789";

  /** Random 12-character temporary password. */
  function generatePassword(length = 12) {
    const all = PASSWORD_LETTERS + PASSWORD_DIGITS;
    const pick = (chars) => {
      // rejection sampling so every character is equally likely
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
    input.type = "text"; // show it so they can write it down
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

  /** Same checks as the Edge Function, just so we can complain straight away. */
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

  // change station
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

  // remove admin
  const removeDialog = $("remove-dialog");
  let removing = null;

  function openRemove(a) {
    removing = a;
    $("remove-who").textContent = `${a.firstname} ${a.surname} (@${a.username}, ${a.admin_station})`;
    setError($("remove-error"), "");
    removeDialog.showModal();
  }

  $("remove-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("remove-submit");
    busy(button, true, "Removing…");
    try {
      const { error } = await sb.functions.invoke("manage-admin", {
        body: { action: "delete", userid: removing.userid },
      });
      if (error) throw new Error(await messageOf(error, "The account could not be removed. Try again."));
      removeDialog.close();
      toast(`${removing.firstname} ${removing.surname} removed`);
      loadAdmins();
    } catch (e) {
      setError($("remove-error"), e.message);
    } finally {
      busy(button, false);
    }
  });

  // delete a closed case
  const caseDeleteDialog = $("case-delete-dialog");
  let deletingCase = null;

  function openCaseDelete(c) {
    deletingCase = c;
    $("case-delete-who").textContent = `${caseRef(c.caseid)}: ${c.title}`;
    $("case-delete-note").textContent =
      (c.incidentcount
        ? `Its ${c.incidentcount} submission${c.incidentcount === 1 ? "" : "s"} and their footage are kept and go back to the review queue. `
        : "") +
      "Its assignments, case chat and AI results are deleted. This can't be undone.";
    setError($("case-delete-error"), "");
    caseDeleteDialog.showModal();
  }

  $("case-delete-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("case-delete-submit");
    busy(button, true, "Deleting…");
    try {
      const { error } = await sb.rpc("delete_closed_case", { p_caseid: deletingCase.caseid });
      if (error) throw new Error(await messageOf(error, "The case could not be deleted. Try again."));
      caseDeleteDialog.close();
      toast(`${caseRef(deletingCase.caseid)} deleted`);
      loadCases();
    } catch (e) {
      setError($("case-delete-error"), e.message);
    } finally {
      busy(button, false);
    }
  });

  // --- start
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
