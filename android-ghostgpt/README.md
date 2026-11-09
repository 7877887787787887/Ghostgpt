# GhostGPT Android — native APK with local root tools

This is a **separate native Android client** in the GhostGPT repository, not a conversion of the SwiftUI iOS code or an iPhone IPA. The debug APK targets Android API 26+ (Android 8.0+).

## Features
- Chat with your own HTTPS OpenAI-compatible model API, including GhostGPT's authenticated LM Studio gateway (`https://msi.tail28f016.ts.net/model`) and a configurable model ID.
- Web browser with file/content access disabled, strict mixed-content blocking, Safe Browsing, and third-party cookies disabled.
- **Android root tools**: on an already-rooted device, users may explicitly authorize `su -c id -u`, read-only diagnostics, or a manually entered command. Root is *never* invoked automatically by chat/AI, and every command requires a separate confirmation dialog. Custom root commands require an additional session-only opt-in.
- Private gateway SSH diagnostic screen with exact host alias and username. The Windows GHOST gateway independently enforces SSH host and read-only command allow-lists.
- Android Keystore AES-GCM encrypted bearer-token storage (separate tokens for model chat and SSH).

## Build
Run the **Build GhostGPT Android APK** GitHub Actions workflow from this branch, or use Android Studio and JDK 17:
```sh
gradle -p android-ghostgpt :app:assembleDebug
```
Artifacts are in `android-ghostgpt/app/build/outputs/apk/debug/app-debug.apk`. This is an installable **debug-signed** APK for testing, not a release-signed production app. For release updates, use a persistent signing key; debug builds should not be distributed as verified releases.

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
