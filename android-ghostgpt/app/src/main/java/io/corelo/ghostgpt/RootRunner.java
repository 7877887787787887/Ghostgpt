package io.corelo.ghostgpt;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.concurrent.TimeUnit;

/** Local-only, user-initiated root shell. Never reachable from the AI or remote gateway. */
final class RootRunner {
    private RootRunner() {}

    static final class Result {
        final int code;
        final boolean timedOut;
        final String output;
        Result(int code, boolean timedOut, String output) {
            this.code = code;
            this.timedOut = timedOut;
            this.output = output;
        }
    }

    static Result execute(String command, int seconds) throws Exception {
        if (command == null || command.trim().isEmpty() || command.length() > 500)
            throw new Exception("Command must be between 1 and 500 characters.");
        Process process = new ProcessBuilder("su", "-c", command).redirectErrorStream(true).start();
        ByteArrayOutputStream captured = new ByteArrayOutputStream();
        Thread collector = new Thread(() -> {
            try (InputStream stream = process.getInputStream()) {
                byte[] buffer = new byte[4096];
                int n;
                while ((n = stream.read(buffer)) != -1) {
                    synchronized (captured) {
                        if (captured.size() < 64 * 1024)
                            captured.write(buffer, 0, Math.min(n, 64 * 1024 - captured.size()));
                    }
                }
            } catch (Exception ignored) { }
        }, "ghostgpt-root-output");
        collector.setDaemon(true);
        collector.start();
        boolean finished;
        try {
            finished = process.waitFor(seconds, TimeUnit.SECONDS);
        } catch (InterruptedException error) {
            process.destroyForcibly();
            Thread.currentThread().interrupt();
            throw new Exception("Root check interrupted.");
        }
        if (!finished) process.destroyForcibly();
        collector.join(700);
        String output;
        synchronized (captured) {
            output = captured.toString("UTF-8");
        }
        return new Result(finished ? process.exitValue() : -1, !finished, output);
    }
}
