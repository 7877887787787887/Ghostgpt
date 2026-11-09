package io.corelo.ghostgpt;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Encrypts gateway tokens using an Android Keystore-backed AES/GCM key. */
final class SecretStore {
    private static final String KEY_ALIAS = "ghostgpt.android.gateway.tokens.v1";
    private static final String STORE = "ghostgpt.encrypted.secrets";

    private SecretStore() {}

    private static SecretKey key(boolean create) throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        SecretKey existing = (SecretKey) store.getKey(KEY_ALIAS, null);
        if (existing != null || !create) return existing;
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build());
        return generator.generateKey();
    }

    static void save(Context context, String name, String value) throws Exception {
        SharedPreferences preferences = context.getSharedPreferences(STORE, Context.MODE_PRIVATE);
        if (value == null || value.isEmpty()) {
            preferences.edit().remove(name).apply();
            return;
        }
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key(true), new SecureRandom());
        byte[] iv = cipher.getIV();
        byte[] encrypted = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
        byte[] joined = new byte[iv.length + encrypted.length];
        System.arraycopy(iv, 0, joined, 0, iv.length);
        System.arraycopy(encrypted, 0, joined, iv.length, encrypted.length);
        preferences.edit().putString(name, Base64.encodeToString(joined, Base64.NO_WRAP)).apply();
    }

    static String load(Context context, String name) {
        String saved = context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString(name, "");
        if (saved == null || saved.isEmpty()) return "";
        try {
            byte[] raw = Base64.decode(saved, Base64.NO_WRAP);
            if (raw.length < 29) return "";
            SecretKey aes = key(false);
            if (aes == null) return "";
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, aes, new GCMParameterSpec(128, Arrays.copyOfRange(raw, 0, 12)));
            return new String(cipher.doFinal(raw, 12, raw.length - 12), StandardCharsets.UTF_8);
        } catch (Exception failure) {
            // Never return untrusted ciphertext or fall back to plaintext storage.
            return "";
        }
    }
}
