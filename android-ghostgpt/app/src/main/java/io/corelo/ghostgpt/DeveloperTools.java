package io.corelo.ghostgpt;

import android.content.Context;
import android.os.Build;
import android.provider.Settings;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.concurrent.TimeUnit;

/**
 * Read-only Android/Fire TV diagnostics. This class never modifies protected settings,
 * starts adbd, installs binaries or runs privileged shell commands.
 */
final class DeveloperTools {
    private DeveloperTools() { }

    static String report(Context context) {
        StringBuilder text = new StringBuilder();
        text.append("DEVICE\n");
        text.append("Manufacturer: ").append(Build.MANUFACTURER).append("\n");
        text.append("Model: ").append(Build.MODEL).append("\n");
        text.append("Android: ").append(Build.VERSION.RELEASE)
            .append(" / API ").append(Build.VERSION.SDK_INT).append("\n");
        text.append("Security patch: ").append(Build.VERSION.SECURITY_PATCH).append("\n");
        text.append("CPU ABIs: ").append(String.join(", ", Build.SUPPORTED_ABIS)).append("\n");
        text.append("Build type: ").append(Build.TYPE).append("\n");
        text.append("Build tags: ").append(Build.TAGS).append("\n\n");
        text.append("DEVELOPER CONFIGURATION\n");
        text.append("Developer options: ").append(globalBoolean(context, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED)).append("\n");
        text.append("ADB debugging: ").append(globalBoolean(context, Settings.Global.ADB_ENABLED)).append("\n");
        text.append("adbd service: ").append(property("init.svc.adbd")).append("\n");
        text.append("ADB TCP port: ").append(property("service.adb.tcp.port")).append("\n");
        text.append("ro.debuggable: ").append(property("ro.debuggable")).append("\n");
        text.append("SELinux: ").append(simpleCommand("getenforce")).append("\n\n");
        text.append("LOCAL IPv4 ADDRESSES\n").append(ipv4Addresses()).append("\n");
        if (Build.VERSION.SDK_INT >= 30) {
            text.append("Android 11+: Wireless debugging pairing is managed by Developer options. ");
            text.append("Open system settings and approve the pairing there; this app cannot turn it on silently.\n");
        } else {
            text.append("Android 8–10: There is no standard Android 11 wireless-debugging pairing page. ");
            text.append("A previously authorized ADB host may configure legacy TCP debugging, but TCP ADB ");
            text.append("may be exposed to other devices on the network. Avoid untrusted Wi-Fi.\n");
        }
        return text.toString();
    }

    private static String globalBoolean(Context context, String setting) {
        try {
            int value = Settings.Global.getInt(context.getContentResolver(), setting, -1);
            return value == 1 ? "Enabled" : value == 0 ? "Disabled" : "Not reported";
        } catch (SecurityException error) {
            return "Restricted by Android permissions";
        } catch (Exception error) {
            return "Unavailable";
        }
    }

    private static String property(String name) {
        return simpleCommand("getprop", name);
    }

    private static String simpleCommand(String... args) {
        Process process = null;
        try {
            process = new ProcessBuilder(args).redirectErrorStream(true).start();
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                return "Timed out";
            }
            if (process.exitValue() != 0) return "Unavailable";
            try (InputStream input = process.getInputStream();
                 ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                byte[] part = new byte[256];
                int length;
                while ((length = input.read(part)) > 0 && bytes.size() < 512) {
                    bytes.write(part, 0, Math.min(length, 512 - bytes.size()));
                }
                String result = bytes.toString("UTF-8").trim();
                return result.isEmpty() ? "Not set" : result.substring(0, Math.min(result.length(), 256));
            }
        } catch (Exception error) {
            return "Unavailable";
        } finally {
            if (process != null) process.destroy();
        }
    }

    private static String ipv4Addresses() {
        StringBuilder result = new StringBuilder();
        try {
            for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!network.isUp() || network.isLoopback()) continue;
                for (java.net.InetAddress address : Collections.list(network.getInetAddresses())) {
                    if (address instanceof Inet4Address && !address.isLoopbackAddress()) {
                        result.append(network.getName()).append(": ")
                              .append(address.getHostAddress()).append("\n");
                    }
                }
            }
        } catch (Exception error) {
            result.append("Unavailable\n");
        }
        return result.length() == 0 ? "No non-loopback IPv4 address reported\n" : result.toString();
    }
}
