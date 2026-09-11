# Design QA

## Source visual truth

- The user-provided image #2 is the icon reference: compact black Z mark with the original visual scale.
- The user-provided image #4 is the desktop remote-control reference: tablet layout, system bars, and desktop-like WebView content proportions.
- The user-provided images #5/#6 are the loading-state reference: the intermediate “正在加载工作区” card must not be shown while a connection is still loading.
- The user-provided image #7 is the settings reference: compact rows, system-following theme, and no biometric-lock row in this app’s settings entry.

## Implementation evidence

- `build/emulator-5554-empty-chinese-final.png` — empty state with “等待接入设备”, compact QR/link actions, system bars, and the corrected `ZCode` wordmark.
- `build/emulator-5554-device-card-chinese-final.png` — saved-device launcher state with “接入设备”, side-by-side “扫码 / 链接” actions, and the corrected `ZCode` wordmark.
- `build/emulator-5554-settings-chinese-final.png` — settings state with language switching removed, the biometric row removed, tighter spacing, update entry, and all three notification switches enabled.
- `build/emulator-5554-floating-notice-latest2.png` — in-app failure notification floating banner over the remote page.
- `build/emulator-5554-debug-fresh.png` — splash icon scale and system-bar treatment.

## QA notes

- Empty-state copy is now “等待接入设备”; the desktop-version import explanation is removed from both locales.
- Import actions are fixed in one row and use the short labels “扫码” and “链接”.
- The settings launcher card no longer renders the “安全 · 后台 · 通知 · 语言” subtitle, and the settings page no longer renders the biometric-lock tile.
- Enabled permission requests, task completion, and task failure events enter the native notification center and trigger the in-app floating banner; new installs default all three notification types to on.
- The loading handshake overlay is hidden during normal loading and is retained only for an actual failure state.

## Verification environment

- Android emulator `emulator-5554`, Android 15/API 35, 1080×2400, density 420.
- `flutter analyze`: passed.
- `flutter test --reporter compact`: 651 tests passed.
- `flutter build apk --debug`: passed; the final debug APK is `build/app/outputs/flutter-apk/app-debug.apk`.

final result: passed
