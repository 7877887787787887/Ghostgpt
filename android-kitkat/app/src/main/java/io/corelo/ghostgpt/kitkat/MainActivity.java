package io.corelo.ghostgpt.kitkat;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.net.Uri;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.util.Collections;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.HttpsURLConnection;

/**
 * GhostGPT Lite for Android 4.4 (API 19).
 * Root commands require an explicit local confirmation; AI replies never execute commands.
 * All HTTPS requests use platform certificate validation. No secret is persisted on KitKat.
 */
public final class MainActivity extends Activity {
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private LinearLayout root;
    private String active = "Chat";
    private String endpoint = "https://msi.tail28f016.ts.net/model";
    private String model = "qwen/qwen3-8b";
    private String token = ""; // In-memory only: Android 4.4 has no Keystore AES-GCM support.
    private final StringBuilder chatHistory = new StringBuilder("GhostGPT KitKat — Android 4.4.4 compatibility build.");
    private final StringBuilder debugHistory = new StringBuilder("Tap Check tablet to inspect configuration.");
    private final StringBuilder rootHistory = new StringBuilder("No privileged command has been executed.");
    private EditText chatInput;

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        render();
    }

    private int px(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView text(String message, int size) {
        TextView view = new TextView(this);
        view.setText(message);
        view.setTextColor(Color.rgb(235, 241, 255));
        view.setTextSize(size);
        view.setPadding(px(8), px(9), px(8), px(9));
        view.setTextIsSelectable(true);
        return view;
    }

    private Button button(String caption, final Runnable work) {
        Button control = new Button(this);
        control.setText(caption);
        control.setTextColor(Color.WHITE);
        control.setTextSize(14);
        control.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View clicked) { work.run(); }
        });
        return control;
    }

    private EditText input(String hint, String initial) {
        EditText control = new EditText(this);
        control.setHint(hint);
        control.setText(initial);
        control.setTextColor(Color.WHITE);
        control.setHintTextColor(Color.LTGRAY);
        control.setSingleLine(false);
        return control;
    }

    private void add(LinearLayout parent, View item) {
        parent.addView(item, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    }

    private void render() {
        root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(18, 24, 40));
        setContentView(root);
        add(root, text("GHOSTGPT  •  KITKAT 4.4", 22));
        LinearLayout navigation = new LinearLayout(this);
        navigation.setOrientation(LinearLayout.HORIZONTAL);
        for (final String name: new String[]{"Chat", "Browser", "Debug", "Root"}) {
            Button tab = button(name, new Runnable() {
                @Override public void run() { active = name; render(); }
            });
            LinearLayout.LayoutParams weight = new LinearLayout.LayoutParams(0, px(56), 1);
            navigation.addView(tab, weight);
        }
        add(root, navigation);
        ScrollView screen = new ScrollView(this);
        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(px(10), px(6), px(10), px(10));
        screen.addView(page);
        root.addView(screen, new LinearLayout.LayoutParams(-1, 0, 1));
        if ("Chat".equals(active)) buildChat(page);
        if ("Browser".equals(active)) buildBrowser(page);
        if ("Debug".equals(active)) buildDebug(page);
        if ("Root".equals(active)) buildRoot(page);
    }

    private void buildChat(final LinearLayout page) {
        add(page, text("Private model chat", 20));
        add(page, text("This older Android version may not trust modern TLS servers. HTTPS and valid certificates are required; no insecure TLS fallback is included.", 13));
        final EditText url = input("HTTPS model gateway", endpoint);
        final EditText id = input("Model ID", model);
        final EditText auth = input("Bearer token — session only, never saved", token);
        auth.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        auth.setSingleLine(true);
        add(page, url);
        add(page, id);
        add(page, auth);
        add(page, button("Apply connection for this session", new Runnable() {
            @Override public void run() {
                String chosen = url.getText().toString().trim();
                if (!validHttps(chosen)) {
                    notice("Use an HTTPS URL without user info, query, or fragment.");
                    return;
                }
                endpoint = chosen;
                model = id.getText().toString().trim();
                token = auth.getText().toString();
                notice("Session settings applied; bearer token is not stored on disk.");
            }
        }));
        add(page, button("Clear bearer token", new Runnable() {
            @Override public void run() {
                token = "";
                auth.setText("");
                notice("In-memory token cleared.");
            }
        }));
        final TextView output = text(chatHistory.toString(), 13);
        add(page, output);
        chatInput = input("Message GhostGPT", "");
        add(page, chatInput);
        add(page, button("Send message", new Runnable() {
            @Override public void run() {
                final String question = chatInput.getText().toString().trim();
                if (question.length() == 0) return;
                if (token.length() == 0) { notice("Enter an authenticated gateway token first."); return; }
                chatInput.setText("");
                chatHistory.append("\n\nYou: ").append(question).append("\nGhostGPT: Checking secure connection…");
                output.setText(chatHistory.toString());
                worker.execute(new Runnable() {
                    @Override public void run() {
                        String response;
                        try { response = chat(question); }
                        catch (Exception error) { response = "Connection unavailable: " + error.getMessage(); }
                        final String reply = response;
                        ui.post(new Runnable() {
                            @Override public void run() {
                                int spot = chatHistory.lastIndexOf("Checking secure connection…");
                                if (spot >= 0) chatHistory.replace(spot, spot + "Checking secure connection…".length(), reply);
                                if (chatHistory.length() > 14000) chatHistory.delete(0, chatHistory.length() - 14000);
                                output.setText(chatHistory.toString());
                            }
                        });
                    }
                });
            }
        }));
    }

    private String chat(String prompt) throws Exception {
        String address = endpoint;
        if (!validHttps(address)) throw new Exception("Invalid HTTPS endpoint.");
        while (address.endsWith("/")) address = address.substring(0, address.length() - 1);
        if (!address.endsWith("/v1/chat/completions")) address += "/v1/chat/completions";
        JSONObject data = new JSONObject();
        data.put("model", model);
        data.put("stream", false);
        data.put("max_tokens", 256);
        JSONArray messages = new JSONArray();
        messages.put(new JSONObject().put("role", "user").put("content", prompt));
        data.put("messages", messages);
        HttpsURLConnection connection = (HttpsURLConnection) new URL(address).openConnection();
        connection.setConnectTimeout(12000);
        connection.setReadTimeout(40000);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Authorization", "Bearer " + token);
        try {
            byte[] payload = data.toString().getBytes("UTF-8");
            connection.setFixedLengthStreamingMode(payload.length);
            OutputStream output = connection.getOutputStream();
            try { output.write(payload); } finally { output.close(); }
            int code = connection.getResponseCode();
            if (code < 200 || code >= 300)
                throw new Exception("Gateway returned HTTP " + code + ". Check token and KitKat TLS support.");
            InputStream stream = connection.getInputStream();
            try {
                byte[] bytes = readUpTo(stream, 1024 * 1024);
                JSONObject result = new JSONObject(new String(bytes, "UTF-8"));
                return result.getJSONArray("choices").getJSONObject(0)
                    .getJSONObject("message").getString("content");
            } finally { stream.close(); }
        } finally { connection.disconnect(); }
    }

    private static byte[] readUpTo(InputStream input, int limit) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] chunk = new byte[4096];
        int len;
        while ((len = input.read(chunk)) >= 0) {
            if (output.size() + len > limit) throw new Exception("Response exceeds size limit.");
            output.write(chunk, 0, len);
        }
        return output.toByteArray();
    }

    private void buildBrowser(LinearLayout page) {
        add(page, text("Open browser", 20));
        add(page, text("Uses an installed Chrome or other browser. Android 4.4.4 and Chrome 81 are obsolete: avoid passwords, banking, and sensitive websites.", 13));
        final EditText address = input("HTTPS address", "https://example.com");
        add(page, address);
        add(page, button("Open HTTPS website", new Runnable() {
            @Override public void run() {
                String destination = address.getText().toString().trim();
                if (!validHttps(destination)) { notice("Only HTTPS links are accepted."); return; }
                try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(destination))); }
                catch (Exception error) { notice("No compatible browser installed."); }
            }
        }));
    }

    private void buildDebug(final LinearLayout page) {
        add(page, text("Developer and wireless debugging", 20));
        add(page, text("Android 4.4 does not have Android 11+ wireless pairing. Only an authorized ADB host can enable legacy TCP debugging. Do not expose ADB port 5555 on public or untrusted networks.", 13));
        final TextView result = text(debugHistory.toString(), 13);
        add(page, result);
        add(page, button("Check tablet status (read-only)", new Runnable() {
            @Override public void run() {
                debugHistory.setLength(0);
                debugHistory.append("Model: ").append(Build.MODEL).append("\n");
                debugHistory.append("Manufacturer: ").append(Build.MANUFACTURER).append("\n");
                debugHistory.append("Android: ").append(Build.VERSION.RELEASE).append(" (API ")
                    .append(Build.VERSION.SDK_INT).append(")\n");
                debugHistory.append("CPU: ").append(Build.CPU_ABI).append("\n");
                debugHistory.append("Build: ").append(Build.DISPLAY).append("\n");
                debugHistory.append("Debuggable: ").append(command("getprop", "ro.debuggable")).append("\n");
                debugHistory.append("ADB TCP port: ").append(command("getprop", "service.adb.tcp.port")).append("\n");
                try {
                    int adb = Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED, -1);
                    debugHistory.append("ADB enabled: ").append(adb).append("\n");
                } catch (Exception error) { debugHistory.append("ADB flag unavailable\n"); }
                debugHistory.append("IP:\n").append(addresses());
                result.setText(debugHistory.toString());
            }
        }));
        add(page, button("Open Android Developer options", new Runnable() {
            @Override public void run() { openSettings(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS); }
        }));
        add(page, button("Open Wi-Fi settings", new Runnable() {
            @Override public void run() { openSettings(Settings.ACTION_WIFI_SETTINGS); }
        }));
        add(page, button("Open system Settings", new Runnable() {
            @Override public void run() { openSettings(Settings.ACTION_SETTINGS); }
        }));
        add(page, button("Open Security / Unknown sources", new Runnable() {
            @Override public void run() { openSettings(Settings.ACTION_SECURITY_SETTINGS); }
        }));
        final String instructions = "After approving USB debugging on the tablet, from a trusted PC:\n"
            + "adb devices -l\n"
            + "adb tcpip 5555\n"
            + "adb connect TABLET_PRIVATE_IP:5555\n"
            + "adb shell getprop ro.build.version.sdk\n"
            + "Close TCP debugging after testing. Only use a trusted isolated network.";
        add(page, text(instructions, 13));
        add(page, button("Copy authorized ADB instructions", new Runnable() {
            @Override public void run() {
                ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (clipboard != null) {
                    clipboard.setPrimaryClip(ClipData.newPlainText("Legacy ADB", instructions));
                    notice("Copied. These commands run on your authorized computer, not on the tablet.");
                }
            }
        }));
    }

    private void buildRoot(final LinearLayout page) {
        add(page, text("Root diagnostics", 20));
        add(page, text("This APK cannot jailbreak/root the tablet. 'su' works only if a root solution is already installed and the tablet grants permission. Every command requires approval.", 13));
        final TextView result = text(rootHistory.toString(), 13);
        add(page, result);
        add(page, button("Check root UID", new Runnable() {
            @Override public void run() { confirmRoot("id -u", result, false); }
        }));
        for (final String diagnostic: new String[]{"id", "getenforce", "df -h", "getprop ro.build.version.release"}) {
            add(page, button("Read-only: " + diagnostic, new Runnable() {
                @Override public void run() { confirmRoot(diagnostic, result, false); }
            }));
        }
        final EditText manual = input("Advanced manual root command (1–250 chars)", "");
        add(page, manual);
        add(page, button("Review manual root command", new Runnable() {
            @Override public void run() {
                String value = manual.getText().toString().trim();
                if (value.length() == 0 || value.length() > 250) { notice("Enter 1–250 characters."); return; }
                confirmRoot(value, result, true);
            }
        }));
        add(page, text("Root commands can erase data or damage old firmware. Never run unreviewed commands. AI responses do not invoke root.", 13));
    }

    private void confirmRoot(final String command, final TextView result, final boolean risky) {
        new AlertDialog.Builder(this)
            .setTitle(risky ? "Run manual root command?" : "Run root diagnostic?")
            .setMessage("The tablet will attempt to execute this command with su, after your confirmation:\n\n"
                    + command + "\n\nThis requires an independently installed root manager.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton(risky ? "Approve elevated command" : "Check", new android.content.DialogInterface.OnClickListener() {
                @Override public void onClick(android.content.DialogInterface dialog, int index) {
                    worker.execute(new Runnable() {
                        @Override public void run() {
                            final String output = commandRoot(command);
                            ui.post(new Runnable() {
                                @Override public void run() {
                                    rootHistory.append("\n$ ").append(command).append("\n").append(output).append("\n");
                                    if (rootHistory.length() > 8000) rootHistory.delete(0, rootHistory.length() - 8000);
                                    result.setText(rootHistory.toString());
                                }
                            });
                        }
                    });
                }
            }).show();
    }

    // Process.waitFor(timeout, TimeUnit) was added only in Android API 26.
    private static boolean waitForOldAndroid(Process process, long timeoutMillis) throws InterruptedException {
        long until = android.os.SystemClock.uptimeMillis() + timeoutMillis;
        while (android.os.SystemClock.uptimeMillis() < until) {
            try {
                process.exitValue();
                return true;
            } catch (IllegalThreadStateException running) {
                Thread.sleep(100);
            }
        }
        try { process.exitValue(); return true; }
        catch (IllegalThreadStateException running) { return false; }
    }

    private static String commandRoot(String value) {
        Process process = null;
        try {
            process = new ProcessBuilder("su", "-c", value).redirectErrorStream(true).start();
            if (!waitForOldAndroid(process, 15000)) {
                process.destroy();
                return "Timed out; root manager may need manual approval.";
            }
            InputStream stdout = process.getInputStream();
            try {
                byte[] data = readUpTo(stdout, 8192);
                return "Exit " + process.exitValue() + ":\n" + new String(data, "UTF-8");
            } finally { stdout.close(); }
        } catch (Exception error) { return "Root access unavailable: " + error.getMessage(); }
        finally { if (process != null) process.destroy(); }
    }

    private static String command(String... value) {
        Process process = null;
        try {
            process = new ProcessBuilder(value).redirectErrorStream(true).start();
            if (!waitForOldAndroid(process, 2000)) { process.destroy(); return "Timed out"; }
            if (process.exitValue() != 0) return "Unavailable";
            InputStream stream = process.getInputStream();
            try { return new String(readUpTo(stream, 256), "UTF-8").trim(); }
            finally { stream.close(); }
        } catch (Exception error) { return "Unavailable"; }
        finally { if (process != null) process.destroy(); }
    }

    private static String addresses() {
        StringBuilder output = new StringBuilder();
        try {
            for (NetworkInterface nic: Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nic.isUp() || nic.isLoopback()) continue;
                for (InetAddress ip: Collections.list(nic.getInetAddresses())) {
                    if (ip instanceof Inet4Address && !ip.isLoopbackAddress())
                        output.append(nic.getName()).append(": ").append(ip.getHostAddress()).append("\n");
                }
            }
        } catch (Exception error) { output.append("Network addresses unavailable"); }
        return output.toString();
    }

    private static boolean validHttps(String raw) {
        Uri uri = Uri.parse(raw);
        return "https".equalsIgnoreCase(uri.getScheme()) &&
            uri.getHost() != null && uri.getUserInfo() == null &&
            uri.getQuery() == null && uri.getFragment() == null;
    }

    private void openSettings(String name) {
        try { startActivity(new Intent(name)); }
        catch (Exception error) { notice("Settings page unavailable on this firmware."); }
    }

    private void notice(String message) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
    }

    @Override protected void onDestroy() {
        worker.shutdownNow();
        token = "";
        super.onDestroy();
    }
}
