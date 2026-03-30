package com.matrix.webtoapk;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.biometric.BiometricManager;
import androidx.biometric.BiometricPrompt;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.FragmentActivity;

import java.util.concurrent.Executor;

public class BiometricAuthManager {
    private static final String TAG = "BiometricAuthManager";
    private static final String PREFS_NAME = "biometric_prefs";
    private static final String KEY_LAST_AUTH_TIME = "last_auth_time";
    
    public static final String TYPE_FINGERPRINT = "fingerprint";

    private final FragmentActivity activity;
    private final SharedPreferences prefs;
    private BiometricPrompt biometricPrompt;
    private BiometricPrompt.PromptInfo promptInfo;
    private final long authTimeoutMs;
    private final String biometricType;

    public interface AuthCallback {
        void onAuthSuccess();
        void onAuthError(String error);
        void onAuthCancelled();
    }

    public BiometricAuthManager(FragmentActivity activity, long timeoutMs, String biometricType) {
        this.activity = activity;
        this.prefs = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        this.authTimeoutMs = timeoutMs;
        this.biometricType = TYPE_FINGERPRINT;
    }
    
    public BiometricAuthManager(FragmentActivity activity, long timeoutMs) {
        this(activity, timeoutMs, TYPE_FINGERPRINT);
    }

    public boolean isBiometricAvailable() {
        BiometricManager biometricManager = BiometricManager.from(activity);
        int canAuthenticate = biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_WEAK | 
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        );
        return canAuthenticate == BiometricManager.BIOMETRIC_SUCCESS;
    }

    public boolean needsReauthentication() {
        long lastAuthTime = prefs.getLong(KEY_LAST_AUTH_TIME, 0);
        if (lastAuthTime == 0) return true;
        if (authTimeoutMs <= 0) return false;
        long currentTime = System.currentTimeMillis();
        return (currentTime - lastAuthTime) > authTimeoutMs;
    }

    public void recordAuthSuccess() {
        prefs.edit().putLong(KEY_LAST_AUTH_TIME, System.currentTimeMillis()).apply();
    }

    public void authenticate(final AuthCallback callback) {
        Executor executor = ContextCompat.getMainExecutor(activity);

        biometricPrompt = new BiometricPrompt(activity, executor,
            new BiometricPrompt.AuthenticationCallback() {
                @Override
                public void onAuthenticationError(int errorCode, @NonNull CharSequence errString) {
                    super.onAuthenticationError(errorCode, errString);
                    Log.e(TAG, "Authentication error: " + errString);
                    if (errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                        errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                        errorCode == BiometricPrompt.ERROR_CANCELED) {
                        callback.onAuthCancelled();
                    } else {
                        callback.onAuthError(errString.toString());
                    }
                }

                @Override
                public void onAuthenticationSucceeded(@NonNull BiometricPrompt.AuthenticationResult result) {
                    super.onAuthenticationSucceeded(result);
                    Log.i(TAG, "Authentication succeeded");
                    recordAuthSuccess();
                    callback.onAuthSuccess();
                }

                @Override
                public void onAuthenticationFailed() {
                    super.onAuthenticationFailed();
                    Log.w(TAG, "Authentication failed - wrong fingerprint/face");
                }
            });

        String title = "Fingerprint Required";
        String subtitle = "Use your fingerprint to unlock";

        promptInfo = new BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK |
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build();

        try {
            biometricPrompt.authenticate(promptInfo);
        } catch (Exception e) {
            Log.e(TAG, "Failed to show biometric prompt", e);
            callback.onAuthError("Failed to show authentication dialog");
        }
    }
}
