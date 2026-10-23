# Argus Shield — mobile app

Flutter app for Argus Shield, used by **citizens** (report CIT incidents and upload footage), **admins** (review submissions, run cases, manage investigators) and **investigators** (work their assigned cases). Data, login and access rules come from Supabase; see [`../../database/README.md`](../../database/README.md).

> **Just want to use the app?** Download the Android app from **<https://argus-shield.netlify.app/>**. Install steps are in the [root README](../../README.md#installing-the-app).

## Running it

```bash
flutter pub get
flutter run            # on an emulator or a connected phone (flutter devices lists them)
```

The app starts on the login page and routes by role: citizens to `CitizenHome`, admins to `AdminDashboard`, investigators to `InvestigatorDashboard`. New admins and investigators log in with a temporary password and must choose their own first (Choose Password screen). How accounts are made: [`database/README.md`](../../database/README.md#how-each-type-of-account-is-created).

After changing `AndroidManifest.xml` or `ios/Runner/Info.plist` (for example the reset-password deep link), stop the app and run `flutter run` again; hot reload and hot restart do not pick those files up.

What is live and what is still to come: see "Current status" in [`database/README.md`](../../database/README.md#current-status).

## Building an installer

```bash
flutter build apk --release      # -> build/app/outputs/flutter-apk/app-release.apk
```

That APK is what the website offers for download. Install it on a phone by opening the file (allow installs from that source when Android asks). The Android application ID is still the Flutter default `com.example.argus_shield` and release builds are signed with the debug key; set up a release key and a real ID before a store release.

Before pushing:

```bash
flutter analyze        # must say "No issues found!"
flutter test           # every test must pass
```

The Supabase project URL and **publishable** key are in `lib/main.dart`. That key is safe to ship because row-level security protects the data. The service role key must never be in the app.

## Folder layout

```text
lib/
├── main.dart                   ← starts Supabase and the app (login page first);
│                                  opens ResetPasswordPage when a reset link is tapped
├── login.dart                  ← login + "Forgot password?" panel (sends the reset email)
├── register_citizen.dart, loadingscreen.dart
├── reset_password.dart         ← "New Password" screen opened by the reset link
├── saved_contact_details.dart  ← remembers the last login's email/phone on the phone
│                                  (pre-fills Forgot password; never passwords)
├── temp_password.dart          ← rules + Generate for temporary staff passwords
├── app_settings.dart, settings_screen.dart
│                               ← language (English / Afrikaans / Zulu) and dark mode
├── sign_out_button.dart        ← logout icon in every dashboard's app bar
├── case_evidence_source.dart, submission_evidence_source.dart
│                               ← where the AI summary + people / vehicles / weapons come from
│                                  (the section itself is admin_screens/case_evidence_section.dart)
├── supabase_service.dart       ← EVERY call to Supabase goes through here
├── theme/
│   ├── app_theme.dart          ← colours, fonts, text styles, spacing, ThemeData
│   └── argus_widgets.dart      ← shared widgets (app bars, buttons, keepAboveSystemBars)
├── models/                     ← plain data classes built from database rows
│   ├── crime_scene_summary.dart   a submission (incident): review, AI summary, chips, filmed time
│   ├── case_summary.dart          a case with investigators (lead first) and a preview
│   ├── case_assignment_info.dart  an investigator on a case
│   ├── submission_groups.dart     location / linked groups, suggestions, clips, case history
│   ├── citizen_profile.dart       the logged-in citizen's details (Profile tab)
│   └── investigator_summary.dart, system_stats.dart, activity_item.dart
├── citizen/                    ← citizen dashboard: upload (1-5 files, phone GPS), my submissions,
│                                  profile. citizen_store.dart sends reports to Supabase and
│                                  queues them for the AI worker
├── investigator_dashboard/
│   ├── investigator_dashboard.dart   ← cases assigned to the signed-in investigator (RLS)
│   ├── investigator_case_detail.dart ← tabs: Scenes · AI summary · Activity · Chat; open ↔ under review
│   └── case_chat_tab.dart            ← live group chat for the case's investigators
└── admin_screens/
    ├── admin_dashboard.dart    ← tabs: Overview · Cases · Detectives · Submissions
    ├── overview.dart           ← status tiles, recent submissions, recent activity
    ├── submissions.dart        ← Newest/Oldest/Location/Status/Case/Linked views + cards
    ├── suggested_matches.dart  ← "N submissions match existing cases" bar + one-tap review
    ├── submission_detail.dart  ← one submission: descriptions, each clip, review actions
    ├── cases.dart              ← Cases tab (case cards: suspects, best suggestion + plate, preview)
    ├── case_detail.dart        ← one case: status, investigators, recommended, submissions, history
    ├── crime_scene_card.dart, crime_scene_page.dart
    │                           ← a case's crime scenes; findings + corrections (also used by investigators)
    ├── entity_crops_page.dart  ← every picture of one person / vehicle / weapon, "Is this Person 1?"
    ├── footage_list.dart, media_viewer_page.dart
    │                           ← a submission's clips; full-screen player / photo with Download
    ├── investigators.dart      ← Detectives tab
    ├── new_investigator_form.dart ← "+ New investigator" popup (create-investigator Edge Function)
    ├── review_actions.dart     ← Accept / Reject / Duplicate / Move / Remove flows
    ├── pickers.dart            ← slide-up panels to choose a case, submission or investigator
    ├── paged_list.dart         ← list that loads 30 rows at a time as you scroll
    └── admin_ui.dart           ← small shared pieces (cards, tags, chips, date formats)
test/
├── admin_fake_service.dart     ← in-memory stand-in for SupabaseService (no network)
├── login_redirect_test.dart    ← each role lands on the right screen after login
├── reset_password_test.dart    ← New Password screen: validation, save, cancel
└── *_test.dart                 ← other widget and model tests
```

## Login, registration and password reset

* **Login** asks for a username; `SupabaseService.loginUser` looks up the email and signs in, then `login.dart` sends citizens to `CitizenHome`, admins to `AdminDashboard` and investigators to `InvestigatorDashboard` via the 3-second `LoadingScreen`.
* **First log-in with a temporary password:** when the login's `app_metadata` has `must_change_password`, the app opens `ResetPasswordPage(firstLogin: true)` (Choose Password) instead of the dashboard; after saving, the user is signed out and logs in with the new password.
* **Forgot password?** opens a panel pre-filled with the email saved on this phone (`saved_contact_details.dart`). **Reset Password** calls `SupabaseService.sendPasswordReset`, which emails a link to `argusshield://reset-password`.
* Tapping the link **on the same phone** opens the app (intent filter in `android/app/src/main/AndroidManifest.xml`, URL scheme in `ios/Runner/Info.plist`). `supabase_flutter` checks it and fires `AuthChangeEvent.passwordRecovery`; `main.dart` listens for that and opens `ResetPasswordPage` in place of whatever was open (via the global `navigatorKey`). An expired link shows a message instead.
* `ResetPasswordPage` asks for the new password twice (at least 6 characters), saves it with `SupabaseService.updatePassword`, signs out and returns to Login with "Password changed, please log in". Cancel or Back also signs out, so the reset session never stays open.
* Supabase setup it needs (Redirect URL, SMTP): [`database/README.md`](../../database/README.md#setting-and-resetting-passwords).

## How the admin screens work

* **Submissions** loads 30 at a time and fetches more as you scroll (`PagedList`). The database pages with a cursor, so long lists stay fast.
* Each submission card shows the **citizen's description and the AI summary**, chips for what the AI saw (vehicles, suspects, "weapon seen", plates), and when it was **filmed** (from the footage's metadata) with a warning when that disagrees with the time the citizen typed.
* **Suspects (POPIA):** a person the AI saw is only a *possible* suspect until an investigator assigned to the case confirms or dismisses them. Admin screens show **counts only**: "about 2 possible suspects awaiting investigator review", "2 confirmed suspects". A case shows the highest of its submissions (A = 2, B = 1, C = 1 → about 2), counting the most people seen at once in one clip. Admins cannot confirm suspects.
* **Case cards** also show the case's best **suggested submission** (the same scoring as "Recommended for this case") with its most relevant **number plate**: one that is also in the case, else one a character off (an OCR misread), else the plate read with the highest confidence. The suggestions load once per page of cards after the cards appear (`getCaseCardSuggestions`), so they never slow down or break the list. Closed cases have none.
* **Suggested matches**: the green bar above the list opens a review list of submissions that probably belong to an existing case, with the reasons. The admin unticks anything wrong and accepts the rest in one tap. Nothing joins a case before that.
* **Accept** on a pending submission suggests cases first; "Case not listed? Create a new case" creates one and opens it.
* **Case page**: submissions as cards, recommended submissions with one-tap Add, remove (never deletes, goes back to Pending), lead investigator (star), and the case history.
* Every page stays above the phone's navigation buttons (`keepAboveSystemBars` in `theme/argus_widgets.dart`, used as the `builder` in `main.dart`).

## Conventions

* Screens never call Supabase directly: add a method to `SupabaseService`, then override it in `test/admin_fake_service.dart` so the tests keep working without a network.
* Colours, fonts and spacing come from `theme/app_theme.dart`, never hard-coded.
* Each admin tab returns only its body; `AdminDashboard` draws the Scaffold, header and tabs.
* Scrolling pages put their top/bottom padding **inside** the scroll view (`SingleChildScrollView(padding: ...)`), not in a `Padding` around it; otherwise the padding becomes fixed empty bands that cut the content off. Don't add extra bottom padding for the phone's buttons; `keepAboveSystemBars` already does that.
