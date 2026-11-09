# MW22-A32 KitKat Root Tools + Wireless ADB

Two **separate native APKs** built for Android 4.4.4 (minSdk 19) and intended for the MediaWave/Techland MW22-A32 touchscreen.

## 1. Ghost Root Tools
Android package: `io.corelo.ghostgpt.rootkitkat`.

- Request **existing** root access using `su -c id -u`; report UID 0 if available.
- Inspect mount points, identity and build information.
- Manually enter a command to run with `su -c`, with confirmation before each command.
- No root exploit or silent privilege escalation is included.

Community reports indicate that **some**, not all, MW22-A32 devices shipped with SuperSU, but factory root and a functioning `su` binary are not guaranteed. A nonworking SU manager cannot be fixed just by installing this APK. Do not install third-party one-click-root software from unverified sites.

## 2. Ghost Wireless ADB
Android package: `io.corelo.ghostgpt.wirelesskitkat`.

- Show current local IP address, ADB TCP port property, developer debugging status.
- Explicit confirmation-gated **Enable wireless ADB**: verify `su` returns UID **0**, then run as root `setprop service.adb.tcp.port 5555; stop adbd; start adbd`.
- Explicit confirmation-gated **Disable wireless ADB**: verify UID 0 then run `setprop service.adb.tcp.port -1; stop adbd; start adbd`.
- Buttons to open Developer options and show authorized USB-ADB alternative if root is unavailable.
- Does **not** persist an open ADB port across reboots.

On Android 4.4, ADB TCP on 5555 is **not** the Android 11+ wireless pairing protocol. Opening it creates a potentially sensitive remote debugging service accessible to devices on the same network. Use only an isolated private LAN, turn it off when finished, and avoid exposing TCP 5555 to the internet or untrusted Wi-Fi.

**Non-root alternative:** On the owner's trusted Windows PC, connect the device using a data-capable USB cable, enable USB debugging in the tablet's Developer options, approve the prompt on the tablet, then run `adb tcpip 5555` and `adb connect <private-tablet-ip>:5555`. Once finished, `adb usb` or a reboot returns to USB mode. No APK can bypass Android's authorization prompts.

## Installation
1. Copy the two verified APKs to the USB alongside `GhostGPT.apk` and `Firefox.apk`.
2. On the tablet, enable **Unknown sources** if needed, open its File Manager and install each APK.
3. Open Ghost Root Tools and test `su -c id -u`.
4. Only after getting UID 0, open Ghost Wireless ADB, review its risk warning, and enable ADB TCP on a private network. Connect from Windows using `adb connect <tablet-ip>:5555`; disable it when complete.
5. If the first root check reports `su` unavailable, the wireless app cannot turn on ADB TCP by itself; use the authorized USB connection instead.

These apps are KitKat compatibility builds, **not** a replacement for an up-to-date OS or verified jailbreak/root exploit. Installation and root testing on the physical tablet remain necessary.
