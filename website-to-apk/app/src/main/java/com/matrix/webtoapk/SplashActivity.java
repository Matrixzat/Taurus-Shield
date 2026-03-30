package com.matrix.webtoapk;

import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.AssetManager;
import android.os.Bundle;
import android.os.Handler;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import androidx.appcompat.app.AppCompatActivity;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;

public class SplashActivity extends AppCompatActivity {
    private static final String PREFS_NAME = "AppPrefs";
    private static final String THEME_INDEX_KEY = "themeIndex";
    private String customLottieJson = null;

    @Override
    protected void onCreate(Bundle bundle) {
        super.onCreate(bundle);
        setContentView(R.layout.activity_splash);
        
        customLottieJson = loadCustomLottieFromAssets();
        
        WebView webView = findViewById(R.id.splashWebView);
        webView.getSettings().setJavaScriptEnabled(true);
        webView.getSettings().setAllowFileAccess(true);

        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        int themeIndex = prefs.getInt(THEME_INDEX_KEY, 0);

        webView.addJavascriptInterface(new WebAppInterface(themeIndex, customLottieJson), "Android");

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                if (customLottieJson != null) {
                    view.evaluateJavascript("loadLottieFromAndroid();", null);
                } else {
                    String appName = getString(R.string.app_name)
                        .replace("\\", "\\\\")
                        .replace("'", "\\'");
                    view.evaluateJavascript(
                        "document.getElementById('app-name').innerText = '" + appName + "';", null);
                }
            }
        });

        if (customLottieJson != null) {
            webView.loadUrl("file:///android_asset/splash_screen_custom.html");
        } else {
            webView.loadUrl("file:///android_asset/splash_screen.html");
        }

        SharedPreferences.Editor editor = prefs.edit();
        editor.putInt(THEME_INDEX_KEY, (themeIndex + 1) % 7);
        editor.apply();

        new Handler().postDelayed(() -> {
            startActivity(new Intent(SplashActivity.this, MainActivity.class));
            finish();
        }, 10000);
    }
    
    private String loadCustomLottieFromAssets() {
        AssetManager assetManager = getAssets();
        try {
            InputStream inputStream = assetManager.open("custom_splash.json");
            BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line);
            }
            reader.close();
            inputStream.close();
            return sb.toString();
        } catch (IOException e) {
            return null;
        }
    }

    public class WebAppInterface {
        private final int themeIndex;
        private final String lottieJson;

        public WebAppInterface(int themeIndex, String lottieJson) {
            this.themeIndex = themeIndex;
            this.lottieJson = lottieJson;
        }

        @JavascriptInterface
        public int getThemeIndex() {
            return themeIndex;
        }
        
        @JavascriptInterface
        public String getCustomLottieJson() {
            return lottieJson;
        }
        
        @JavascriptInterface
        public boolean hasCustomLottie() {
            return lottieJson != null;
        }
    }
}
