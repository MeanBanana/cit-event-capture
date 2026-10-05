# Argus Shield

**Real-Time Computer Vision Application for Suspect and Vehicle Intelligence Capture in CIT Robbery Investigations**

Argus Shield is a research and development project focused on creating an investigator-facing mobile system that uses computer vision, artificial intelligence, and data management techniques to extract, store, and query suspect and vehicle intelligence from cash-in-transit (CIT) robbery footage.

The system is designed to assist investigators by transforming video footage into structured, searchable intelligence while considering ethical, security, and privacy requirements.

> **Note:** The project's technology stack was revised after the initial planning phase. The application is now built as a **Flutter mobile app** backed by **Supabase**, rather than the original Android Studio (Java) + PHP web + custom Python backend design. See [Architectural Design](#architectural-design) below for details. No separate web application is planned; the Flutter app serves all user roles (see [`web/`](#web)).

---

# Project Overview

Argus Shield consists of several interconnected development areas:

* **Mobile Application** — Flutter (Dart) application, targeting both iOS and Android, used by citizens, investigators, and admins to interact with the system.
* **Backend (Supabase)** — Backend-as-a-service platform (built on PostgreSQL) providing authentication, auto-generated REST APIs, database, and file storage. Any custom server-side logic (e.g. Supabase Edge Functions) also lives here.
* **AI / Computer Vision** — Python-based computer vision models used to extract information (suspects, vehicles, weapons, license plates) from footage.
* **Web Application** *(optional, not in current scope)* — An admin console may be built only if time allows. See [`web/`](#web) below.
* **Database** — Supabase/PostgreSQL schema, migrations, and row-level security (RLS) policies used to store and retrieve investigation data, managed with the Supabase CLI.
* **Diagrams** — Architecture diagrams (C4 model), entity relationship diagrams (ERD), use-case diagrams, and UI mockups/wireframes.

The three primary user roles are:

* **Citizens** — submit footage/evidence of CIT incidents.
* **Investigators / Law enforcement officers** — review structured intelligence and manage assigned cases.
* **Admins** — manage investigator accounts, assign cases, and oversee system-wide activity ("watchover" dashboard).

These components work together to provide an end-to-end system for processing and querying suspect and vehicle intelligence.

---

# Project Structure

```text
cit-event-capture/
│
├── mobile/
│   └── argus_shield/             ← Flutter (Dart) app — iOS and Android (see its README)
│
├── backend/
│   └── Integration glue between the app, Supabase and the AI/CV component
│
├── ai/
│   └── Computer vision models and AI processing (Python)
│
├── web/
│   └── Placeholder — optional admin console, only if time allows
│
├── database/
│   ├── README.md                 ← full database documentation
│   └── supabase/                 ← run Supabase CLI commands from database/
│       ├── config.toml           ← Supabase CLI project configuration
│       ├── migrations/           ← SQL migrations (schema, users/roles, RLS policies)
│       └── functions/            ← Supabase Edge Functions (planned, not created yet)
│
├── diagrams/
│   └── Architecture, ERD and use-case diagrams; UI mockups/wireframes
│
├── docs/
│   └── Research documents and project reports
│
├── tests/
│   └── Testing files, test scripts and test results
│
├── README.md
├── CONTRIBUTING.md
└── .gitignore
```

## Folder Responsibilities

### `mobile/`

Contains the Flutter (Dart) mobile application, targeting both iOS and Android from a single codebase.

This may include:

* Screens/UI (login, admin dashboard, investigator case board, citizen submission board)
* Widgets and shared UI components
* State management
* Supabase client integration (auth, data, storage)
* Mobile-specific configuration and assets

### `backend/`

Contains backend configuration and logic built around **Supabase**.

Supabase provides authentication (JWT-based), auto-generated PostgREST APIs for each database table, database hosting, and file storage — removing the need for a hand-rolled API server. This folder may include:

* Integration glue between the mobile app, Supabase, and the AI/CV component

**Edge Functions** (TypeScript, Deno) for custom server-side logic, such as letting an admin create investigator accounts from inside the app, live in `database/supabase/functions/`, because the Supabase CLI deploys functions from its own `supabase/` folder. The Supabase CLI configuration (`config.toml`) and all RLS policies also live in [`database/`](#database), not in this folder.

### `ai/`

Contains artificial intelligence and computer vision functionality, written in Python.

This may include:

* Computer vision models (e.g. YOLOv8-based detection)
* Image and video processing
* Object detection: weapons, vehicles, license plates
* Person/suspect detection
* Feature extraction
* Model configuration and related scripts

### `web/`

**Status: confirmed — no web application in the current scope.**

The original project plan included a PHP/HTML/CSS/JS web application for investigators. Following the move to Flutter, the team has decided that the **Flutter mobile app will serve all user roles** (citizens, investigators, and admins).

If time allows at the end of the project, a web-based **admin console** may be built. This folder is kept as a placeholder for that possibility.

### `database/`

Contains the Supabase/PostgreSQL database, managed with the **Supabase CLI**. The live database is hosted on Supabase Cloud; this folder is the version-controlled record of its structure.

```text
database/
├── README.md
└── supabase/
    ├── config.toml
    └── migrations/
        ├── 20260929072508_remote_schema.sql            ← baseline schema pulled from Supabase Cloud
        ├── 20260929114152_auth_and_rls.sql             ← Supabase Auth link + role-based RLS policies
        ├── 20260929221626_user_role_tables.sql         ← role enum, citizen/investigator tables, usernames
        ├── 20261005141600_cases_table.sql              ← cases; assignments point at cases
        ├── 20261005142800_weapon_detail.sql            ← weapondetail for weapon detections
        ├── 20261005143300_drop_suspect_behaviour.sql
        ├── 20261005152000_list_investigators.sql       ← Investigators screen
        ├── 20261005153500_admin_overview_stats.sql     ← Overview tiles
        ├── 20261005154500_submissions.sql              ← datereported, list_submissions
        ├── 20261005161500_overview_activity.sql        ← Recent activity feed
        ├── 20261005163000_review_and_cases.sql         ← accept / reject / duplicate, case actions
        ├── 20261005203000_case_events_and_leads.sql    ← case history, lead investigator, case status rules
        └── 20261005203100_submission_views_and_ai.sql  ← AI fields, paging, grouping, suggestions, one-tap review
```

The full list with what each migration does is in [`database/README.md`](./database/README.md#migrations).

**See [`database/README.md`](./database/README.md)** for the full schema, how accounts and login work, who can see what, Flutter examples, and troubleshooting.

Migrations are applied in timestamp order. **All database changes must be made as migrations** (see [Database Workflow](#database-workflow)), not by editing tables in the Supabase dashboard; otherwise Git and the live database drift apart.

Do not store database passwords, service role keys, or other credentials in this directory.

### `diagrams/`

Contains architecture and design diagrams for the project.

This may include:

* C4 model diagrams (Level 1 context diagram, Level 2 container diagram)
* Entity Relationship Diagrams (ERD)
* Use-case diagrams
* UI mockups and wireframes (e.g. login, admin dashboard, investigator board, citizen submission board)

### `docs/`

Contains project documentation.

This may include:

* Research documentation
* Design documents
* Technical reports
* Project planning documents
* Deliverables (e.g. requirements and use-case descriptions)

### `tests/`

Contains testing-related files. (The Flutter app's own tests live next to the app in `mobile/argus_shield/test/`, because `flutter test` looks for them there.)

This may include:

* Flutter widget/unit tests
* Supabase/API integration tests
* AI model tests
* Test data
* Test results
* Automated testing scripts

---

# Requirements

Before starting development, ensure the required software for your assigned development area is installed.

General requirements include:

* Git
* Flutter SDK and Dart
* Android Studio (recommended IDE for Flutter development, with emulator support)
* Python 3.x (for AI/CV development)
* Supabase account and Supabase CLI
* Docker Desktop (required by the Supabase CLI for `supabase db pull`; on Windows this needs WSL and virtualization enabled)
* Figma (for UI/UX prototyping, if contributing to design)

Additional dependencies may be required depending on the component being developed.

Component-specific setup instructions should be documented in the relevant folder or in the project documentation.

---

# Getting Started

## 1. Clone the Repository

Clone the repository from GitHub:

```bash
git clone https://github.com/MeanBanana/cit-event-capture.git
```

Enter the project directory:

```bash
cd cit-event-capture
```

## 2. Read the Contribution Guidelines

Before making changes, read:

[CONTRIBUTING.md](./CONTRIBUTING.md)

This document explains:

* How to create and manage branches
* How to commit changes
* How to synchronise a feature branch with `main`
* How to resolve merge conflicts
* How to push changes
* How to create Pull Requests
* How code review works
* Security and repository rules

All contributors are expected to follow these guidelines.

## 3. Identify Your Development Area

Determine which part of the project you are working on:

```text
mobile/
backend/
ai/
web/
database/
diagrams/
docs/
tests/
```

Only modify files relevant to your assigned task unless you have communicated with the team about changes to another component.

---

# Git Workflow

The `main` branch represents the stable version of the project.

Contributors must **not commit directly to `main`**.

The standard workflow is:

```text
main
 |
 |-- Create feature branch
 |
 v
Feature Branch
 |
 |-- Make changes
 |
 |-- Commit changes
 |
 |-- Synchronise with main
 |
 |-- Resolve conflicts if necessary
 |
 |-- Test
 |
 |-- Push
 |
 v
Pull Request
 |
 v
Code Review
 |
 v
Approval
 |
 v
main
```

For the complete Git workflow, see:

[CONTRIBUTING.md](./CONTRIBUTING.md)

---

# Branch Naming

Branches should have descriptive names that indicate the area or purpose of the work.

Examples:

```text
feature/backend-auth-policies
feature/vehicle-detection
feature/investigator-dashboard
bugfix/mobile-camera-upload
database-schema
diagrams/erd-update
documentation/project-architecture
```

Avoid vague branch names such as:

```text
test
new
changes
stuff
branch1
```

Before creating a branch, check that another team member is not already using the same branch.

---

# Development Guidelines

When contributing to Argus Shield:

* Work on your own branch.
* Do not commit directly to `main`.
* Pull the latest `main` before starting new work.
* Keep your branch synchronised with `main`.
* Place files in the correct project directory.
* Keep commits focused and descriptive.
* Test your changes before creating a Pull Request.
* Do not commit secrets or sensitive information (including Supabase keys).
* Communicate with the team before making major cross-component changes.
* Create a Pull Request before merging changes into `main`.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full contribution process.

---

# Architectural Design

## Technology Stack

| Layer/Component | Technology | Purpose |
|---|---|---|
| UI/UX | Flutter (Dart) | Cross-platform mobile framework (iOS + Android) from a single codebase |
| Backend | Supabase | Backend-as-a-service on PostgreSQL — auth, auto-generated REST APIs, storage |
| AI/CV | Python | Computer vision and AI/ML libraries (e.g. OpenCV, TensorFlow, PyTorch) for footage analysis |
| Database | Supabase PostgreSQL | Relational database with row-level security |
| Authentication | Supabase Auth (JWT) | Sign-up, login and token-based access; the Supabase client SDK refreshes sessions automatically |
| APIs | PostgREST (auto-generated by Supabase) | Standard REST communication between mobile app and backend |
| Edge Functions (if needed) | TypeScript (Deno, via Supabase) | Custom server-side logic beyond auto-generated APIs |
| UI/UX Prototyping | Figma | Collaborative design and prototyping |

## Development Environments / IDEs

* Android Studio — Flutter development and testing (emulators)
* Supabase — backend, database, and file storage hosting

## High-Level Technical Design

The high-level architecture follows the C4 model (Levels 1–2):

* **Level 1 — Context diagram:** how the system interacts with its users (citizens, investigators, admins) and external systems.
* **Level 2 — Container diagram:** the mobile app, Supabase backend, database, and AI/CV component as containers, including their responsibilities, relationships, and technologies.

See [`diagrams/`](#diagrams) for the current diagrams.

---

# Authentication and Access Control

Full details, including Flutter code and the complete permission table, are in [`database/README.md`](./database/README.md).

## How users are stored

| Table | Managed by | Holds |
|---|---|---|
| `auth.users` | Supabase Auth | Email, hashed password, login sessions |
| `public."User"` | This project | Everyone: `username`, `firstname`, `surname`, `email`, `phonenumber`, `role`, and the `userid` referenced by all other tables |
| `public.citizen` | This project | Citizen-only details: `residence` |
| `public.investigator` | This project | Investigator-only details: `rank`, `badgenumber`, `station`, `unit`, `dutystatus` |

* `role` is an enum: `citizen`, `investigator` or `admin`. Admins have no extra details, so they only have a `"User"` row.
* `"User".authid` links each profile to its Supabase Auth account. Passwords and tokens are **never** stored in our tables; the app sends them straight to Supabase Auth.
* The database guarantees a citizen row only belongs to a citizen and an investigator row only to an investigator.

## How accounts are created

* **Citizens** register in the app (`supabase.auth.signUp`), sending their username, name, phone number and residence. A database trigger creates their `"User"` and `citizen` rows. **App sign-ups are always citizens.** A role sent from the app is ignored.
* **Investigators** do not register themselves. An admin will create them from the admin screen through the `create-investigator` Edge Function, which emails them a code to set their own password. *(The Edge Function is not built yet; until then investigator accounts are created by the database owner, and the investigator screens themselves are still to come.)*
* **Admins** are set up manually by the database owner (see `database/README.md`).
* **Login** uses a **username**. The app looks up the matching email with `email_for_username`, then signs in with email + password and reads `role` to choose the dashboard.
* **Deleted accounts:** if a login is deleted, the profile row is kept (with `authid` empty) so the evidence trail on cases and uploads is preserved.

## Who can see and do what (row-level security)

Every table has RLS enabled. The mobile app uses the **publishable key** and the logged-in user's token, so each query automatically returns only the rows that user is allowed to see.

| Role | Access |
|---|---|
| **Citizen** | Report incidents and upload footage as themselves; view only their own submissions and profile; edit their own username, name, phone number and residence |
| **Investigator** | View only cases they are actively assigned to, plus that footage, detections, vehicle details and the case history; move a case between open and under review; confirm (verify) AI detections; log corrections; view cross-incident links and other investigators; change their own duty status |
| **Admin** | Full access; review submissions (accept into a case, reject, mark duplicate); accept suggested matches; create, edit, close and reopen cases; assign investigators and choose the lead; confirm suspects; manage users and investigator details |
| **Not logged in** | No access to any table (only the username lookup used by the login screen) |

The Python AI/CV pipeline uses the **service role (secret) key**, which bypasses RLS, to write detections and update processing status. Only that key can write the AI fields (per-clip descriptions, the combined summary, capture times); the database refuses them from the app. This key must **never** be placed in the mobile app or committed to Git. What the pipeline must write, and in which order, is in [`database/README.md`](./database/README.md#the-ai-pipeline-what-it-writes).

## From submission to case

**A citizen submits, the AI analyses, the admin decides.**

1. A citizen reports an incident and uploads footage. It starts as **Pending review**.
2. The AI pipeline (to be built) describes each clip, writes one combined summary, reads plates and links the same vehicle or suspect across reports.
3. The admin works through the **Submissions** tab: Newest / Oldest, grouped by Location, Status, Case, or Linked (submissions the AI connected). Each card shows the citizen's description **and** the AI summary.
4. The database suggests which case a submission belongs to (AI links, same or nearly the same plate, distance, time from the footage's own metadata), with the reasons. The admin reviews the **Suggested matches** list and accepts the right ones in one tap, or accepts a submission into a new or existing case by hand. **Nothing joins a case without an admin accepting it.**
5. Inside a case the admin assigns investigators (the first becomes the lead), sees recommended submissions, and can remove a submission again: it goes back to Pending and is never deleted.
6. Every step is recorded in the case history (`caseevent`).

Details: [`database/README.md`](./database/README.md#how-a-submission-becomes-a-case).

## Using it from Flutter (`supabase_flutter`)

```dart
// Register (always creates a citizen account)
await supabase.auth.signUp(email: email, password: password, data: {
  'username': username, 'firstname': firstname, 'surname': surname,
  'phonenumber': phone, 'residence': residence,
});

// Log in with a username, then read the role to decide which dashboard to show
final email = await supabase.rpc('email_for_username',
    params: {'p_username': username}) as String?;
await supabase.auth.signInWithPassword(email: email!, password: password);
final profile = await supabase
    .from('User')
    .select('userid, username, firstname, surname, role')
    .eq('authid', supabase.auth.currentUser!.id)
    .single();
// profile['role'] -> 'admin' | 'investigator' | 'citizen'

// Reads are filtered automatically by RLS.
// Most screens call database functions instead of reading tables directly,
// e.g. one page of submissions (see database/README.md for all of them):
final page = await supabase.rpc('list_submissions', params: {'p_review': 'pending'});
```

---

# Database Workflow

All Supabase CLI commands are run from the `database/` folder (the folder that contains `supabase/`). Git commands are run from the repository root.

## First-time setup

```bash
cd database
supabase login
supabase link --project-ref <project-ref>   # ask the team for the project ref and database password
supabase migration list                     # every migration should appear under both Local and Remote
```

## Making a database change

The full step-by-step guide is in [`database/README.md`](./database/README.md#workflow-making-a-database-change). In short:

1. Create a branch, then check GitHub and Supabase match:
   ```bash
   cd database
   supabase migration list     # Local and Remote must be identical
   supabase db pull            # should say "No schema changes found"
   ```
2. Create a new migration and write the SQL in the new file under `supabase/migrations/`:
   ```bash
   supabase migration new short_descriptive_name
   ```
3. Check, then apply it to the Supabase database:
   ```bash
   supabase db push --dry-run  # must list only your new migration
   supabase db push
   ```
4. Commit the migration file on your feature branch and open a Pull Request.

## Rules

* Do **not** change tables, columns, or policies in the Supabase dashboard. If a change is ever made there, run `supabase db pull` straight away so it is captured as a migration.
* Do **not** edit a migration that has already been pushed. Create a new migration instead.
* New tables automatically get RLS enabled (via the `ensure_rls` event trigger) but have **no policies**, so the app cannot read them until policies are added in a migration.

## Troubleshooting (Windows)

* **`Bind for 0.0.0.0:54320 failed: port is already allocated`** during `supabase db pull`: a leftover Docker container is using the port. Find it with `docker ps -a --filter "publish=54320"` and remove it with `docker rm -f <ID>`.
* **`ports are not available ... 54320`** during `supabase db pull`: Windows has reserved that port. Restart the NAT service in an Administrator PowerShell (`net stop winnat` then `net start winnat`), or set `shadow_port` to a free port under `[db]` in `supabase/config.toml`.
* **`db pull` writes a file that only drops and re-adds the same CHECK constraints:** a false alarm. Answer **No** to updating the migration history and delete the file. See `database/README.md`.
* **Docker errors:** make sure Docker Desktop is running and `docker info` works before running Supabase CLI commands.

---

# Security and Privacy

Argus Shield deals with potentially sensitive investigation-related information.

Security and privacy must therefore be considered throughout development.

Never commit the following to the repository:

* Passwords
* Supabase API keys or service role keys
* Authentication tokens
* Database credentials
* Personal information
* Sensitive datasets
* Private investigation footage
* Hard-coded secrets
* Environment-specific credentials

Sensitive configuration should be stored using appropriate environment variables or other secure configuration mechanisms (e.g. Supabase project settings, `.env` files excluded from Git).

The following types of files should generally be excluded using `.gitignore`:

```text
.env
credentials.json
passwords.txt
database_passwords.txt
node_modules/
build/
.gradle/
venv/
```

If sensitive information is accidentally committed, notify the team immediately rather than simply deleting it in a later commit.

---

# Documentation

Project documentation should be stored in the `docs/` directory, with diagrams stored in `diagrams/`.

Examples include:

* System architecture (C4 diagrams)
* Database design and ERD
* UI mockups/wireframes
* API documentation
* Research
* Design decisions
* Testing documentation
* User documentation

The root `README.md` should contain information needed to understand and get started with the project.

Detailed technical documentation should generally be placed inside `docs/`.

---

# Testing

All contributors should test their changes before submitting a Pull Request.

Testing should be appropriate to the component being modified.

Examples include:

* Flutter widget and unit testing: run `flutter analyze` and `flutter test` in `mobile/argus_shield/` (the admin screens are tested against an in-memory fake, so no Supabase project is needed)
* Supabase/API integration testing
* AI model testing
* Database testing, including RLS policy testing: log in as a citizen, an investigator, and an admin and confirm each only sees what it should
* Demo data: a SQL script with demo submissions, a demo case, footage, AI descriptions and AI links (kept outside the repository; see [`database/README.md`](./database/README.md#testing))
* Integration testing across mobile app, Supabase, and AI component

Test results should be documented where appropriate.

The `tests/` directory should contain reusable test code, scripts, and relevant testing resources.

Before creating a Pull Request, ensure that your changes:

* Work as expected.
* Do not introduce obvious regressions.
* Do not break other components.
* Have been tested in the appropriate environment.

---

# GitHub Issues

GitHub Issues should be used to track:

* Bugs
* Features
* Tasks
* Improvements
* Research items
* Technical problems

Each issue should clearly describe:

* What needs to be done.
* Why it needs to be done.
* The expected outcome.
* The team member responsible, where applicable.

Examples:

```text
Bug: Vehicle detection crashes when uploading video

Feature: Add investigator search functionality

Task: Create database relationship diagram

Research: Evaluate vehicle detection model performance
```

---

# Collaborators

* [Carel von Ronge](https://github.com/MeanBanana)
* [Deacon George Nel](https://github.com/Deacs-ifbb)
* [Claire Aimee Duke](https://github.com/Claireeduke)
* [Eliandro Cidy Gomez Miranda](https://github.com/EliandroGomesMiranda)
* [Melusi Sikakane](https://github.com/melumbulelosikakane-lang)

---

# Project Status

Argus Shield is currently under active research and development.

| Part | State |
|---|---|
| Login / registration (citizen) | Live on Supabase Auth |
| Admin dashboard: Overview, Cases, Detectives, Submissions | Live on the database (review, cases, assignments, suggestions, history) |
| Citizen upload / My submissions / Profile | **Local demo only**: reports are kept in memory for the session and are not saved to Supabase yet |
| Investigator screens | **Not built yet**: an investigator who logs in is told so and signed out again |
| Creating investigator accounts from the app | **Not built yet**: needs the `create-investigator` Edge Function |
| Footage storage | **Not built yet**: no Supabase Storage bucket or storage policies |
| AI / computer vision pipeline | **Not built yet** (`ai/` is empty). The database is ready for it; demo data stands in for it |


Individual components may be at different stages of development. Features should not be considered production-ready unless they have been implemented, tested, and reviewed by the team.

---

# Project Goal

The goal of Argus Shield is to create a computer vision-based intelligence application capable of assisting investigations by transforming video footage into structured, searchable suspect and vehicle information.

The project aims to combine:

```text
Video Footage
      |
      v
Computer Vision / AI
      |
      v
Information Extraction
      |
      v
Database (Supabase/PostgreSQL)
      |
      v
Backend (Supabase)
      |
      v
Investigator Interface (Flutter mobile app)
```

The system should ultimately allow investigators to efficiently search, retrieve, and analyse relevant suspect and vehicle intelligence extracted from CIT robbery footage.

Development should maintain appropriate ethical, security, privacy, and responsible-AI considerations throughout the project. In particular, the system is designed as a decision-support tool: it does not determine guilt, make arrests, or take autonomous enforcement action — investigators remain responsible for reviewing and acting on system-generated intelligence.

---

# Repository Information

**Repository:** `cit-event-capture`

**Project Name:** Argus Shield

**Primary Branch:** `main`

**Project Type:** Research and Development

**Focus:** Computer Vision, Artificial Intelligence, Investigation Support, Data Management

---

This project is currently not licensed for redistribution.

The team should decide on the appropriate license before publicly distributing the project.
