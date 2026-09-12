# ZCode

[中文](README.md) | **English**

> ZCode App is a personal, unofficial project and is not affiliated with Z.ai. ZCode and related names and trademarks belong to their respective owners.
>
> Built on top of the upstream open-source project [pjpv/zremote](https://github.com/pjpv/zremote): the original "scan-to-import + WebView session" app reworked into a ZCode mobile control client.

ZCode App (v1.0.6) is a mobile companion app for ZCode desktop's mobile remote-control feature. The desktop shows a QR code; scan it once (or paste the control link) to import a device — it stays usable long-term. Multiple machines can be managed in parallel from one UI.

<p align="center">
  <img src="docs/screenshots/device-light.png" width="260" alt="ZCode device management in light mode" />
  <img src="docs/screenshots/device-dark.png" width="260" alt="ZCode device management in dark mode" />
  <img src="docs/screenshots/settings-light.png" width="260" alt="ZCode settings" />
</p>

## How it works

- **Native shell** — device management, settings and notifications are native Flutter UI.
- **Session = WebView** — entering a device loads ZCode desktop's remote-control page in a bundled WebView: the desktop page itself, not a re-implementation. Navigation is allowlisted and injected scripts are restricted to `https://zcode.z.ai`.
- **Notifications** — approval requests, completions and failures alert in-app while the app is open and as system notifications after it leaves the foreground. No persistent "running" notification is shown.
- **In-app updates (Android)** — the app checks GitHub Releases, downloads the exact APK asset with resumable download and SHA256 verification, pre-checks package identity and version code, then hands the file to the system installer.
- **Simplified Chinese UI** — intentionally fixed; there is no language switcher.

## Download & install

Grab a build from [Releases](https://github.com/2421873411a-rgb/ZCode-App/releases):

- **Android** — `ZCode-v<version>.apk` (arm64), application ID `com.zcode.app`
- **iOS** — not supported; this is an Android-only project and no IPA is published

## Building

Requirements: Flutter ≥ 3.47 (Dart ≥ 3.10), Android SDK 36, JDK 17.

Release builds require `android/key.properties` with a real keystore; GitHub Actions uses the `KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` repository secrets. Without them the release workflow fails on purpose — there is no debug-key fallback.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

## Repository layout

```text
lib/          native shell (device, settings, update UI), WebView session host, notifications, update service
android/      MainActivity, notification plumbing, legacy-upgrade cleanup
docs/         protocol notes, release checklist, design assets (historical docs in docs/archive/)
test/         Dart unit & widget tests
```

## Disclaimer

ZCode App loads the official ZCode desktop remote-control page inside a WebView; it does not forge requests and does not bypass authentication. Control links (`sid`/`hash`) are credentials — keep them private and never commit them.

## License

[MIT](LICENSE)
