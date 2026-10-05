# Argus Shield — mobile app

Flutter app for Argus Shield, used by **citizens** (report CIT incidents and upload footage), **admins** (review submissions, run cases, manage investigators) and, later, **investigators** (work their assigned cases). Data, login and access rules come from Supabase; see [`../../database/README.md`](../../database/README.md).

## Running it

```bash
flutter pub get
flutter run            # on an emulator or a connected phone
```

The app starts on the login page. Log in with a citizen account for the citizen screens or an admin account for the admin dashboard (how to create an admin: `database/README.md`, "Creating an admin"). Investigator screens are not built yet: an investigator who logs in is told so and signed out.

What is live and what is still a demo: see "Current status" in [`database/README.md`](../../database/README.md#current-status).

Before pushing:

```bash
flutter analyze        # must say "No issues found!"
flutter test           # every test must pass
```

The Supabase project URL and **publishable** key are in `lib/main.dart`. That key is safe to ship because row-level security protects the data. The service role key must never be in the app.

## Folder layout

```text
lib/
├── main.dart                   ← starts Supabase and the app (login page first)
├── login.dart, register_citizen.dart, loadingscreen.dart
├── supabase_service.dart       ← EVERY call to Supabase goes through here
├── theme/
│   ├── app_theme.dart          ← colours, fonts, text styles, spacing, ThemeData
│   └── argus_widgets.dart      ← shared widgets (app bars, buttons, keepAboveSystemBars)
├── models/                     ← plain data classes built from database rows
│   ├── crime_scene_summary.dart   a submission (incident): review, AI summary, chips, filmed time
│   ├── case_summary.dart          a case with investigators (lead first) and a preview
│   ├── case_assignment_info.dart  an investigator on a case
│   ├── submission_groups.dart     location / linked groups, suggestions, clips, case history
│   └── investigator_summary.dart, system_stats.dart, activity_item.dart
├── citizen/                    ← citizen dashboard: upload, my submissions, profile
│                                  (LOCAL DEMO: citizen_store.dart keeps reports in memory;
│                                   they are not saved to Supabase yet)
└── admin_screens/
    ├── admin_dashboard.dart    ← tabs: Overview · Cases · Detectives · Submissions
    ├── overview.dart           ← status tiles, recent submissions, recent activity
    ├── submissions.dart        ← Newest/Oldest/Location/Status/Case/Linked views + cards
    ├── suggested_matches.dart  ← "N submissions match existing cases" bar + one-tap review
    ├── submission_detail.dart  ← one submission: descriptions, each clip, review actions
    ├── cases.dart              ← Cases tab (case cards with a submissions preview)
    ├── case_detail.dart        ← one case: status, investigators, recommended, submissions, history
    ├── investigators.dart      ← Detectives tab
    ├── review_actions.dart     ← Accept / Reject / Duplicate / Move / Remove flows
    ├── pickers.dart            ← slide-up panels to choose a case, submission or investigator
    ├── paged_list.dart         ← list that loads 30 rows at a time as you scroll
    └── admin_ui.dart           ← small shared pieces (cards, tags, chips, date formats)
test/
├── admin_fake_service.dart     ← in-memory stand-in for SupabaseService (no network)
└── *_test.dart                 ← widget and model tests
```

## How the admin screens work

* **Submissions** loads 30 at a time and fetches more as you scroll (`PagedList`). The database pages with a cursor, so long lists stay fast.
* Each submission card shows the **citizen's description and the AI summary**, chips for what the AI saw (vehicles, people, "weapon seen", plates), and when it was **filmed** (from the footage's metadata) with a warning when that disagrees with the time the citizen typed.
* **Suggested matches**: the green bar above the list opens a review list of submissions that probably belong to an existing case, with the reasons. The admin unticks anything wrong and accepts the rest in one tap. Nothing joins a case before that.
* **Accept** on a pending submission suggests cases first; "Case not listed? Create a new case" creates one and opens it.
* **Case page**: submissions as cards, recommended submissions with one-tap Add, remove (never deletes, goes back to Pending), lead investigator (star), and the case history.
* Every page stays above the phone's navigation buttons (`keepAboveSystemBars` in `main.dart`).

## Conventions

* Screens never call Supabase directly: add a method to `SupabaseService`, then override it in `test/admin_fake_service.dart` so the tests keep working without a network.
* Colours, fonts and spacing come from `theme/app_theme.dart`, never hard-coded.
* Each admin tab returns only its body; `AdminDashboard` draws the Scaffold, header and tabs.
