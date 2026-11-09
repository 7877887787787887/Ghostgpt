package io.corelo.ghostgpt;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Native Android GhostGPT: model chat, hardened browser, approved root and SSH tooling. */
public final class MainActivity extends Activity {
    private static final int BG = Color.rgb(12, 16, 26);
    private static final int PANEL = Color.rgb(24, 32, 49);
    private static final int WHITE = Color.rgb(240, 245, 255);
    private static final int MUTED = Color.rgb(158, 174, 198);
    private static final int ACCENT = Color.rgb(71, 139, 247);
    private static final int BORDER = Color.rgb(52, 67, 91);
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    private final List<JSONObject> chatHistory = new ArrayList<>();
    private final StringBuilder chatLog = new StringBuilder("Connect your model in Settings, then send a message.");
    private final StringBuilder rootLog = new StringBuilder("Root has not been checked. No command has been executed.");
    private final StringBuilder sshLog = new StringBuilder("SSH has not been checked. Commands require an authenticated PC gateway.");
    private android.content.SharedPreferences preferences;
    private LinearLayout layout;
    private FrameLayout body;
    private WebView browser;
    private String activeTab = "Chat";
    private boolean rootCustomEnabled = false;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        preferences = getSharedPreferences("ghostgpt.android.preferences", Context.MODE_PRIVATE);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        renderShell();
    }

    private int dp(float value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    private GradientDrawable background(int color, int stroke) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(dp(13));
        if (stroke != 0) drawable.setStroke(dp(1), stroke);
        return drawable;
    }

    private LinearLayout column(int padding) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(padding), dp(padding), dp(padding), dp(padding));
        return box;
    }

    private LinearLayout row() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.HORIZONTAL);
        box.setGravity(Gravity.CENTER_VERTICAL);
        return box;
    }

    private TextView label(String value, int size, int color, boolean bold) {
        TextView text = new TextView(this);
        text.setText(value);
        text.setTextSize(size);
        text.setTextColor(color);
        text.setLineSpacing(dp(3), 1f);
        if (bold) text.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return text;
    }

    private EditText field(String hint, String initial) {
        EditText input = new EditText(this);
        input.setSingleLine(false);
        input.setTextSize(14);
        input.setTextColor(WHITE);
        input.setHintTextColor(MUTED);
        input.setHint(hint);
        input.setText(initial);
        input.setPadding(dp(12), dp(8), dp(12), dp(8));
        input.setBackground(background(PANEL, BORDER));
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        return input;
    }

    private Button action(String text, boolean primary, Runnable run) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextColor(WHITE);
        button.setTextSize(13);
        button.setAllCaps(false);
        button.setBackground(background(primary ? ACCENT : PANEL, primary ? 0 : BORDER));
        button.setPadding(dp(8), dp(7), dp(8), dp(7));
        button.setOnClickListener(v -> run.run());
        return button;
    }

    private LinearLayout.LayoutParams full(int top) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(top);
        return params;
    }

    private void add(LinearLayout parent, View child, int marginTop) {
        parent.addView(child, full(marginTop));
    }

    private ScrollView scroll(LinearLayout contents) {
        ScrollView view = new ScrollView(this);
        view.setFillViewport(true);
        view.addView(contents);
        return view;
    }

    private void renderShell() {
        layout = column(0);
        layout.setBackgroundColor(BG);
        layout.setFitsSystemWindows(true);
        setContentView(layout);
        LinearLayout heading = column(14);
        add(heading, label("GHOSTGPT   /   ANDROID", 20, WHITE, true), 0);
        add(heading, label("Model chat · Secure browser · Root tools", 11, MUTED, false), 3);
        layout.addView(heading);
        View line = new View(this);
        line.setBackgroundColor(BORDER);
        layout.addView(line, new LinearLayout.LayoutParams(-1, dp(1)));
        body = new FrameLayout(this);
        layout.addView(body, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout tabs = row();
        tabs.setPadding(dp(4), dp(6), dp(4), dp(8));
        for (String item : new String[]{"Chat", "Browser", "Root", "SSH", "Settings"}) {
            Button button = action(item, item.equals(activeTab), () -> show(item));
            button.setTextSize(11);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, dp(47), 1);
            params.setMargins(dp(2), 0, dp(2), 0);
            tabs.addView(button, params);
        }
        layout.addView(tabs);
        show(activeTab);
    }

    private void show(String item) {
        if (!item.equals(activeTab)) {
            activeTab = item;
            renderShell();
            return;
        }
        body.removeAllViews();
        switch (item) {
            case "Chat": showChat(); break;
            case "Browser": showBrowser(); break;
            case "Root": showRoot(); break;
            case "SSH": showSSH(); break;
            default: showSettings(); break;
        }
    }

    private String pref(String key, String fallback) { return preferences.getString(key, fallback); }

    private void showChat() {
        LinearLayout contents = column(14);
        add(contents, label("GhostGPT chat", 19, WHITE, true), 0);
        add(contents, label("Authenticated LM Studio / OpenAI-compatible HTTPS endpoint. AI replies cannot run local root commands.", 12, MUTED, false), 5);
        TextView transcript = label(chatLog.toString(), 14, WHITE, false);
        transcript.setTextIsSelectable(true);
        transcript.setPadding(dp(12), dp(12), dp(12), dp(12));
        transcript.setBackground(background(PANEL, BORDER));
        ScrollView messages = scroll(column(0));
        ((LinearLayout) messages.getChildAt(0)).addView(transcript);
        contents.addView(messages, new LinearLayout.LayoutParams(-1, 0, 1));
        EditText input = field("Ask GhostGPT anything...", "");
        add(contents, input, 12);
        final Button[] sendButton = new Button[1];
        sendButton[0] = action("Send to AI model", true, () -> {
            String prompt = input.getText().toString().trim();
            if (prompt.isEmpty()) return;
            String token = SecretStore.load(this, "modelToken");
            String endpoint = pref("modelEndpoint", "https://msi.tail28f016.ts.net/model");
            String model = pref("modelId", "qwen/qwen3-8b");
            input.setText("");
            chatLog.append("\n\nYOU  ·  ").append(prompt).append("\n\nGHOSTGPT  ·  Processing…");
            transcript.setText(chatLog.toString());
            messages.post(() -> messages.fullScroll(View.FOCUS_DOWN));
            sendButton[0].setEnabled(false);
            List<JSONObject> request = new ArrayList<>(chatHistory);
            try {
                JSONObject user = new JSONObject();
                user.put("role", "user");
                user.put("content", prompt);
                request.add(user);
            } catch (Exception ignored) { }
            workers.execute(() -> {
                String reply;
                boolean success;
                try {
                    reply = RemoteClient.chat(endpoint, token, model, request);
                    success = true;
                } catch (Exception failure) {
                    reply = "Connection failed: " + failure.getMessage();
                    success = false;
                }
                final String answer = reply;
                final boolean accepted = success;
                ui.post(() -> {
                    int position = chatLog.lastIndexOf("GHOSTGPT  ·  Processing…");
                    if (position >= 0)
                        chatLog.replace(position, position + "GHOSTGPT  ·  Processing…".length(),
                                "GHOSTGPT  ·  " + answer);
                    if (accepted) {
                        chatHistory.clear();
                        chatHistory.addAll(request);
                        try {
                            JSONObject assistant = new JSONObject();
                            assistant.put("role", "assistant");
                            assistant.put("content", answer);
                            chatHistory.add(assistant);
                            if (chatHistory.size() > 24) chatHistory.subList(0, 2).clear();
                        } catch (Exception ignored) { }
                    }
                    transcript.setText(chatLog.toString());
                    messages.post(() -> messages.fullScroll(View.FOCUS_DOWN));
                    sendButton[0].setEnabled(true);
                });
            });
        });
        add(contents, sendButton[0], 8);
        body.addView(contents);
    }

    private void showBrowser() {
        LinearLayout contents = column(10);
        LinearLayout controls = row();
        EditText address = field("HTTPS website", pref("browserUrl", "https://chrome-browser.pages.dev"));
        address.setSingleLine(true);
        controls.addView(address, new LinearLayout.LayoutParams(0, dp(45), 1));
        Button open = action("Go", true, () -> {
            String value = address.getText().toString().trim();
            if (!value.startsWith("https://") && !value.startsWith("http://")) {
                Toast.makeText(this, "Use a full HTTPS address", Toast.LENGTH_SHORT).show();
                return;
            }
            preferences.edit().putString("browserUrl", value).apply();
            if (browser != null) browser.loadUrl(value);
        });
        LinearLayout.LayoutParams buttonLayout = new LinearLayout.LayoutParams(dp(67), dp(45));
        buttonLayout.leftMargin = dp(6);
        controls.addView(open, buttonLayout);
        add(contents, controls, 0);
        browser = new WebView(this);
        WebSettings settings = browser.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSafeBrowsingEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(browser, false);
        browser.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String scheme = request.getUrl().getScheme();
                return scheme == null || (!scheme.equalsIgnoreCase("https") && !scheme.equalsIgnoreCase("http"));
            }
        });
        contents.addView(browser, new LinearLayout.LayoutParams(-1, 0, 1));
        if (pref("browserUrl", "https://chrome-browser.pages.dev").startsWith("https://"))
            browser.loadUrl(pref("browserUrl", "https://chrome-browser.pages.dev"));
        body.addView(contents);
    }

    private void showRoot() {
        LinearLayout contents = column(15);
        add(contents, label("Android root tools", 19, WHITE, true), 0);
        add(contents, label("For devices already rooted with a trusted solution. This app cannot root a stock Android device or bypass its security.", 12, MUTED, false), 5);
        add(contents, label("Root sessions require your device's root manager to approve su. Commands execute only locally, after confirmation; the AI model cannot invoke them.", 12, MUTED, false), 6);
        TextView output = label(rootLog.toString(), 13, WHITE, false);
        output.setTextIsSelectable(true);
        output.setPadding(dp(12), dp(12), dp(12), dp(12));
        output.setBackground(background(PANEL, BORDER));
        add(contents, output, 14);
        Button verify = action("Check root access (id -u)", true,
                () -> confirmRoot("Check whether this app can obtain UID 0 using su?", "id -u", output));
        add(contents, verify, 12);
        add(contents, label("Read-only root diagnostics", 15, WHITE, true), 18);
        for (String[] item : new String[][]{
                {"Device model", "getprop ro.product.model"},
                {"Android version", "getprop ro.build.version.release"},
                {"SELinux enforcement", "getenforce"},
                {"Disk usage", "df -h"},
                {"Running identity", "id"}
        }) {
            add(contents, action(item[0], false,
                    () -> confirmRoot("Run read-only root diagnostic?", item[1], output)), 7);
        }
        add(contents, label("Advanced: manually reviewed root command", 15, WHITE, true), 18);
        CheckBox confirm = new CheckBox(this);
        confirm.setText("Enable manual root commands for this app session");
        confirm.setTextColor(WHITE);
        confirm.setChecked(rootCustomEnabled);
        add(contents, confirm, 7);
        EditText custom = field("Type a root command (maximum 500 characters)", "");
        add(contents, custom, 6);
        Button run = action("Review and run as root", false, () -> {
            if (!confirm.isChecked()) {
                Toast.makeText(this, "Enable manual root mode first.", Toast.LENGTH_SHORT).show();
                return;
            }
            String command = custom.getText().toString().trim();
            if (command.isEmpty() || command.length() > 500) {
                Toast.makeText(this, "Enter a command of 1–500 characters.", Toast.LENGTH_SHORT).show();
                return;
            }
            new AlertDialog.Builder(this)
                    .setTitle("Execute as Android root?")
                    .setMessage("This command can permanently change or damage your device.\n\n" + command +
                            "\n\nIt is executed locally with su. GhostGPT AI cannot run it automatically.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Execute as root", (dialog, which) -> executeRoot(command, output))
                    .show();
        });
        add(contents, run, 8);
        confirm.setOnCheckedChangeListener((view, enabled) -> {
            rootCustomEnabled = enabled;
            run.setEnabled(enabled);
        });
        run.setEnabled(rootCustomEnabled);
        add(contents, label("No automatic root escalation, hidden commands, or background remote shell.", 11, MUTED, false), 14);
        body.addView(scroll(contents));
    }

    private void confirmRoot(String prompt, String command, TextView output) {
        new AlertDialog.Builder(this)
                .setTitle("Approve local root diagnostic?")
                .setMessage(prompt + "\n\nCommand: " + command)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Run", (dialog, which) -> executeRoot(command, output))
                .show();
    }

    private void executeRoot(String command, TextView output) {
        rootLog.append("\n\n$ su -c ").append(command).append("\nRunning…");
        output.setText(rootLog.toString());
        workers.execute(() -> {
            String result;
            try {
                RootRunner.Result call = RootRunner.execute(command, 25);
                if (call.timedOut) result = "Timed out after 25 seconds (root permission might require approval).";
                else result = "Exit code " + call.code + "\n" + call.output;
                if (command.equals("id -u") && call.code == 0 && call.output.trim().equals("0")) {
                    result += "\nRoot shell is available (UID 0); this does not root GhostGPT automatically.";
                }
            } catch (Exception error) {
                result = "Root tool unavailable or rejected: " + error.getMessage();
            }
            String message = result;
            ui.post(() -> {
                int idx = rootLog.lastIndexOf("Running…");
                if (idx >= 0) rootLog.replace(idx, idx + "Running…".length(), message);
                if (rootLog.length() > 16000) rootLog.delete(0, rootLog.length() - 16000);
                output.setText(rootLog.toString());
            });
        });
    }

    private void showSSH() {
        LinearLayout contents = column(15);
        add(contents, label("Private SSH gateway", 19, WHITE, true), 0);
        add(contents, label("Run one manually approved read-only command on an exact SSH alias allowed by your Windows GhostGPT gateway.", 12, MUTED, false), 5);
        EditText alias = field("Trusted host alias", pref("sshHost", "ghost"));
        add(contents, alias, 12);
        EditText user = field("SSH account", pref("sshUser", "pi"));
        add(contents, user, 8);
        EditText command = field("Read-only command, e.g. uname -a", "uname -a");
        add(contents, command, 8);
        TextView output = label(sshLog.toString(), 12, WHITE, false);
        output.setTextIsSelectable(true);
        output.setBackground(background(PANEL, BORDER));
        output.setPadding(dp(12), dp(12), dp(12), dp(12));
        add(contents, output, 12);
        add(contents, action("Review SSH command", true, () -> {
            String h = alias.getText().toString().trim(), u = user.getText().toString().trim(),
                    cmd = command.getText().toString().trim();
            if (cmd.isEmpty()) return;
            new AlertDialog.Builder(this)
                    .setTitle("Send approved SSH command?")
                    .setMessage("Host: " + h + "\nAccount: " + u + "\n\n" + cmd +
                            "\n\nYour PC gateway enforces its SSH host and command allow-lists.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Run", (dialog, which) -> {
                        preferences.edit().putString("sshHost", h).putString("sshUser", u).apply();
                        sshLog.append("\n\n").append(h).append(" $ ").append(cmd).append("\nRunning…");
                        output.setText(sshLog.toString());
                        workers.execute(() -> {
                            String reply;
                            try {
                                JSONObject response = RemoteClient.sshReadOnly(
                                        pref("sshEndpoint", "https://msi.tail28f016.ts.net:10000/terminal"),
                                        SecretStore.load(this, "sshToken"), h, u, cmd);
                                reply = "Exit: " + response.optInt("exit_code", -1) +
                                        "\n" + response.optString("stdout", "") +
                                        "\n" + response.optString("stderr", "");
                            } catch (Exception error) {
                                reply = "SSH failed: " + error.getMessage();
                            }
                            String finalReply = reply;
                            ui.post(() -> {
                                int idx = sshLog.lastIndexOf("Running…");
                                if (idx >= 0) sshLog.replace(idx, idx + "Running…".length(), finalReply);
                                if (sshLog.length() > 16000) sshLog.delete(0, sshLog.length() - 16000);
                                output.setText(sshLog.toString());
                            });
                        });
                    }).show();
        }), 10);
        add(contents, label("The SSH terminal is separate from Android root. It cannot grant the Android app root privileges.", 11, MUTED, false), 12);
        body.addView(scroll(contents));
    }

    private void showSettings() {
        LinearLayout contents = column(15);
        add(contents, label("Connections & security", 19, WHITE, true), 0);
        add(contents, label("Model chat", 16, WHITE, true), 12);
        EditText modelURL = field("Model HTTPS base URL",
                pref("modelEndpoint", "https://msi.tail28f016.ts.net/model"));
        add(contents, modelURL, 8);
        EditText model = field("Model ID", pref("modelId", "qwen/qwen3-8b"));
        add(contents, model, 8);
        EditText modelToken = passwordField("New model bearer token (leave empty to keep)");
        add(contents, modelToken, 8);
        add(contents, label("Remote SSH gateway", 16, WHITE, true), 18);
        EditText sshURL = field("SSH HTTPS /terminal URL",
                pref("sshEndpoint", "https://msi.tail28f016.ts.net:10000/terminal"));
        add(contents, sshURL, 8);
        EditText sshToken = passwordField("New SSH bearer token (leave empty to keep)");
        add(contents, sshToken, 8);
        add(contents, action("Save connection settings", true, () -> {
            String modelEndpoint = modelURL.getText().toString().trim();
            String sshEndpoint = sshURL.getText().toString().trim();
            if (!validHttps(modelEndpoint) || !validHttps(sshEndpoint)) {
                Toast.makeText(this, "Both gateway URLs must use HTTPS without credentials or query parameters.", Toast.LENGTH_LONG).show();
                return;
            }
            try {
                if (modelToken.length() > 0)
                    SecretStore.save(this, "modelToken", modelToken.getText().toString().trim());
                if (sshToken.length() > 0)
                    SecretStore.save(this, "sshToken", sshToken.getText().toString().trim());
                preferences.edit().putString("modelEndpoint", modelEndpoint)
                        .putString("modelId", model.getText().toString().trim())
                        .putString("sshEndpoint", sshEndpoint).apply();
                modelToken.setText("");
                sshToken.setText("");
                Toast.makeText(this, "Settings saved; tokens encrypted in Android Keystore.", Toast.LENGTH_LONG).show();
            } catch (Exception error) {
                Toast.makeText(this, "Could not encrypt tokens: " + error.getClass().getSimpleName(), Toast.LENGTH_LONG).show();
            }
        }), 14);
        add(contents, action("Delete both saved tokens", false, () ->
                new AlertDialog.Builder(this)
                        .setTitle("Delete gateway tokens?")
                        .setMessage("This clears the Android app's saved model and SSH bearer tokens.")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Delete", (dialog, which) -> {
                            try {
                                SecretStore.save(this, "modelToken", "");
                                SecretStore.save(this, "sshToken", "");
                                Toast.makeText(this, "Tokens deleted", Toast.LENGTH_SHORT).show();
                            } catch (Exception ignored) { }
                        }).show()), 8);
        add(contents, label("Root commands run only locally after approval. The AI never receives root access. Gateway tokens are never stored in plaintext preferences or sent to the browser.", 11, MUTED, false), 14);
        add(contents, label("Android 8.0+ · Root tools require a separately rooted device · Debug builds are for testing.", 11, MUTED, false), 8);
        body.addView(scroll(contents));
    }

    private EditText passwordField(String hint) {
        EditText input = field(hint, "");
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        return input;
    }

    private static boolean validHttps(String value) {
        try {
            android.net.Uri url = android.net.Uri.parse(value);
            return "https".equalsIgnoreCase(url.getScheme()) && url.getHost() != null &&
                    url.getUserInfo() == null && url.getQuery() == null && url.getFragment() == null;
        } catch (Exception ignored) { return false; }
    }

    @Override public void onBackPressed() {
        if ("Browser".equals(activeTab) && browser != null && browser.canGoBack()) browser.goBack();
        else if (!"Chat".equals(activeTab)) { activeTab = "Chat"; renderShell(); }
        else super.onBackPressed();
    }

    @Override protected void onDestroy() {
        if (browser != null) { browser.stopLoading(); browser.destroy(); browser = null; }
        workers.shutdownNow();
        super.onDestroy();
    }
}
