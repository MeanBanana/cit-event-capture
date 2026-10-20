# Building the Android APK for the website

The website's **Get the app** section offers `web/landing/public/downloads/argus-shield.apk`
to Android phones only (other devices get a QR code / message, and Netlify
refuses the file to them: `web/landing/netlify/edge-functions/apk-guard.ts`).

All commands are for **Command Prompt** on the laptop with Flutter.

---

## 1. Once: make the team's signing key

Android only installs an **update** if it is signed with the same key as the
installed app. Make one key, keep it safe, and use it for every APK you publish.

```
cd %USERPROFILE%\Documents\Argus\cit-event-capture\mobile\argus_shield\android\app
keytool -genkey -v -keystore argus-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias argus
```

* `keytool` comes with Android Studio's Java. If Command Prompt says it's not
  recognised, use the full path, e.g.
  `"C:\Program Files\Android\Android Studio\jbr\bin\keytool" -genkey ...`
* It asks for a password (twice) and your name / organisation (any values).

Then create the file `mobile\argus_shield\android\key.properties` (Notepad)
with your password:

```
storePassword=THE_PASSWORD
keyPassword=THE_PASSWORD
keyAlias=argus
storeFile=argus-upload.jks
```

**Never commit these two files** (`.gitignore` already skips `key.properties`
and `*.jks`). Back them up somewhere private (e.g. a USB stick or a private
cloud folder). If the key is lost, people must uninstall the app before they
can install a newer APK.

Without `key.properties` the build still works, but signs with the debug key
(fine for testing, not for the website).

## 2. Every release: bump the version

In `mobile\argus_shield\pubspec.yaml`:

```
version: 1.0.1+2
```

The number after `+` must go **up** every time you publish, or phones refuse
to install it as an update. Also update `version` (and `size`) under
`download` in `web\landing\src\content.ts` so the website shows the same.

## 3. Build

```
cd %USERPROFILE%\Documents\Argus\cit-event-capture\mobile\argus_shield
flutter clean
flutter pub get
flutter build apk --release --split-per-abi
```

`--split-per-abi` makes one small APK per phone chip type. The one almost every
phone from the last 8 years needs is **arm64-v8a**:

```
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

(For one APK that runs on every phone, including very old 32-bit ones, leave
out `--split-per-abi` and use `app-release.apk`. It is about 2-3 times bigger.)

## 4. Test it on a phone first

Copy the APK to an Android phone (USB, WhatsApp to yourself, Google Drive...),
install it, and check: register, log in, upload a report, the AI result
appears for admins. Release builds behave differently from `flutter run`
debug builds, so always test the release APK itself.

## 5. Put it on the website

```
copy build\app\outputs\flutter-apk\app-arm64-v8a-release.apk ..\..\web\landing\public\downloads\argus-shield.apk
```

Then commit and push. Netlify redeploys and the website's Download button
serves the new APK.

* Keep the APK under 100 MB (GitHub's file limit); the arm64 APK is far below that.
* The file name must stay `argus-shield.apk` (the website links to it).

## How the "Android phones only" rule works

1. **On the page** (`web/landing/src/lib/device.ts`): the browser reports its
   platform. Android **phones** see *Download for Android*; computers see a QR
   code to open the page on their phone; iPhones and Android tablets see why
   they can't download it.
2. **On Netlify** (`netlify/edge-functions/apk-guard.ts`): a request for
   `/downloads/...` only gets the file when the browser says it is Android
   *and* mobile. Anything else gets "Android phones only" (HTTP 403), even
   with the direct link.

A browser can be told to pretend to be another device, so this keeps the
download for the devices it's meant for; it isn't a security lock. Nothing in
the app is secret: logins and data are protected by Supabase.

On a phone with Chrome's **Desktop site** switched on, the phone looks like a
computer; the page tells people to switch it off.
