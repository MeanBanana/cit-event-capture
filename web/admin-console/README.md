# Argus Shield admin console (web)

A small website for the **root administrator** only. It shows every police
station's admin and lets the root admin create new admin accounts and change
an admin's station. Station admins keep using the mobile app.

It is plain HTML / CSS / JavaScript: no build step, no Node needed.

```
web/admin-console/
  index.html     sign-in page + console
  styles.css     look and feel (white, navy, amber from the logo)
  app.js         all the logic
  config.js      Supabase URL + publishable key (same as the mobile app)
  logo.svg       Argus Shield logo
  vendor/        supabase-js 2.118.0 (MIT licence), bundled so the
                 console doesn't depend on an outside CDN
```

## Before it works

Supabase needs the new table, functions and the `create-admin` Edge Function,
and someone must be made the root admin. The steps are in
[`SUPABASE_ADMIN_CONSOLE.md`](../../SUPABASE_ADMIN_CONSOLE.md) at the
top of the repo.

## Run it on your computer

Browsers block some features on pages opened straight from a file, so serve
the folder:

```
cd web\admin-console
python -m http.server 8080
```

Then open <http://localhost:8080>.

## Put it online (free)

It's a static site, so any static host works. Upload the whole
`web/admin-console` folder:

* **Netlify Drop**: go to <https://app.netlify.com/drop> and drag the folder
  onto the page. You get a link straight away.
* **Vercel** or **GitHub Pages** work the same way (publish the folder).

No Supabase setting needs to change for a new address: signing in with a
password doesn't use redirect links.

## How it's secured

* Signing in is normal Supabase Auth (username or email + password). Right
  after, the console asks the database `current_admin()`; anyone who isn't
  the root admin is signed out with "Only the root administrator can sign in".
* That check is only for a clear message. The real protection is on the
  server: `list_admins()` and `set_admin_station()` refuse anyone but the
  root admin, and the `create-admin` Edge Function checks the caller too.
* `config.js` only has the **publishable** key (it's public by design and
  already ships in the mobile app). The service key stays inside Supabase.
* New admins get a temporary password from the root admin. It is shown once
  after creating the account and wiped from the page when the dialog closes.
