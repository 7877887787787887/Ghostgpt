package io.corelo.ghostgpt;

import android.net.Uri;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;

import javax.net.ssl.HttpsURLConnection;

/** Requests go only to the exact HTTPS endpoint selected in Settings. */
final class RemoteClient {
    private RemoteClient() {}

    static String chat(String endpoint, String token, String model, List<JSONObject> history) throws Exception {
        if (model == null || model.trim().isEmpty()) throw new Exception("Configure a model ID in Settings.");
        String url = normalize(endpoint, "/v1/chat/completions");
        JSONObject request = new JSONObject();
        request.put("model", model.trim());
        request.put("messages", new JSONArray(history));
        request.put("stream", false);
        request.put("max_tokens", 512);
        JSONObject reply = send(url, token, request);
        JSONArray choices = reply.optJSONArray("choices");
        if (choices == null || choices.length() == 0) throw new Exception("The model gateway returned no choices.");
        JSONObject message = choices.getJSONObject(0).optJSONObject("message");
        if (message == null) throw new Exception("The model gateway returned no message.");
        String answer = message.optString("content", "");
        if (answer.trim().isEmpty()) throw new Exception("The model returned an empty response.");
        return answer;
    }

    static JSONObject sshReadOnly(String endpoint, String token, String host, String username, String command) throws Exception {
        String url = normalize(endpoint, "");
        if (host == null || !host.matches("[A-Za-z0-9._-]{1,253}"))
            throw new Exception("SSH must use a trusted host alias.");
        if (username == null || !username.matches("[A-Za-z0-9._-]{0,64}"))
            throw new Exception("Invalid SSH account.");
        // The Windows gateway independently enforces an exact host allow-list and read-only commands.
        JSONObject request = new JSONObject();
        request.put("mode", "ssh");
        request.put("host", host);
        request.put("username", username);
        request.put("command", command);
        request.put("approved", true);
        request.put("riskConfirmed", false);
        return send(url, token, request);
    }

    private static String normalize(String endpoint, String suffix) throws Exception {
        String text = endpoint == null ? "" : endpoint.trim();
        Uri uri = Uri.parse(text);
        if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null)
            throw new Exception("Configure an HTTPS gateway URL without embedded credentials or query parameters.");
        while (text.endsWith("/")) text = text.substring(0, text.length() - 1);
        if (!suffix.isEmpty() && !text.endsWith(suffix)) text += suffix;
        return text;
    }

    private static JSONObject send(String endpoint, String token, JSONObject payload) throws Exception {
        if (token == null || token.isEmpty()) throw new Exception("A gateway bearer token is required in Settings.");
        HttpsURLConnection conn = (HttpsURLConnection) new URL(endpoint).openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(12000);
        conn.setReadTimeout(75000);
        conn.setInstanceFollowRedirects(false);
        conn.setDoOutput(true);
        conn.setRequestProperty("Authorization", "Bearer " + token);
        conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        conn.setRequestProperty("Accept", "application/json");
        try {
            byte[] encoded = payload.toString().getBytes(StandardCharsets.UTF_8);
            conn.setFixedLengthStreamingMode(encoded.length);
            try (OutputStream out = conn.getOutputStream()) { out.write(encoded); }
            int code = conn.getResponseCode();
            if (code >= 300 && code < 400) throw new Exception("Gateway redirect refused (HTTP " + code + ").");
            InputStream stream = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            String response = boundedRead(stream);
            if (code < 200 || code >= 300)
                throw new Exception("Gateway rejected request (HTTP " + code + "): " + response.substring(0, Math.min(response.length(), 320)));
            return new JSONObject(response);
        } finally {
            conn.disconnect();
        }
    }

    private static String boundedRead(InputStream in) throws Exception {
        if (in == null) return "";
        try (InputStream stream = in; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] chunk = new byte[8192];
            int total = 0;
            int n;
            while ((n = stream.read(chunk)) >= 0) {
                total += n;
                if (total > 1024 * 1024) throw new Exception("Gateway response exceeds 1 MiB.");
                out.write(chunk, 0, n);
            }
            return out.toString("UTF-8");
        }
    }
}
