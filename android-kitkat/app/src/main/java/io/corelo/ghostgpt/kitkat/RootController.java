package io.corelo.ghostgpt.kitkat;

import android.os.SystemClock;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.IOException;

/**
 * Local, user-initiated root operations for Android API 19.
 * Never exposed to the AI model, a URL handler, remote clients or background services.
 * Installing this APK does NOT install su or elevate the tablet.
 */
final class RootController {
    private RootController() {}

    static final class Result {
        final int exit;
        final boolean timedOut;
        final String output;
        Result(int exit, boolean timedOut, String output) {
            this.exit = exit;
            this.timedOut = timedOut;
            this.output = output;
        }
        boolean success() { return exit == 0 && !timedOut; }
        String describe() {
            if (timedOut) return "Timed out waiting for su or the root manager. Check its authorization prompt.\n" + output;
            return "Exit " + exit + "\n" + output;
        }
    }

    static Result run(String cmd, int timeoutMillis) {
        if (cmd == null || cmd.length() == 0 || cmd.length() > 500)
            return new Result(-1, false, "Command must contain 1-500 characters.");
        Process process = null;
        Thread drain = null;
        final ByteArrayOutputStream captured = new ByteArrayOutputStream();
        try {
            process = new ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start();
            final InputStream input = process.getInputStream();
            drain = new Thread(new Runnable() {
                @Override public void run() {
                    try {
                        byte[] chunk = new byte[1024];
                        int n;
                        while ((n = input.read(chunk)) >= 0) {
                            synchronized (captured) {
                                if (captured.size() < 16384)
                                    captured.write(chunk, 0, Math.min(n, 16384 - captured.size()));
                            }
                        }
                    } catch (IOException ignored) {
                    } finally {
                        try { input.close(); } catch (IOException ignored) {}
                    }
                }
            }, "ghost-root-output");
            drain.setDaemon(true);
            drain.start();
            long deadline = SystemClock.uptimeMillis() + timeoutMillis;
            Integer exit = null;
            while (SystemClock.uptimeMillis() < deadline) {
                try {
                    exit = process.exitValue();
                    break;
                } catch (IllegalThreadStateException running) {
                    Thread.sleep(100);
                }
            }
            if (exit == null) {
                process.destroy();
                if (drain != null) drain.join(500);
                return new Result(-1, true, output(captured));
            }
            if (drain != null) drain.join(650);
            return new Result(exit.intValue(), false, output(captured));
        } catch (Exception error) {
            return new Result(-1, false, "Root command could not run: " + error.getMessage());
        } finally {
            if (process != null) process.destroy();
        }
    }

    private static String output(ByteArrayOutputStream bytes) throws Exception {
        synchronized (bytes) { return new String(bytes.toByteArray(), "UTF-8"); }
    }

    static boolean hasRoot(Result identity) {
        return identity != null && identity.success() && "0".equals(identity.output.trim());
    }

    static String status() {
        String port = unprivilegedProperty("service.adb.tcp.port");
        String service = unprivilegedProperty("init.svc.adbd");
        return "ADB TCP port: " + port + "\nADB service: " + service;
    }

    private static String unprivilegedProperty(String property) {
        Process proc = null;
        try {
            proc = new ProcessBuilder("getprop", property).start();
            long deadline = SystemClock.uptimeMillis() + 2000;
            boolean done = false;
            while (SystemClock.uptimeMillis() < deadline) {
                try { proc.exitValue(); done = true; break; }
                catch (IllegalThreadStateException running) { Thread.sleep(50); }
            }
            if (!done) return "not available";
            InputStream stream = proc.getInputStream();
            try {
                byte[] buffer = new byte[128];
                int len = stream.read(buffer);
                if (len <= 0) return "not set";
                String text = new String(buffer, 0, len, "UTF-8").trim();
                return text.length() == 0 ? "not set" : text;
            } finally { stream.close(); }
        } catch (Exception failure) { return "not available"; }
        finally { if (proc != null) proc.destroy(); }
    }

    /**
     * Changes only the local adbd transport. Calling code must obtain a fresh,
     * explicit approval and check for trusted private Wi-Fi before enabling.
     * Does not persist across reboot and never sets up a background service.
     */
    static String setWirelessAdb(boolean enable) {
        Result identity = run("id -u", 15000);
        if (!hasRoot(identity))
            return "Root unavailable. Your existing SU manager must grant GhostGPT root access.\n" + identity.describe();
        String action = enable
                ? "setprop service.adb.tcp.port 5555; stop adbd; start adbd"
                : "setprop service.adb.tcp.port -1; stop adbd; start adbd";
        Result result = run(action, 15000);
        return (enable ? "Enable legacy ADB/TCP:\n" : "Disable legacy ADB/TCP:\n")
                + result.describe() + "\n" + status()
                + (enable ? "\nImportant: disconnect from untrusted Wi-Fi and turn ADB off when finished." : "");
    }
}
