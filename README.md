# Argus Shield

**Real-Time Computer Vision Application for Suspect and Vehicle Intelligence Capture in CIT Robbery Investigations**

Argus Shield turns footage of cash-in-transit (CIT) robberies into structured, searchable intelligence for investigators. Citizens upload videos and photos from their phones, an AI pipeline finds the people, vehicles, weapons, number plates and gunfire in them, and admins and investigators work the resulting cases in one mobile app, with ethics, security and privacy (POPIA) designed in.

> ## 📱 Download the app
>
> The Android app can be downloaded from our website: **<https://argus-shield.netlify.app/>**
>
> You don't need to build anything to use Argus Shield: download it, install it and log in. The rest of this README is for developers who want to run it from source or set up their own copy of the system. See [Installing the app](#installing-the-app).

---

## Contents

1. [What's in the system](#whats-in-the-system)
2. [Installing the app](#installing-the-app)
3. [Using the app for the first time](#using-the-app-for-the-first-time)
4. [Running from source (developers)](#running-from-source-developers)
5. [Setting up the whole system](#setting-up-the-whole-system)
6. [Project structure](#project-structure)
7. [How it works](#how-it-works)
8. [Testing](#testing)
9. [Contributing](#contributing)
10. [Security and privacy](#security-and-privacy)
11. [Project status](#project-status)
12. [Still to do](#still-to-do)
13. [Collaborators](#collaborators)

---

## What's in the system

| Part | Technology | Where | Docs |
|---|---|---|---|
| **Mobile app** (citizens, investigators, station admins) | Flutter (Dart), Android + iOS | `mobile/argus_shield/` | [README](mobile/argus_shield/README.md) |
| **Database, login, file storage** | Supabase (PostgreSQL 17, Auth, Storage, Realtime, Edge Functions) | `database/` | [README](database/README.md), [AI_PIPELINE.md](database/AI_PIPELINE.md) |
| **AI / computer vision pipeline** | Python (YOLO26, YOLOE, FastALPR, YuNet, YAMNet) | `ai/` | [README](ai/README.md) |
| **AI worker** (connects the pipeline to Supabase) | Python | `backend/` | [README](backend/README.md) |
| **Website** (download page + web admin console, where the root admin creates admins for police stations and Hawks units) | Vite + React + TypeScript; plain HTML/JS console | `web/landing/`, `web/admin-console/` | [landing](web/landing/README.md), [console](web/admin-console/README.md), [setup](SUPABASE_ADMIN_CONSOLE.md) |

User roles:

* **Citizens** register in the app, report CIT incidents and upload 1–5 videos/photos per report.
* **Investigators** see only the cases they are assigned to: crime scenes, footage, AI findings, corrections, case history and a case group chat.
* **Station admins** review submissions, build cases, assign investigators and create investigator accounts.
* **The root admin** (one per system) creates the admins for the different police stations and Hawks units from the web console at `/admin/` on the website.

---

## Installing the app

### Android (recommended)

1. On your phone, open **<https://argus-shield.netlify.app/>** and download the app (`.apk` file).
2. Open the downloaded file. Android will ask to allow installs from this source (your browser or Files app): tap **Settings**, turn on **Allow from this source**, then go back.
3. Tap **Install**. If Google Play Protect warns that the app is unknown, tap **More details → Install anyway** (the app is not on the Play Store yet).
4. Open **Argus Shield**.

To update, download the newer version from the website and install it over the old one.

### iOS

There is no App Store or TestFlight build yet. iPhone users can run the app from source on their own device with a Mac and Xcode (see [Running from source](#running-from-source-developers)).

---

## Using the app for the first time

| You are | What to do |
|---|---|
| **Citizen** | Tap **Register as citizen**, fill in your details, then log in with your **username** and password. Use **Upload** to report an incident; follow it under **My submissions**. |
| **Investigator** | You can't register yourself. A station admin creates your account and gives you a **temporary password**. Log in with your username and that password; the app then asks you to **choose your own password**, signs you out, and you log in again with it. |
| **Station admin** | The root admin creates your account in the web console and gives you a temporary password. First log-in works the same as for investigators. |
| **Root admin** | Sign in to the console at <https://argus-shield.netlify.app/admin/> (made once by the database owner, see [step 4](#4-make-the-root-admin)). |

* **Forgot password?** on the login page emails a reset link. Open the link **on the same phone**: it opens the app's *New Password* screen.
* The **settings** icon (top right) switches the language (English, Afrikaans, Zulu) and dark mode. The icon next to it signs you out.
* Footage: upload the **original** video from the phone, not a WhatsApp/TikTok copy. Shared copies are shrunk and lose the GPS and recording time, and plates and faces become unreadable.

---

## Running from source (developers)

### Requirements

| For | Install |
|---|---|
| Everything | [Git](https://git-scm.com/) |
| Mobile app | [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.13`), Android Studio (Android SDK + emulator); Xcode on a Mac for iOS |
| Database | A [Supabase](https://supabase.com/) account, the [Supabase CLI](https://supabase.com/docs/guides/cli), [Docker Desktop](https://www.docker.com/products/docker-desktop/) (on Windows: WSL 2 + virtualisation enabled) |
| AI pipeline / worker | Python 3 (the team uses 3.13); an NVIDIA GPU is strongly recommended (a laptop CPU takes roughly 5–9 minutes per minute of video) |
| Website | Node.js 22 |

### 1. Clone

```bash
git clone https://github.com/MeanBanana/cit-event-capture.git
cd cit-event-capture
```

### 2. Run the mobile app

```bash
cd mobile/argus_shield
flutter pub get
flutter run
```

`flutter run` starts the app on a running emulator or a phone connected with USB debugging (`flutter devices` lists them). The app already points at the team's Supabase project (URL and **publishable** key in `lib/main.dart`), so it works straight away with your existing accounts.

To build your own Android installer:

```bash
flutter build apk --release
```

The file is `build/app/outputs/flutter-apk/app-release.apk`. Copy it to a phone and install it as in [Installing the app](#installing-the-app). To publish a new version on the website, see [Website](#6-website-and-root-admin-console).

> After changing `AndroidManifest.xml` or `ios/Runner/Info.plist`, stop the app and `flutter run` again; hot reload doesn't pick those files up.

### 3. Run the AI pipeline on a video (optional)

```bash
cd ai
python -m venv .venv
.venv\Scripts\activate             # Windows; macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
python main.py video.mp4           # or up to 5 files: one submission
```

Results go to `ai/crops/submission N/` (`results.json` + pictures). Details: [`ai/README.md`](ai/README.md).

---

## Setting up the whole system

Only needed for a **new** Supabase project, or when a step below hasn't been done on the team's project yet. Do the steps in order.

### 1. Create and link the Supabase project

```bash
cd database
supabase login
supabase link --project-ref <project-ref>   # team project: ask Carel for the ref and database password
```

### 2. Create the database

```bash
supabase db push            # applies every migration in supabase/migrations/, in order
supabase migration list     # every migration shows under both Local and Remote
```

This creates all tables, row-level security, database functions, the AI job queue, the case chat, the admin accounts table and the private `submissions` storage bucket.

### 3. Deploy the Edge Functions

```bash
supabase functions deploy create-investigator
supabase functions deploy create-admin
```

`config.toml` turns **Verify JWT** off for both; that is intended (each function checks the caller itself). `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided to them automatically.

### 4. Make the root admin

Register a normal account in the app (or pick an existing admin), then in **Supabase → SQL Editor**:

```sql
SELECT public.make_root_admin('their_username', 'Argus HQ');
```

The root admin can now sign in to the web console and create station admins, who in turn create investigators in the app. Details and checks: [`SUPABASE_ADMIN_CONSOLE.md`](SUPABASE_ADMIN_CONSOLE.md).

### 5. Supabase dashboard settings

* **Authentication → URL Configuration → Redirect URLs:** add `argusshield://reset-password` (otherwise reset links open a browser instead of the app).
* **Authentication → Emails → SMTP Settings:** add a custom SMTP provider before real users rely on email. Supabase's built-in email only reaches the project team, a few emails per hour.
* **Your own project?** Put its URL and publishable key in `mobile/argus_shield/lib/main.dart` and `web/admin-console/config.js`. Never the service role key.

### 6. Website and root admin console

```bash
cd web/landing
npm install
npm run dev          # http://localhost:3006  (console: http://localhost:3006/admin/)
npm run build        # -> web/landing/dist/, the whole site including dist/admin/
```

The live site (<https://argus-shield.netlify.app/>) is deployed by **Netlify** from `main` using `web/landing/netlify.toml`; it only rebuilds when `web/landing/` or `web/admin-console/` changes. To offer a new app version for download, build the APK (step 2 above) and update the download on the website.

### 7. Run the AI worker

The worker runs on a GPU PC, takes analysis jobs from Supabase and writes the results back. It only makes outgoing connections, so no port forwarding is needed.

```bash
pip install -r ai/requirements.txt -r backend/requirements.txt
copy backend\.env.example backend\.env      # macOS/Linux: cp
# edit backend/.env: paste the service role key (Supabase → Project Settings → API)
python backend/worker.py                    # keeps running; Ctrl+C to stop
```

While it runs, new citizen uploads are analysed within seconds (it logs to `backend/worker.log`; `ai_worker_status()` in the database tells whether a worker is online). Test without the app: `python backend/submit_test.py ai/video.mp4 --location "N1 Midrand"`. Details: [`backend/README.md`](backend/README.md).

> `backend/.env` is git-ignored. The service role key bypasses all security rules: keep it on the worker PC only, never in the app, the website or Git.

---

## Project structure

```text
cit-event-capture/
├── mobile/argus_shield/       Flutter app (citizen, investigator, admin screens) + its tests
├── database/
│   ├── README.md              schema, accounts, RLS, functions, migrations, workflow
│   ├── AI_PIPELINE.md         job queue and what the AI worker writes
│   └── supabase/
│       ├── config.toml        Supabase CLI configuration
│       ├── migrations/        every database change, in timestamp order
│       ├── functions/         Edge Functions: create-investigator, create-admin
│       └── tests/             pgTAP database tests (supabase test db)
├── ai/                        computer vision pipeline, models, case matching, weapon training notebook
├── backend/                   AI worker, result upload, test submission script
├── web/
│   ├── landing/               public website (app download), deployed on Netlify
│   └── admin-console/         root admin console, served at /admin/ on the website
├── tests/                     Python integration tests against a local Supabase
├── diagrams/                  C4 context/container diagrams, ERD, use cases, wireframes
├── docs/                      research documents and reports
├── SUPABASE_ADMIN_CONSOLE.md  step-by-step Supabase setup for the admin console
├── CONTRIBUTING.md            Git workflow and contribution rules
└── README.md
```

---

## How it works

**A citizen submits, the AI analyses, an admin decides, investigators investigate.**

1. A citizen reports an incident with 1–5 videos/photos. The files go to the private `submissions` storage bucket and an `analyse` job is queued.
2. The **AI worker** runs the pipeline: it tracks every vehicle, person and weapon, reads make, colour and plate, counts people and suggests clothing colours, saves a picture of clear faces (found, **never** recognised), and listens for gunfire (automatic vs semi-automatic). GPS and recording time are read from the files.
3. In **Submissions**, the admin sees the citizen's description next to the AI summary. The database suggests a matching case (within 1 km and 14 days, or the same plate) with its reasons. **Nothing joins a case until an admin accepts it.**
4. Accepting merges the submission's people, vehicles and weapons into the case ("Is this Person 2?" when unsure) and updates the case's AI summary.
5. The admin assigns investigators (the first is the lead). Investigators open their cases, view crime scenes and footage, **correct** AI findings (every correction is logged), move the case between open and under review, and talk in the case's group **chat**.
6. Every person the AI sees is only a **possible suspect**. Under POPIA only an assigned investigator may confirm or dismiss them; admin screens show counts only.
7. Every step is recorded in the case history.

The app uses the **publishable key** plus the user's login, so row-level security decides what each person can see. The full permission table is in [`database/README.md`](database/README.md#who-can-see-and-do-what-rls).

The system is a decision-support tool: it doesn't decide guilt or take any action itself. Investigators remain responsible for reviewing and acting on what it finds.

---

## Testing

| What | How |
|---|---|
| Mobile app | In `mobile/argus_shield/`: `flutter analyze` (must say "No issues found!") and `flutter test`. Screens are tested against in-memory fakes, so no Supabase is needed |
| Database | In `database/`: `supabase start`, `supabase db reset`, then `supabase test db` (needs Docker Desktop) |
| Integration | With the local database running, from the repo root: `python tests/test_ai_pipeline_db.py`, `test_corrections_db.py`, `test_case_chat_db.py`, `test_admin_accounts_db.py`, `test_combine_entities_db.py`, `test_submissions_storage.py`, `test_worker.py` (needs `pip install "psycopg[binary]"`) |
| Permissions | Log in as a citizen, an investigator and an admin and check each sees only what it should |

---

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. In short:

* Never commit directly to `main`. Create a descriptive branch (`feature/vehicle-detection`, `bugfix/mobile-camera-upload`), keep it in sync with `main`, test, push, and open a Pull Request for review.
* **Every database change is a migration** (`supabase migration new <name>` in `database/`, then `supabase db push --dry-run` and `supabase db push`). Never change tables or policies in the Supabase dashboard, and never edit a migration that has already been pushed. Full workflow and Windows troubleshooting: [`database/README.md`](database/README.md#workflow-making-a-database-change).
* In the app, screens never call Supabase directly: add a method to `SupabaseService` and to the test fakes (see the [app README](mobile/argus_shield/README.md#conventions)).
* Track bugs, features and research in GitHub Issues.

---

## Security and privacy

Argus Shield handles sensitive investigation data. Never commit:

* passwords, database credentials, Supabase **service role** keys or tokens (`.env` files are git-ignored)
* personal information, real investigation footage or sensitive datasets

The **publishable** key in the app and the console is public by design; RLS protects the data. If a secret is ever committed, tell the team straight away instead of just deleting it in a later commit (it stays in the Git history and must be rotated).

---

## Project status

| Part | State |
|---|---|
| Login, citizen registration, forgot / reset password | **Live**. Needs a custom SMTP provider before real users rely on email |
| Temporary passwords for new admins and investigators | **Live**: must choose their own password at first log-in |
| Citizen upload, My submissions, profile | **Live** on Supabase (footage in the `submissions` bucket, queued for the AI) |
| Admin dashboard: Overview, Cases, Detectives, Submissions | **Live**: review, suggestions, cases, assignments, AI evidence, footage viewer, new investigators |
| Investigator dashboard | **Live**: assigned cases, crime scenes, AI summary, corrections, activity, case chat, open ↔ under review |
| Root admin web console | **Live** at <https://argus-shield.netlify.app/admin/> |
| AI pipeline + worker | **Built**. Runs on the team's GPU PC; uploads are only analysed while `backend/worker.py` is running |
| Settings | English / Afrikaans / Zulu, dark mode |
| Suspect review (POPIA) | **Database ready**; the investigator screen to confirm / dismiss possible suspects is still to be built |
| App distribution | Android APK on the website; no Play Store / App Store release yet |

Features are not production-ready until implemented, tested and reviewed by the team.

---

## Still to do

- [ ] **Suspect review screen** for investigators (confirm / dismiss possible suspects with a reason; the database functions exist)
- [ ] **Case notes** (append-only) and logged investigator edits of submission data
- [ ] Investigators verifying or rejecting AI links between incidents
- [ ] **Station-scoped admins**: station admins still see every station's submissions and cases
- [ ] Removing / disabling an admin from the console
- [ ] "AI worker online" tile in the admin app (`getAiWorkerStatus()` is ready, no UI yet)
- [ ] Custom SMTP provider in Supabase
- [ ] Decide whether `"User".authid` should be nullable again (until then, don't delete users in the Supabase dashboard; see [`database/README.md`](database/README.md#still-to-do))
- [ ] Release signing, a unique Android application ID (currently `com.example.argus_shield`) and store releases
- [ ] AI accuracy: measure on labelled SA footage, more weapon training data (machetes / pangas), test on real automatic fire (see [`ai/README.md`](ai/README.md#still-to-do))
- [ ] Update the ERD in `diagrams/` with the newer tables (`cases`, `caseevent`, `caseentity`, `aijob`, `casemessage`, `admin`, …)
- [ ] POPIA decisions: how long dismissed people are kept, whether viewing suspect details is logged, who may see footage of possible suspects
- [ ] Choose a licence before distributing the code publicly

---

## Collaborators

* [Carel von Ronge](https://github.com/MeanBanana)
* [Deacon George Nel](https://github.com/Deacs-ifbb)
* [Claire Aimee Duke](https://github.com/Claireeduke)
* [Eliandro Cidy Gomez Miranda](https://github.com/EliandroGomesMiranda)
* [Melusi Sikakane](https://github.com/melumbulelosikakane-lang)

---

This project is currently not licensed for redistribution.
