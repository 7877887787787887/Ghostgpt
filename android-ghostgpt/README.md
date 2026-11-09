# GhostGPT Android — native APK with local root tools

This is a **separate native Android client** in the GhostGPT repository, not a conversion of the SwiftUI iOS code or an iPhone IPA. The Android 0.3 app targets API 26+ (Android 8.0+). CI produces separate **production** and **preview** debug APKs.

## Features
- Chat with your own HTTPS OpenAI-compatible model API, including GhostGPT's authenticated LM Studio gateway (`https://msi.tail28f016.ts.net/model`) and a configurable model ID.
- Web browser with file/content access disabled, strict mixed-content blocking, Safe Browsing, and third-party cookies disabled.
- **Developer/debugging toolbox**: inspect Android version, manufacturer, CPU ABIs, security patch, ADB status, TCP debugging port, SELinux mode, local network addresses, and build properties. Developer options, Wi-Fi settings, install-unknown-apps permissions, accessibility, and the device's own app settings open only through Android's official Settings activities. Copy guidance for Android 11+ wireless ADB pairing and legacy Android 8–10 authenticated ADB.
- Additional consent-gated root diagnostics: build fingerprint, ADB TCP status, battery, and recent logs, when root has already been granted independently.
- **Android root tools**: on an already-rooted device, users may explicitly authorize `su -c id -u`, read-only diagnostics, or a manually entered command. Root is *never* invoked automatically by chat/AI, and every command requires a separate confirmation dialog. Custom root commands require an additional session-only opt-in.
- Private gateway SSH diagnostic screen with exact host alias and username. The Windows GHOST gateway independently enforces SSH host and read-only command allow-lists.
- Android Keystore AES-GCM encrypted bearer-token storage (separate tokens for model chat and SSH).

## Build
Run the **Build GhostGPT Android APK** GitHub Actions workflow from this branch, or use Android Studio and JDK 17:
```sh
gradle -p android-ghostgpt :app:assembleProductionDebug :app:assemblePreviewDebug
```
The build creates `android-ghostgpt/app/build/outputs/apk/production/debug/app-production-debug.apk` and `android-ghostgpt/app/build/outputs/apk/preview/debug/app-preview-debug.apk`. Both are initially CI debug-signed APKs. **Preview** has a separate package ID (`io.corelo.ghostgpt.android.preview`), so it can be installed beside an older `io.corelo.ghostgpt.android` installation without removing its data. It is not an in-place update. For persistent production updates, sign production builds with the *same user-controlled key* each time, stored securely outside GitHub.

## Setup
1. Install the APK on Android 8.0 or later. It can run unrooted, but root tools will not work unless a root solution is **already** installed and grants this app `su` permission.
2. In **Settings**, enter the HTTPS model endpoint, the exact served model ID, and its private bearer token. Tap **Save connection settings**. The token is encrypted by Android Keystore, and never sent to WebView.
3. Open **Chat** to send messages. There is no automatic command execution, no AI-directed root access, and no implicit remote shell.
4. On a separately rooted device, open **Root** and approve a diagnostic. If your root manager asks for permission, review it carefully.
5. For remote SSH commands, configure the private GHOST gateway, its separate bearer token, and an alias on the server in `GHOSTGPT_SSH_HOSTS`. The app only submits one manually confirmed request and the gateway enforces its read-only allow-list.

## Boundaries
- A normal Android APK **cannot root a device just by being installed**. This project contains no rooting exploit, bootloader bypass, unattended root escalation, or hidden background control.
- Root commands run with the device's privileges. Manually entered commands can damage, wipe, or render it unbootable. Do not run commands you do not understand.
- Debug builds are not production-hardened. There is no guarantee of functional compatibility with every Fire TV model or Android TV remote input; physical-device testing is required.
- The app does not include iOS jailbreak tooling. Those features are specific to separate iOS work.
- No shell, token, or root endpoint is exposed from the Android device. The browser is not a desktop streaming client.

## Developer options and wireless debugging

On Android 11+, open **Debug → Open Wireless debugging / pairing**, then pair from your authorized computer using the on-screen port and code. The app **does not pair automatically** or elevate permissions.

On Android 8–10, including legacy Fire TV builds, standard Android 11 wireless pairing is unavailable; using `adb tcpip 5555` from a previously authorized computer can expose a TCP debugging interface to the network. Only use it on a trusted isolated network; disable it when finished. GhostGPT does not enable this network port on its own.

**Android permissions are enforced:** ordinary apps cannot silently turn on USB debugging, modify developer options, defeat a locked bootloader, unlock another device, or obtain root. Some Fire TV firmwares hide or replace Android developer options pages; the app falls back to the device's available Settings menu.

## USB and update-signing workflow

The MSI PC stores an independent persistent signing key for USB distribution. The plain Android debug artifact created on ephemeral GitHub runners will not necessarily update a previous debug installation. Never remove an existing installation or its data automatically to bypass `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

To test safely alongside an older app, install the **preview** APK (`io.corelo.ghostgpt.android.preview`). The **production** APK remains the canonical package (`io.corelo.ghostgpt.android`) and should be signed consistently by the trusted MSI signing process before copying to the USB. Only the latest APK needs to be visible at the root of the USB; older releases can stay in its hidden `APKs` folder.

Browser navigation only allows HTTPS, rejects credentials embedded in URLs, blocks mixed content and disables third-party cookies. The WebView is destroyed when its tab closes to avoid leaking memory and keeping hidden pages active.
