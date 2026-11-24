# GhostGPT KitKat — Android 4.4.4 (API 19)

A separate, lightweight native Android app for the **MW22-A32 tablet** photographed by the user. It targets **Android 4.4 KitKat**, API 19, and does not replace the existing Android 8+ GhostGPT application.

## Capabilities

- **Private model chat:** HTTPS OpenAI-compatible `/v1/chat/completions` requests; model URL, model ID, and a bearer token are entered in the app. The token is **never saved to disk** because Android 4.4 lacks modern secure Keystore encryption support. Android 4.4 often cannot negotiate modern TLS; the app fails closed rather than disabling certificate verification.
- **Browser launcher:** Opens a selected HTTPS page using a separately installed browser. It does not embed an outdated Android 4.4 WebView for sensitive internet browsing.
- **Developer diagnostics:** Android build and CPU, local IP, protected ADB state, and the published `service.adb.tcp.port` property. Shortcuts to Android Developer options, system settings, Wi-Fi, and Unknown sources.
- **Wireless debugging controls integrated in GhostGPT:** The new **Wireless** tab reads legacy ADB status, verifies trusted private Wi-Fi and pre-existing `su` UID 0, and can enable/disable ADB TCP port 5555 after explicit user confirmation. On KitKat there is no modern wireless pairing. Without root, use an already-authorized USB ADB connection.
- **Root tools integrated in GhostGPT:** Checks for a working `su`, UID 0, identity, filesystem mounts, memory, disk use, firmware properties, SELinux and ADB TCP status; also offers a root-manager shortcut and manually entered commands, each requiring confirmation. If your separate root app grants `su`, GhostGPT can use that permission. It does not install root exploits or bypass authorization.

## Build and installation

GitHub Actions: **Build GhostGPT Android KitKat 4.4 APK**. The CI produces `android-kitkat/app/build/outputs/apk/debug/app-debug.apk` and verifies `minSdkVersion=19` and APK signing. A private MSI signing key can produce a consistent locally signed APK for future updates.

For the tablet, first confirm the chip's ABI in Debug (or via trusted ADB `getprop ro.product.cpu.abi`). The legacy app contains no native ABI-specific libraries and can run on ARM or x86 when the Android API requirement is met.

The user should transfer the verified APK using the USB drive and install manually through the tablet's File Manager or Package Installer after enabling Unknown sources, if required. Never automatically change system settings or run a silent installation.

## Chrome compatibility

Chrome 138+ (Android 8/10+) and GhostGPT Android 0.3 (Android 8+) **will not install on Android 4.4.4**. For an optional standalone browser, APKMirror lists Chrome **81.0.4044.138** with `minSdkVersion=19` and `armeabi-v7a`, SHA-256 `018ba2baec8015a6a90d8363b639ab56632613e9a68ca2b0811ba658a7887aa9`. Download from an authorized source and **verify both file SHA-256 and Google signing certificate before installation**. Do not mislabel HTML downloads as APKs or bypass access restrictions.

Chrome 81 was released in 2020 and does not receive security updates. Android 4.4.4 is similarly obsolete; avoid sensitive sites and passwords and keep this tablet on an isolated network.

## Limits

- Some newer HTTPS services, AI gateways, and websites cannot be used with KitKat's old certificate store/TLS stack, even with a properly installed app.
- No Android 11+ Wi-Fi pairing, no automatic root, no exploit payloads, no hidden remote administration.
- Hardware and browser compatibility require physical-tablet testing.

## KitKat 0.2.0: integrated Root and Wireless tabs

A pre-existing SuperSU or other compatible root manager must grant GhostGPT `su` authorization. Root tools never run from AI messages or on startup. **Wireless → Enable** requires both the user's trusted-private-Wi-Fi checkbox and an explicit confirmation; it verifies UID 0 before restarting Android's `adbd` on TCP port 5555. This exposes remote debugging to devices on the local network and should be disabled when finished. On Android 4.4 this is not Android 11-style wireless pairing. The separate APKs are not required to use these integrated features.

The app package is still `io.corelo.ghostgpt.kitkat` and versionCode is 2. Sign updates using the existing persistent MSI signing key; never replace it with a new CI debug key when installing over the previous build.
