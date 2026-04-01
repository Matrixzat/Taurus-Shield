package com.matrix.webtoapk;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.JavascriptInterface;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.SslErrorHandler;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.Toast;
import android.media.MediaScannerConnection; 
import android.app.DownloadManager; 
import android.database.Cursor; 
import android.webkit.URLUtil; 
import static android.content.Context.DOWNLOAD_SERVICE; 
import android.app.NotificationChannel; 
import android.app.NotificationManager; 
import java.io.File;
import java.io.FileOutputStream; 
import java.io.IOException;
import java.io.BufferedReader;
  import java.io.InputStream;
  import java.io.InputStreamReader; 


import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.appcompat.app.AppCompatDelegate;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.localbroadcastmanager.content.LocalBroadcastManager;


import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;
import org.json.JSONException;
import org.json.JSONObject;
import org.unifiedpush.android.connector.UnifiedPush;

import kotlin.Unit;
import kotlin.jvm.functions.Function1;
import android.view.WindowManager;
import android.webkit.WebStorage;
import android.app.PictureInPictureParams;

public class MainActivity extends AppCompatActivity {
    // Corrected permission codes to differentiate between storage and media requests
    private static final int STORAGE_PERMISSION_REQUEST_CODE = 1001; // Used for WRITE_EXTERNAL_STORAGE (API < 29)
    private static final int MEDIA_PERMISSION_REQUEST_CODE = 1003; // Placeholder

    private static final int NOTIFICATION_PERMISSION_REQUEST_CODE = 2; // For POST_NOTIFICATIONS
    private static final int LOCATION_PERMISSION_REQUEST_CODE = 1002;
    private static final String NOTIFICATION_CHANNEL_ID = "web_app_notifications";
    private static final String NOTIFICATION_CHANNEL_NAME = "Web App Notifications";
    private static final String OAUTH_REDIRECT_SCHEME = "com.matrix.webtoapk";
    private static final String OAUTH_REDIRECT_HOST = "oauth2redirect";

    private WebView webview;
    private UserScriptManager userScriptManager;    
    private View mainLayout;
    private View errorLayout;
    private ViewGroup parentLayout;
    private boolean errorOccurred = false;
    private ValueCallback<Uri[]> mFilePathCallback;
    private ActivityResultLauncher<Intent> fileChooserLauncher;
    private WebAppInterface webAppInterface;
    private long lastBackPressedTime = 0;
    private BroadcastReceiver unifiedPushEndpointReceiver;
    private BroadcastReceiver mediaActionReceiver;
    
    // Download pending variables
    private String pendingDownloadUrl;
    private String pendingDownloadUserAgent;
    private String pendingDownloadContentDisposition;
    private String pendingDownloadMimetype;
    private long pendingDownloadContentLength;
    private String pendingDownloadFilename; 

    private boolean isInitialLoad = true;
    private boolean pageLoaded = false; // Tracks if onPageFinished has run

    String mainURL = "https://matrix-api-documentation.vercel.app";
    boolean requireDoubleBackToExit = true;
    boolean allowSubdomains = true;

    boolean enableExternalLinks = true;
    boolean openExternalLinksInBrowser = false;
    boolean confirmOpenInBrowser = true;
    boolean allowSwipeToNavigate = true;
    boolean allowOpenMobileApp = true;
    boolean confirmOpenExternalApp = false;

    String cookies = "ENABLED";
    String basicAuth = "";
    String userAgent = "";
    String CacheMode = "LOAD_DEFAULT";
    boolean enablePullToRefresh = true;
    boolean blockLocalhostRequests = false;
    boolean JSEnabled = true;
    boolean JSCanOpenWindowsAutomatically = true;
    boolean DomStorageEnabled = true;
    boolean DatabaseEnabled = true;
    boolean MediaPlaybackRequiresUserGesture = true;
    boolean SavePassword = true;
    boolean AllowFileAccess = true;
    boolean AllowFileAccessFromFileURLs = true;
    boolean AllowUniversalAccessFromFileURLs = true;
    boolean showDetailsOnErrorScreen = false;
    boolean forceLandscapeMode = false;
    boolean edgeToEdge = false;
    boolean forceDarkTheme = false;
    boolean DebugWebView = false;
    boolean geolocationEnabled = true;
    boolean AppCacheEnabled = true;
    boolean AllowGeolocationPermissionAlways = true;
    boolean biometricLockEnabled = false;
    int biometricTimeoutMinutes = 5;
    String biometricType = "both";
    boolean signApk = true;

    // --- New feature flags (patched by make.sh apply_config) ---
    boolean screenshotPrevention = false;
    boolean zoomEnabled = false;
    boolean deepLinkEnabled = false;
    String deepLinkScheme = "";
    boolean incognitoOnExit = false;
    boolean pipEnabled = false;
    // -----------------------------------------------------------

    private BiometricAuthManager biometricAuthManager;
    private View biometricOverlay;
    private View unlockButton;
    private View lockPulseRing;
    private boolean isAuthenticated = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        loadConfig();
        if (screenshotPrevention) {
            getWindow().setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE);
        }
        if (forceDarkTheme) {
            AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_YES);
        }
        if (edgeToEdge) {
            WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        }

        super.onCreate(savedInstanceState);

        if (edgeToEdge) {
            getWindow().setStatusBarColor(Color.TRANSPARENT);
            getWindow().setNavigationBarColor(Color.TRANSPARENT);
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            int importance = NotificationManager.IMPORTANCE_DEFAULT;
            NotificationChannel channel = new NotificationChannel(NOTIFICATION_CHANNEL_ID, NOTIFICATION_CHANNEL_NAME, importance);
            channel.setDescription("Channel for web app notifications");
            NotificationManager notificationManager = getSystemService(NotificationManager.class);
            notificationManager.createNotificationChannel(channel);
            Log.d("WebToApk", "Notification channel created.");
        }

        // --- NEW: REQUEST NOTIFICATION PERMISSION FOR ANDROID 13+ ---
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this,
                        new String[]{Manifest.permission.POST_NOTIFICATIONS},
                        NOTIFICATION_PERMISSION_REQUEST_CODE);
                Log.d("WebToApk", "Requesting POST_NOTIFICATIONS permission.");
            }
        }
        // -----------------------------------------------------------

        // --- REQUEST LOCATION PERMISSION EARLY (before WebView loads) ---
        if (geolocationEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
                    != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this,
                        new String[]{Manifest.permission.ACCESS_FINE_LOCATION},
                        LOCATION_PERMISSION_REQUEST_CODE);
                Log.d("WebToApk", "Requesting LOCATION permission early in onCreate.");
            }
        }
        // -----------------------------------------------------------

        if (forceLandscapeMode) {
            setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        }

        setContentView(R.layout.activity_main);
        SwipeRefreshLayout swipeRefresh = findViewById(R.id.swipeRefresh);
        mainLayout = findViewById(android.R.id.content);
        parentLayout = (ViewGroup) mainLayout.getParent();
        userScriptManager = new UserScriptManager(this, mainURL);

        biometricOverlay = findViewById(R.id.biometricOverlay);
        unlockButton = findViewById(R.id.unlockButton);
        lockPulseRing = findViewById(R.id.lockPulseRing);
        if (biometricLockEnabled) {
            long timeoutMs = biometricTimeoutMinutes * 60 * 1000L;
            biometricAuthManager = new BiometricAuthManager(this, timeoutMs, biometricType);
            if (biometricAuthManager.isBiometricAvailable()) {
                if (biometricAuthManager.needsReauthentication()) {
                    biometricOverlay.setVisibility(View.VISIBLE);
                    if (unlockButton != null) {
                        unlockButton.setOnClickListener(v -> promptBiometricAuth());
                    }
                    biometricOverlay.setOnClickListener(v -> promptBiometricAuth());
                    startPulseAnimation();
                    promptBiometricAuth();
                } else {
                    isAuthenticated = true;
                    Log.i("WebToApk", "Biometric auth still valid, skipping prompt");
                }
            } else {
                isAuthenticated = true;
                Log.w("WebToApk", "Biometric not available, skipping auth");
            }
        } else {
            isAuthenticated = true;
        }

        // Handle OAuth redirect intent
        Intent intent = getIntent();
        String action = intent.getAction();
        Uri data = intent.getData();
        Log.d("WebToApk", "Action: " + action + ", Data: " + data);
        
        // Initialize WebView before checking for OAuth redirect
        webview = findViewById(R.id.webView);
        webview.setVisibility(View.GONE);

        if (Intent.ACTION_VIEW.equals(action) && data != null && OAUTH_REDIRECT_SCHEME.equals(data.getScheme()) && OAUTH_REDIRECT_HOST.equals(data.getHost())) {
            webview.loadUrl(data.toString());
            // Since webview is initialized, we can safely proceed with setup below
        }

        webview.setWebViewClient(new CustomWebViewClient());
        webview.setWebChromeClient(new CustomWebChrome());
       

swipeRefresh.setOnRefreshListener(() -> {
    webview.reload();
    swipeRefresh.setRefreshing(false);
});
        webAppInterface = new WebAppInterface(this);
        webview.addJavascriptInterface(webAppInterface, "WebToApk");

        WebSettings webSettings = webview.getSettings();
        webSettings.setJavaScriptEnabled(JSEnabled);
        webSettings.setJavaScriptCanOpenWindowsAutomatically(JSCanOpenWindowsAutomatically);
        webSettings.setDomStorageEnabled(DomStorageEnabled);
        webSettings.setDatabaseEnabled(DatabaseEnabled);
        webSettings.setMediaPlaybackRequiresUserGesture(MediaPlaybackRequiresUserGesture);
        webSettings.setSavePassword(SavePassword);
        webSettings.setAllowFileAccess(AllowFileAccess);
        webSettings.setAllowFileAccessFromFileURLs(AllowFileAccessFromFileURLs);
        webSettings.setSupportZoom(zoomEnabled);
        webSettings.setBuiltInZoomControls(zoomEnabled);
        if (zoomEnabled) {
            webSettings.setDisplayZoomControls(false);
        }
        webview.setWebContentsDebuggingEnabled(DebugWebView);
        webSettings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW); // Enforce HTTPS

        if (geolocationEnabled) {
            webSettings.setGeolocationEnabled(true);
            webSettings.setGeolocationDatabasePath(getFilesDir().getPath());
        }

        if (!userAgent.isEmpty()) {
            webSettings.setUserAgentString(userAgent);
        } else {
            webSettings.setUserAgentString("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36");
        }

        webSettings.setCacheMode(WebSettings.LOAD_DEFAULT);
        
webSettings.setAllowUniversalAccessFromFileURLs(true);
        webview.setOverScrollMode(WebView.OVER_SCROLL_NEVER);


        CookieManager cookieManager = CookieManager.getInstance();
        cookieManager.setAcceptThirdPartyCookies(webview, true);
        cookieManager.setCookie(mainURL, cookies);
        cookieManager.flush();
        
                // --- Allow swipe / Back navigation ---
webview.setOnKeyListener((v, keyCode, event) -> {
    if (v.hasFocus() && event.getAction() == KeyEvent.ACTION_DOWN) {
        if (keyCode == KeyEvent.KEYCODE_BACK && webview.canGoBack()) {
            webview.goBack();
            return true;
        }
    }
    return false;
});

        fileChooserLauncher = registerForActivityResult(
            new ActivityResultContracts.StartActivityForResult(),
            result -> {
                Uri[] results = null;

                if (result.getResultCode() == Activity.RESULT_OK && result.getData() != null) {
                    Intent intentData = result.getData();
                    if (intentData.getClipData() != null) {
                        int count = intentData.getClipData().getItemCount();
                        results = new Uri[count];
                        for (int i = 0; i < count; i++) {
                            results[i] = intentData.getClipData().getItemAt(i).getUri();
                        }
                    } else if (intentData.getData() != null) {
                        results = new Uri[]{intentData.getData()};
                    }
                }

                if (mFilePathCallback != null) {
                    mFilePathCallback.onReceiveValue(results);
                    mFilePathCallback = null;
                }
            }
        );

        webview.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimetype, long contentLength) {
                try {
                    Log.d("WebToApk", "onDownloadStart triggered - URL: " + url + ", MIME: " + mimetype);
                    // Toast for download start is not included to avoid unnecessary popups.

                    // --- Robust Filename Derivation ---
                    String filename = URLUtil.guessFileName(url, contentDisposition, mimetype);
                    if (filename == null || filename.isEmpty() || filename.matches("downloadfile\\.(bin|dat)")) {
                        String extension = getExtensionFromMimeType(mimetype);
                        filename = "downloaded_file_" + System.currentTimeMillis() + (extension != null ? "." + extension : "");
                        if (filename.endsWith(".")) { // Remove trailing dot if extension is null
                            filename = filename.substring(0, filename.length() - 1);
                        }
                    }
                    final String finalFilename = filename;
                    // ----------------------------------

                    // --- START OF ROBUST BLOB/DATA URL HANDLING (Base64 Bridge) ---
                    if (url.startsWith("blob:") || url.startsWith("data:")) {
                        Log.d("WebToApk", "Handling Blob/Data URL with Base64 bridge: " + url);
                        // Toast for blob start is not included.

                        String js = "javascript:(function() {" +
                            "try {" +
                            "  var url = '" + url.replace("'", "\\'") + "';" +
                            "  var filename = '" + finalFilename.replace("'", "\\'") + "';" +
                            "  var mimetype = '" + mimetype.replace("'", "\\'") + "';" +
                            "  if (url.startsWith('data:')) {" +
                            "    window.WebToApk.saveFileFromBase64(url, filename, mimetype);" +
                            "    return;" +
                            "  }" +
                            "  var xhr = new XMLHttpRequest();" +
                            "  xhr.open('GET', url, true);" +
                            "  xhr.responseType = 'blob';" +
                            "  xhr.onload = function() {" +
                            "    if (xhr.status === 200) {" +
                            "      var reader = new FileReader();" +
                            "      reader.onloadend = function() {" +
                            "        window.WebToApk.saveFileFromBase64(reader.result, filename, mimetype);" +
                            "      };" +
                            "      reader.onerror = function() {" +
                            "        window.WebToApk.onBlobDownloadError('FileReader failed');" +
                            "      };" +
                            "      reader.readAsDataURL(xhr.response);" +
                            "    } else {" +
                            "      window.WebToApk.onBlobDownloadError('XHR failed with status: ' + xhr.status);" +
                            "    }" +
                            "  };" +
                            "  xhr.onerror = function() {" +
                            "    window.WebToApk.onBlobDownloadError('XHR request failed');" +
                            "  };" +
                            "  xhr.send();" +
                            "} catch (e) {" +
                            "  window.WebToApk.onBlobDownloadError('JavaScript error: ' + e.message);" +
                            "}" +
                            "})()";

                        webview.post(() -> webview.evaluateJavascript(js, null)); 
                        return; // Consume the download, handled by Base64 bridge
                    }
                    // --- END OF ROBUST BLOB/DATA URL HANDLING ---

                    // Non-Blob URL handling (Standard DownloadManager)
                    Log.d("WebToApk", "Handling non-Blob URL with DownloadManager: " + url);
                    useDownloadManager(url, userAgent, contentDisposition, mimetype, contentLength, finalFilename);
                } catch (Exception e) {
                    Log.e("WebToApk", "Download process failed", e);
                    Toast.makeText(MainActivity.this, "Download failed: " + e.getMessage(), Toast.LENGTH_LONG).show(); // KEPT: Critical failure toast
                }
            }
        });

        if (geolocationEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
                    != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this,
                        new String[]{Manifest.permission.ACCESS_FINE_LOCATION},
                        LOCATION_PERMISSION_REQUEST_CODE);
            }
        }

        unifiedPushEndpointReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String endpoint = intent.getStringExtra("endpoint");
                String p256dh = intent.getStringExtra("p256dh");
                String auth = intent.getStringExtra("auth");

                Log.d("WebToApk", "Received new UnifiedPush data. Endpoint: " + endpoint);

                if (endpoint != null && p256dh != null && auth != null && webview != null) {
                    try {
                        JSONObject keys = new JSONObject();
                        keys.put("p256dh", p256dh);
                        keys.put("auth", auth);

                        JSONObject subscription = new JSONObject();
                        subscription.put("endpoint", endpoint);
                        subscription.put("expirationTime", JSONObject.NULL);
                        subscription.put("keys", keys);

                        String subscriptionJson = subscription.toString();

                        webview.post(() -> {
                            String js = "if (typeof window.__shim_onNewEndpoint === 'function') { window.__shim_onNewEndpoint('" + subscriptionJson.replace("'", "\\'") + "'); }";
                            webview.evaluateJavascript(js, null);
                        });
                    } catch (JSONException e) {
                        Log.e("WebToApk", "Failed to create subscription JSON for shim", e);
                    }
                }
            }
        };

        // Correct registration for API 33+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(unifiedPushEndpointReceiver, new IntentFilter("com.matrix.webtoapk.NEW_ENDPOINT"), Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(unifiedPushEndpointReceiver, new IntentFilter("com.matrix.webtoapk.NEW_ENDPOINT"));
        }

        if (edgeToEdge) {
            ViewCompat.setOnApplyWindowInsetsListener(mainLayout, (v, windowInsets) -> {
                Insets insets = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars());
                float density = v.getResources().getDisplayMetrics().density;
                float top = insets.top / density;
                float bottom = insets.bottom / density;
                float left = insets.left / density;
                float right = insets.right / density;

                Log.d("WebToApk", String.format(java.util.Locale.US,
                    "Insets (CSS px) -> T:%.2f, B:%.2f, L:%.2f, R:%.2f",
                    top, bottom, left, right
                ));

                String js = String.format(java.util.Locale.US,
                    "document.documentElement.style.setProperty('--safe-area-inset-top', '%.2fpx');" +
                    "document.documentElement.style.setProperty('--safe-area-inset-bottom', '%.2fpx');" +
                    "document.documentElement.style.setProperty('--safe-area-inset-left', '%.2fpx');" +
                    "document.documentElement.style.setProperty('--safe-area-inset-right', '%.2fpx');" +
                    "document.dispatchEvent(new CustomEvent('WebToApkInsetsApplied'));",
                    top, bottom, left, right
                );
                webview.evaluateJavascript(js, null);

                return WindowInsetsCompat.CONSUMED;
            });
        }

if (savedInstanceState != null) {
    webview.restoreState(savedInstanceState);
    webview.setVisibility(View.VISIBLE);
} else {
    new Handler(Looper.getMainLooper()).postDelayed(() -> {
        webview.loadUrl(mainURL);
    }, 500);
    
    // Fallback: Make WebView visible after 3 seconds even if page hasn't loaded
    // This prevents blank screen issues when network is slow or errors occur
    new Handler(Looper.getMainLooper()).postDelayed(() -> {
        if (webview.getVisibility() != View.VISIBLE) {
            Log.d("WebToApk", "Fallback: Making WebView visible after timeout");
            webview.setVisibility(View.VISIBLE);
        }
    }, 3000);
}

        mediaActionReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent != null && intent.getAction() != null && intent.getAction().equals("com.matrix.webtoapk.MEDIA_ACTION")) {
                    String action = intent.getStringExtra("EXTRA_MEDIA_ACTION");
                    if (action != null) {
                        executeMediaActionInWebView(action);
                    }
                }
            }
        };
        LocalBroadcastManager.getInstance(this).registerReceiver(mediaActionReceiver, new IntentFilter("com.matrix.webtoapk.MEDIA_ACTION"));
    }

      // ── Runtime configuration from assets/webforge.conf ───────────────────────
      private void loadConfig() {
          try {
              InputStream is = getAssets().open("webforge.conf");
              BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));
              String line;
              while ((line = reader.readLine()) != null) {
                  line = line.trim();
                  if (line.isEmpty() || line.startsWith("#")) continue;
                  int eq = line.indexOf('=');
                  if (eq < 0) continue;
                  String key = line.substring(0, eq).trim();
                  String val = line.substring(eq + 1).trim();
                  switch (key) {
                      case "mainURL": if (!val.isEmpty()) mainURL = val; break;
                      case "requireDoubleBackToExit": requireDoubleBackToExit = "true".equalsIgnoreCase(val); break;
                      case "allowSubdomains": allowSubdomains = "true".equalsIgnoreCase(val); break;
                      case "enableExternalLinks": enableExternalLinks = "true".equalsIgnoreCase(val); break;
                      case "openExternalLinksInBrowser": openExternalLinksInBrowser = "true".equalsIgnoreCase(val); break;
                      case "confirmOpenInBrowser": confirmOpenInBrowser = "true".equalsIgnoreCase(val); break;
                      case "allowSwipeToNavigate": allowSwipeToNavigate = "true".equalsIgnoreCase(val); break;
                      case "allowOpenMobileApp": allowOpenMobileApp = "true".equalsIgnoreCase(val); break;
                      case "confirmOpenExternalApp": confirmOpenExternalApp = "true".equalsIgnoreCase(val); break;
                      case "cookies": if (!val.isEmpty()) cookies = val; break;
                      case "basicAuth": basicAuth = val; break;
                      case "userAgent": userAgent = val; break;
                      case "CacheMode": if (!val.isEmpty()) CacheMode = val; break;
                      case "enablePullToRefresh": enablePullToRefresh = "true".equalsIgnoreCase(val); break;
                      case "blockLocalhostRequests": blockLocalhostRequests = "true".equalsIgnoreCase(val); break;
                      case "JSEnabled": JSEnabled = "true".equalsIgnoreCase(val); break;
                      case "JSCanOpenWindowsAutomatically": JSCanOpenWindowsAutomatically = "true".equalsIgnoreCase(val); break;
                      case "DomStorageEnabled": DomStorageEnabled = "true".equalsIgnoreCase(val); break;
                      case "DatabaseEnabled": DatabaseEnabled = "true".equalsIgnoreCase(val); break;
                      case "MediaPlaybackRequiresUserGesture": MediaPlaybackRequiresUserGesture = "true".equalsIgnoreCase(val); break;
                      case "SavePassword": SavePassword = "true".equalsIgnoreCase(val); break;
                      case "AllowFileAccess": AllowFileAccess = "true".equalsIgnoreCase(val); break;
                      case "AllowFileAccessFromFileURLs": AllowFileAccessFromFileURLs = "true".equalsIgnoreCase(val); break;
                      case "AllowUniversalAccessFromFileURLs": AllowUniversalAccessFromFileURLs = "true".equalsIgnoreCase(val); break;
                      case "showDetailsOnErrorScreen": showDetailsOnErrorScreen = "true".equalsIgnoreCase(val); break;
                      case "forceLandscapeMode": forceLandscapeMode = "true".equalsIgnoreCase(val); break;
                      case "edgeToEdge": edgeToEdge = "true".equalsIgnoreCase(val); break;
                      case "forceDarkTheme": forceDarkTheme = "true".equalsIgnoreCase(val); break;
                      case "DebugWebView": DebugWebView = "true".equalsIgnoreCase(val); break;
                      case "geolocationEnabled": geolocationEnabled = "true".equalsIgnoreCase(val); break;
                      case "AppCacheEnabled": AppCacheEnabled = "true".equalsIgnoreCase(val); break;
                      case "AllowGeolocationPermissionAlways": AllowGeolocationPermissionAlways = "true".equalsIgnoreCase(val); break;
                      case "biometricLockEnabled": biometricLockEnabled = "true".equalsIgnoreCase(val); break;
                      case "biometricTimeoutMinutes":
                          try { biometricTimeoutMinutes = Integer.parseInt(val); } catch (NumberFormatException ignored) {} break;
                      case "biometricType": if (!val.isEmpty()) biometricType = val; break;
                      case "screenshotPrevention": screenshotPrevention = "true".equalsIgnoreCase(val); break;
                      case "zoomEnabled": zoomEnabled = "true".equalsIgnoreCase(val); break;
                      case "deepLinkEnabled": deepLinkEnabled = "true".equalsIgnoreCase(val); break;
                      case "deepLinkScheme": if (!val.isEmpty()) deepLinkScheme = val; break;
                      case "incognitoOnExit": incognitoOnExit = "true".equalsIgnoreCase(val); break;
                      case "pipEnabled": pipEnabled = "true".equalsIgnoreCase(val); break;
                      default: break;
                  }
              }
              reader.close();
          } catch (Exception e) {
              // webforge.conf not present or unreadable — use compiled-in defaults
              Log.d("WebToApk", "loadConfig: " + e.getMessage());
          }
      }

  
    private void registerForUnifiedPush(final String vapidPublicKey) {
        if (vapidPublicKey == null || vapidPublicKey.isEmpty()) {
            Log.e("WebToApk", "VAPID public key is null or empty. Cannot register for push.");
            return;
        }

        UnifiedPush.tryUseCurrentOrDefaultDistributor(this, new Function1<Boolean, Unit>() {
            @Override
            public Unit invoke(Boolean success) {
                if (success) {
                    Log.d("WebToApk", "UnifiedPush distributor found, registering...");
                    UnifiedPush.registerApp(MainActivity.this, "org.unifiedpush.distributors.noprovider", "com.matrix.webtoapk", vapidPublicKey);
                } else {
                    Log.w("WebToApk", "No UnifiedPush distributor found or user cancelled.");
                    new Handler(Looper.getMainLooper()).post(() -> {
                        new AlertDialog.Builder(MainActivity.this)
                            .setTitle(R.string.push_distributor_required_title)
                            .setMessage(R.string.push_distributor_required_message)
                            .setPositiveButton(R.string.learn_more, (dialog, which) -> {
                                Intent browserIntent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://unifiedpush.org/users/distributors/"));
                                startActivity(browserIntent);
                            })
                            .setNegativeButton(android.R.string.cancel, null)
                            .show();
                    });
                }
                return Unit.INSTANCE;
            }
        });
    }

    private void executeMediaActionInWebView(String action) {
        Log.d("WebToApk", "Executing JS for media action: " + action);
        if (webview != null) {
            webview.post(() -> {
                String js = "if (typeof window.__runMediaAction === 'function') { window.__runMediaAction('" + action + "'); }";
                webview.evaluateJavascript(js, null);
            });
        }
    }

    @Override
    protected void onDestroy() {
        if (incognitoOnExit && webview != null) {
            webview.clearCache(true);
            webview.clearHistory();
            CookieManager.getInstance().removeAllCookies(null);
            CookieManager.getInstance().flush();
            WebStorage.getInstance().deleteAllData();
        }
        super.onDestroy();
        if (unifiedPushEndpointReceiver != null) {
            // Unregistering the receiver safely
            try { unregisterReceiver(unifiedPushEndpointReceiver); } catch (Exception e) { Log.e("WebToApk", "Failed to unregister unifiedPushEndpointReceiver", e); }
        }
        if (mediaActionReceiver != null) {
            LocalBroadcastManager.getInstance(this).unregisterReceiver(mediaActionReceiver);
        }
    }

    @Override
    protected void onSaveInstanceState(@NonNull Bundle outState) {
        super.onSaveInstanceState(outState);
        webview.saveState(outState);
    }


    
    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);

        if (requestCode == STORAGE_PERMISSION_REQUEST_CODE) {
            // This is only triggered for WRITE_EXTERNAL_STORAGE (API < 29)
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                if (pendingDownloadUrl != null) {
                    // Retry the download using the pending data
                    useDownloadManager(pendingDownloadUrl, pendingDownloadUserAgent, pendingDownloadContentDisposition, pendingDownloadMimetype, pendingDownloadContentLength, pendingDownloadFilename);
                    
                    // Clear pending data after retrying
                    pendingDownloadUrl = null;
                    pendingDownloadUserAgent = null;
                    pendingDownloadContentDisposition = null;
                    pendingDownloadMimetype = null;
                    pendingDownloadContentLength = 0;
                    pendingDownloadFilename = null;
                }
                Toast.makeText(this, "Permission granted, retrying download", Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, "Storage permission denied. Downloads may not work.", Toast.LENGTH_LONG).show();
                pendingDownloadUrl = null;
            }
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Toast.makeText(this, "Notifications enabled. Download status will be visible.", Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, "Notifications denied. Download progress may not show in status bar.", Toast.LENGTH_LONG).show();
            }
        } else if (requestCode == LOCATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Toast.makeText(this, "Location permission granted.", Toast.LENGTH_SHORT).show();
                if (webview != null) {
                    isInitialLoad = true;
                    errorOccurred = false;
                    webview.reload();
                }
            } else {
                if (webview != null) {
                    webview.setVisibility(View.VISIBLE);
                }
            }
        }
    }

    private class CustomWebChrome extends WebChromeClient {
        @Override
        public boolean onConsoleMessage(ConsoleMessage consoleMessage) {
            String src = consoleMessage.sourceId();
            Integer line = consoleMessage.lineNumber();
            String msg = consoleMessage.message();

            if (src.startsWith("http://") || src.startsWith("https://")) {
                src = src.substring(8);
                Log.e("WebToApk", "[" + src + ":" + line + "] " + msg);
            } else {
                switch (consoleMessage.messageLevel()) {
                    case ERROR:
                        Log.e("WebToApk", "\u001B[0;31m[" + src + ":" + line + "] " + msg + "\u001B[0m");
                        break;
                    case WARNING:
                        Log.w("WebToApk", "\u001B[1;33m[" + src + ":" + line + "]\u001B[0m " + msg);
                        break;
                    case LOG:
                    case DEBUG:
                    case TIP:
                        Log.d("WebToApk", "\u001B[0;34m[" + src + ":" + line + "]\u001B[0m " + msg);
                        break;
                }
            }
            return true;
        }

        @Override
        public boolean onJsAlert(WebView view, String url, String message, final JsResult result) {
            new AlertDialog.Builder(MainActivity.this)
                .setMessage(message)
                .setPositiveButton(android.R.string.ok, (dialog, which) -> result.confirm())
                .setCancelable(false)
                .create()
                .show();
            return true;
        }

        @Override
        public boolean onJsConfirm(WebView view, String url, String message, final JsResult result) {
            new AlertDialog.Builder(MainActivity.this)
                .setMessage(message)
                .setPositiveButton(android.R.string.ok, (dialog, which) -> result.confirm())
                .setNegativeButton(android.R.string.cancel, (dialog, which) -> result.cancel())
                .setCancelable(false)
                .create()
                .show();
            return true;
        }

        @Override
        public boolean onJsPrompt(WebView view, String url, String message, String defaultValue, final JsPromptResult result) {
            final EditText input = new EditText(MainActivity.this);
            input.setText(defaultValue);
            new AlertDialog.Builder(MainActivity.this)
                .setMessage(message)
                .setView(input)
                .setPositiveButton(android.R.string.ok, (dialog, which) -> result.confirm(input.getText().toString()))
                .setNegativeButton(android.R.string.cancel, (dialog, which) -> result.cancel())
                .setCancelable(false)
                .create()
                .show();
            return true;
        }

        private View mCustomView;
        private WebChromeClient.CustomViewCallback mCustomViewCallback;
        private int mOriginalOrientation;
        private int mOriginalSystemUiVisibility;

        @Override
        public void onHideCustomView() {
            ((FrameLayout) getWindow().getDecorView()).removeView(mCustomView);
            mCustomView = null;
            getWindow().getDecorView().setSystemUiVisibility(mOriginalSystemUiVisibility);
            setRequestedOrientation(mOriginalOrientation);
            mCustomViewCallback.onCustomViewHidden();
            mCustomViewCallback = null;
        }

        @Override
        public void onShowCustomView(View view, WebChromeClient.CustomViewCallback callback) {
            if (mCustomView != null) {
                onHideCustomView();
                return;
            }
            mCustomView = view;
            mOriginalSystemUiVisibility = getWindow().getDecorView().getSystemUiVisibility();
            mOriginalOrientation = getRequestedOrientation();
            mCustomViewCallback = callback;
            ((FrameLayout) getWindow().getDecorView()).addView(mCustomView,
                new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE);
        }

        @Override
        public void onGeolocationPermissionsShowPrompt(String origin, android.webkit.GeolocationPermissions.Callback callback) {
            if (geolocationEnabled) {
                callback.invoke(origin, true, false);
            } else {
                callback.invoke(origin, false, false);
            }
        }

        @Override
        public boolean onShowFileChooser(WebView webView, ValueCallback<Uri[]> filePathCallback, FileChooserParams fileChooserParams) {
            if (mFilePathCallback != null) {
                mFilePathCallback.onReceiveValue(null);
            }
            mFilePathCallback = filePathCallback;

            Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*"); // Allow all file types

            String[] acceptTypes = fileChooserParams.getAcceptTypes();
            if (acceptTypes.length > 0 && acceptTypes[0] != null && !acceptTypes[0].isEmpty()) {
                intent.putExtra(Intent.EXTRA_MIME_TYPES, acceptTypes);
            }

            if (fileChooserParams.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) {
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
            }

            Intent chooserIntent = Intent.createChooser(intent, "Select File");

            try {
                fileChooserLauncher.launch(chooserIntent);
            } catch (ActivityNotFoundException e) {
                mFilePathCallback = null;
                Toast.makeText(MainActivity.this, "Cannot open file manager", Toast.LENGTH_LONG).show();
                return false;
            }

            return true;
        }
    }

    private void shareDownloadedFile(String filename) {
        File file = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), filename);
        if (!file.exists()) {
            Toast.makeText(this, "File not found. Please wait for the download to complete.", Toast.LENGTH_SHORT).show();
            return;
        }

        try {
            String authority = getPackageName() + ".fileprovider";
            Uri fileUri = FileProvider.getUriForFile(this, authority, file);

            String mimeType = getContentResolver().getType(fileUri);
            if (mimeType == null) {
                String lowerName = filename.toLowerCase();
                if (lowerName.endsWith(".apk")) mimeType = "application/vnd.android.package-archive";
                else if (lowerName.endsWith(".pdf")) mimeType = "application/pdf";
                else if (lowerName.endsWith(".jpg") || lowerName.endsWith(".jpeg") || lowerName.endsWith(".png") || lowerName.endsWith(".gif"))
                    mimeType = "image/*";
                else if (lowerName.endsWith(".mp4") || lowerName.endsWith(".avi") || lowerName.endsWith(".mkv")) mimeType = "video/*";
                else if (lowerName.endsWith(".mp3") || lowerName.endsWith(".wav")) mimeType = "audio/*";
                else if (lowerName.endsWith(".txt") || lowerName.endsWith(".html")) mimeType = "text/plain";
                else mimeType = "*/*";
            }

            Intent finalIntent = new Intent(Intent.ACTION_VIEW);
            finalIntent.setDataAndType(fileUri, mimeType);
            finalIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);

            Intent chooserIntent = Intent.createChooser(finalIntent, "Open or Share: " + filename);
            startActivity(chooserIntent);

            Log.d("WebToApk", "Shared file via chooser: " + filename + " (MIME: " + mimeType + ")");
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, "Sharing failed: Check FileProvider configuration.", Toast.LENGTH_LONG).show();
            Log.e("WebToApk", "FileProvider error: " + e.getMessage(), e);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "No app found to open: " + filename, Toast.LENGTH_LONG).show();
            Log.e("WebToApk", "No app for file type: " + filename, e);
        } catch (Exception e) {
            Toast.makeText(this, "Failed to share: " + e.getMessage(), Toast.LENGTH_LONG).show();
            Log.e("WebToApk", "Sharing error for: " + filename, e);
        }
    }

    private class CustomWebViewClient extends WebViewClient {
    @Override
    public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
        if (DebugWebView) {
            new AlertDialog.Builder(MainActivity.this)
                .setMessage(R.string.notification_error_ssl_cert_invalid)
                .setPositiveButton("Continue", (dialog, which) -> handler.proceed())
                .setNegativeButton("Cancel", (dialog, which) -> handler.cancel())
                .setCancelable(false)
                .show();
        } else {
            handler.cancel();
        }
    }

    @Override
    public void onReceivedHttpAuthRequest(final WebView view, final android.webkit.HttpAuthHandler handler, String host, String realm) {
        if (MainActivity.this.basicAuth != null && !MainActivity.this.basicAuth.isEmpty()) {
            String[] parts = MainActivity.this.basicAuth.split(":", 2);
            if (parts.length == 2) {
                String login = parts[0];
                String password = parts[1];
                String mainDomain = Uri.parse(MainActivity.this.mainURL).getHost();

                boolean domainIsValid = false;
                if (mainDomain != null && !mainDomain.isEmpty() && host != null && !host.isEmpty()) {
                    if (MainActivity.this.allowSubdomains) {
                        domainIsValid = host.endsWith(mainDomain) || mainDomain.endsWith(host);
                    } else {
                        domainIsValid = host.equals(mainDomain);
                    }
                }

                if (domainIsValid) {
                    handler.proceed(login, password);
                    return;
                }
            }
        }

        final View dialogView = getLayoutInflater().inflate(R.layout.auth_dialog, null);
        final EditText usernameInput = dialogView.findViewById(R.id.username);
        final EditText passwordInput = dialogView.findViewById(R.id.password);

        new AlertDialog.Builder(MainActivity.this)
            .setTitle("Authentication Required")
            .setView(dialogView)
            .setPositiveButton("OK", (dialog, which) -> {
                String user = usernameInput.getText().toString();
                String pass = passwordInput.getText().toString();
                handler.proceed(user, pass);
            })
            .setNegativeButton("Cancel", (dialog, which) -> handler.cancel())
            .show();
    }

   @Override
public void onPageStarted(WebView webView, String url, Bitmap favicon) {
    super.onPageStarted(webView, url, favicon);
    if (isInitialLoad) {
        userScriptManager.injectScripts(webView, url);
        errorOccurred = false;
    }
    
    // Make WebView visible early when page starts loading
    // This ensures users see content loading instead of blank screen
    if (webView.getVisibility() != View.VISIBLE) {
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            if (webView.getVisibility() != View.VISIBLE) {
                Log.d("WebToApk", "Making WebView visible on page start");
                webView.setVisibility(View.VISIBLE);
            }
        }, 3000); // Show after 3 seconds if still loading
    }
}

@Override
public void onPageFinished(WebView webView, String url) {
    super.onPageFinished(webView, url);
    if (isInitialLoad && !errorOccurred) {
        Log.d("WebToApk", "Page loaded: " + url);
        errorOccurred = false;
        isInitialLoad = false;
        // If webview is not visible, make it visible.
        if (webView.getVisibility() != View.VISIBLE) {
            webView.setVisibility(View.VISIBLE);
        }
    } else if (!errorOccurred) {
        Log.d("WebToApk", "Subsequent page loaded: " + url);
        if (webView.getVisibility() != View.VISIBLE) {
            webView.setVisibility(View.VISIBLE);
        }
    } else {
        Log.w("WebToApk", "Page finished with error; splash/error layout remains: " + url);
    }
}

    @Override
public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
    super.onReceivedError(view, request, error);
    
    // Only treat main frame errors as fatal (ignore subresource errors like ads, tracking scripts)
    if (request.isForMainFrame()) {
        errorOccurred = true;
        Log.e("WebToApk", "Main frame WebView error: " + error.getDescription());
        
        if (errorLayout != null) {
            errorLayout.setVisibility(View.VISIBLE);
        }
        
        // Even on error, make WebView visible so user can see error page or retry
        if (view.getVisibility() != View.VISIBLE) {
            view.setVisibility(View.VISIBLE);
        }
    } else {
        // Subresource error - log but don't block the page
        Log.w("WebToApk", "Subresource error (ignored): " + error.getDescription() + " for URL: " + request.getUrl());
    }
}

    @Override
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        String url = request.getUrl().toString();
        Log.d("WebToApk", "Loading URL: " + url + ", allowOpenMobileApp: " + allowOpenMobileApp);

        // Handle native app schemes
        if (isNativeAppUrl(url)) {
            Log.d("WebToApk", "Detected native app URL: " + url);
            if (allowOpenMobileApp) {
                if (confirmOpenExternalApp) {
                    new AlertDialog.Builder(MainActivity.this)
                        .setTitle(R.string.external_link)
                        .setMessage(R.string.open_in_external_app)
                        .setPositiveButton(android.R.string.yes, (dialog, which) -> {
                            launchExternalApp(url);
                        })
                        .setNegativeButton(android.R.string.no, null)
                        .setOnCancelListener(dialog -> {
                            // Do nothing if canceled
                        })
                        .show();
                } else {
                    launchExternalApp(url);
                }
            } else {
                Log.d("WebToApk", "External app opening disabled for URL: " + url);
                Toast.makeText(MainActivity.this, "Opening external apps is disabled.", Toast.LENGTH_SHORT).show();
            }
            return true; // Prevent WebView from loading the URL
        }

        // Allow all other URLs (including Google OAuth) to load in WebView
        Log.d("WebToApk", "Loading URL in WebView: " + url);
        return false;
    }

    private void launchExternalApp(String url) {
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            startActivity(intent);
            Log.d("WebToApk", "Successfully launched external app for URL: " + url);
        } catch (ActivityNotFoundException e) {
            Log.e("WebToApk", "No app found for URL: " + url, e);
            Toast.makeText(MainActivity.this, "No app installed to handle this link.", Toast.LENGTH_LONG).show();
        }
    }

    private boolean isNativeAppUrl(String url) {
        String lowerUrl = url.toLowerCase();
        return lowerUrl.startsWith("telegram://") ||
               lowerUrl.startsWith("tg:") ||
               lowerUrl.startsWith("whatsapp://") ||
               lowerUrl.startsWith("instagram://") ||
               lowerUrl.startsWith("fb://") ||
               lowerUrl.startsWith("twitter://") ||
               lowerUrl.startsWith("tiktok://") ||
               lowerUrl.startsWith("snapchat://");
    }
}

    public class UserScriptManager {
        private Context context;
        private String mainURL;

        public UserScriptManager(Context context, String mainURL) {
            this.context = context;
            this.mainURL = mainURL;
        }

        public void injectScripts(WebView webView, String url) {
            // Add script injection logic if needed
        }
    }

    public class WebAppInterface {
        Context mContext;

        WebAppInterface(Context c) {
            mContext = c;
        }

        @JavascriptInterface
        public void showToast(String toast) {
            Toast.makeText(mContext, toast, Toast.LENGTH_LONG).show();
        }

        @JavascriptInterface
        public void subscribeForPush(String publicKey) {
            Log.d("WebToApk", "subscribeForPush called with publicKey: " + publicKey);
            registerForUnifiedPush(publicKey);
        }

        @JavascriptInterface
        public void onBlobDownloadError(String error) {
            new Handler(Looper.getMainLooper()).post(() -> {
                Log.e("WebToApk", "Blob download error (JS bridge): " + error);
                Toast.makeText(mContext, "Blob download failed: " + error, Toast.LENGTH_LONG).show(); // KEPT: Critical failure toast
            });
        }
        
        /**
         * Receives Base64 encoded file content from JavaScript and saves it as a file.
         * This is the robust fix for downloading Blob and Data URLs.
         */
        @JavascriptInterface
        public void saveFileFromBase64(String base64Data, String filename, String mimeType) {
            if (base64Data == null || base64Data.isEmpty()) {
                new Handler(Looper.getMainLooper()).post(() ->
                    Toast.makeText(mContext, "Download failed: No data received.", Toast.LENGTH_LONG).show() // KEPT: Critical failure toast
                );
                return;
            }

            // Remove the data prefix if present (e.g., "data:image/png;base64,")
            if (base64Data.contains(",")) {
                base64Data = base64Data.substring(base64Data.indexOf(",") + 1);
            }

            try {
                // Decode the base64 string into file bytes
                byte[] fileBytes = android.util.Base64.decode(base64Data, android.util.Base64.DEFAULT);
                
                // File will be saved to the standard Downloads folder
                File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                if (!dir.exists() && !dir.mkdirs()) {
                    Log.e("WebToApk", "Failed to create Downloads directory: " + dir.getAbsolutePath());
                    new Handler(Looper.getMainLooper()).post(() ->
                        Toast.makeText(mContext, "Download failed: Cannot access storage.", Toast.LENGTH_LONG).show() // KEPT: Critical failure toast
                    );
                    return;
                }

                File outputFile = new File(dir, filename);
                FileOutputStream fos = new FileOutputStream(outputFile);
                fos.write(fileBytes);
                fos.flush();
                fos.close();

                // Run on UI thread to ensure toast is visible
                new Handler(Looper.getMainLooper()).post(() -> {
                    // <-- TOAST RE-ADDED: Download success toast for Base64 method
                    Toast.makeText(mContext, "Download successful: " + filename, Toast.LENGTH_LONG).show();
                    // Immediately scan the file to make it visible in the Downloads folder
                    ((MainActivity)mContext).scanFile(outputFile.getAbsolutePath(), mimeType);
                });
                Log.d("WebToApk", "Base64 file saved successfully to: " + outputFile.getAbsolutePath());

            } catch (IOException | IllegalArgumentException e) {
                Log.e("WebToApk", "Failed to save file from Base64: " + e.getMessage(), e);
                new Handler(Looper.getMainLooper()).post(() ->
                    Toast.makeText(mContext, "Download failed: " + e.getMessage(), Toast.LENGTH_LONG).show() // KEPT: Critical failure toast
                );
            }
        }
    }
 
 
 @Override
public boolean onKeyDown(int keyCode, KeyEvent event) {
    if (event.getAction() == KeyEvent.ACTION_DOWN && keyCode == KeyEvent.KEYCODE_BACK && requireDoubleBackToExit) {
        if (webview.canGoBack()) {
            webview.goBack();
            return true;
        } else {
            long currentTime = System.currentTimeMillis();
            if (currentTime - lastBackPressedTime < 2000) {
                finish();
                return true;
            } else {
                Toast.makeText(this, "Press back again to exit", Toast.LENGTH_SHORT).show();
                lastBackPressedTime = currentTime;
                return true;
            }
        }
    }
    return super.onKeyDown(keyCode, event);
}
    

    // Download-related methods
    private long enqueueDownload(DownloadManager dm, DownloadManager.Request req, String filename) {
        try {
            long downloadId = dm.enqueue(req);
            // Toast for download start is not included here, as the status bar notification handles this feedback.
            return downloadId;
        } catch (Exception e) {
            Toast.makeText(this, "Download failed: " + e.getMessage(), Toast.LENGTH_LONG).show(); // KEPT: Critical failure toast
            Log.e("WebToApk", "Failed to start download", e);
            return -1;
        }
    }

  private void checkDownloadStatus(long downloadId, String filename, String mimeType) {
    new Handler(Looper.getMainLooper()).postDelayed(() -> {
        DownloadManager downloadManager = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
        DownloadManager.Query query = new DownloadManager.Query().setFilterById(downloadId);
        boolean downloadComplete = false;

        try (Cursor cursor = downloadManager.query(query)) {
            if (cursor != null && cursor.moveToFirst()) {
                int statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS);
                int localUriIndex = cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI);
                int reasonIndex = cursor.getColumnIndex(DownloadManager.COLUMN_REASON);
                int titleIndex = cursor.getColumnIndex(DownloadManager.COLUMN_TITLE);

                if (statusIndex == -1 || localUriIndex == -1 || reasonIndex == -1 || titleIndex == -1) {
                    Log.e("WebToApk", "DownloadManager cursor missing required columns.");
                    return;
                }

                int status = cursor.getInt(statusIndex);
                String localUri = cursor.getString(localUriIndex);
                String title = cursor.getString(titleIndex);

                switch (status) {
                    case DownloadManager.STATUS_SUCCESSFUL:
                        downloadComplete = true;
                        if (localUri != null && localUri.startsWith("file://")) {
                            String path = Uri.parse(localUri).getPath();
                            Log.d("WebToApk", "Download completed. Path: " + path);
                            Toast.makeText(this, "Download completed: " + title, Toast.LENGTH_SHORT).show();
                            scanFile(path, mimeType);
                        } else {
                            Log.e("WebToApk", "Successful download but local URI is not a file path: " + localUri);
                        }
                        break;
                    case DownloadManager.STATUS_FAILED:
                        downloadComplete = true;
                        int reason = cursor.getInt(reasonIndex);
                        Log.e("WebToApk", "Download failed with reason: " + reason);
                        Toast.makeText(this, "Download failed", Toast.LENGTH_LONG).show();
                        break;
                    default:
                        Log.d("WebToApk", "Download in progress for ID: " + downloadId);
                        break;
                }
            }
        } catch (Exception e) {
            Log.e("WebToApk", "Error checking download status: " + e.getMessage(), e);
            downloadComplete = true;
        }

        if (!downloadComplete) {
            checkDownloadStatus(downloadId, filename, mimeType);
        }
    }, 5000);
}

public void scanFile(String path, String mimeType) {
    MediaScannerConnection.scanFile(this,
        new String[]{path},
        new String[]{mimeType},
        (p, uri) -> Log.d("WebToApk", "File scanned: " + p + " -> " + uri));
}

private void useDownloadManager(String url, String userAgent, String contentDisposition, String mimetype, long contentLength, String filename) {
    DownloadManager downloadManager = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
    DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url));
    request.setMimeType(mimetype);
    request.addRequestHeader("Cookie", CookieManager.getInstance().getCookie(url));
    request.addRequestHeader("User-Agent", userAgent);
    request.setDescription("Downloading: " + filename);
    request.setTitle(filename);

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
        ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
        request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_HIDDEN);
    } else {
        request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
    }

    request.setVisibleInDownloadsUi(true);
    request.allowScanningByMediaScanner();
    request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename);

    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED) {
            pendingDownloadUrl = url;
            pendingDownloadUserAgent = userAgent;
            pendingDownloadContentDisposition = contentDisposition;
            pendingDownloadMimetype = mimetype;
            pendingDownloadContentLength = contentLength;
            pendingDownloadFilename = filename;
            ActivityCompat.requestPermissions(this,
                new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE},
                STORAGE_PERMISSION_REQUEST_CODE);
            Log.d("WebToApk", "Requesting WRITE_EXTERNAL_STORAGE permission for download (API < 29).");
            return;
        }
    }

    long downloadId = enqueueDownload(downloadManager, request, filename);
    if (downloadId != -1) checkDownloadStatus(downloadId, filename, mimetype);
}

private void fallbackToDownloadManager(String url, String userAgent, String contentDisposition, String mimetype, long contentLength, String filename) {
    Log.d("WebToApk", "Falling back to DownloadManager for: " + url);
    Toast.makeText(this, "Falling back to DownloadManager for: " + url, Toast.LENGTH_SHORT).show();
    useDownloadManager(url, userAgent, contentDisposition, mimetype, contentLength, filename);
}

private String getExtensionFromMimeType(String mimeType) {
    if (mimeType == null) return null;
    switch (mimeType.toLowerCase()) {
        case "application/pdf": return "pdf";
        case "image/jpeg":
        case "image/jpg":
        case "image/pjpeg": return "jpg";
        case "image/png": return "png";
        case "image/gif": return "gif";
        case "image/webp": return "webp";
        case "image/svg+xml": return "svg";

        case "video/mp4":
        case "application/mp4": return "mp4";
        case "video/webm": return "webm";
        case "video/quicktime": return "mov";
        case "video/x-msvideo": return "avi";

        case "audio/mpeg":
        case "audio/mp3": return "mp3";
        case "audio/wav":
        case "audio/x-wav": return "wav";
        case "audio/ogg": return "ogg";

        case "text/plain": return "txt"; // Added
        case "text/html": return "html";
        case "text/css": return "css";

        case "application/javascript":
        case "text/javascript":
        case "application/x-javascript": return "js"; // Added

        case "application/x-python-code":
        case "text/x-python": return "py"; // Added

        case "application/x-php":
        case "text/php": return "php"; // Added

        case "application/json": return "json";
        case "application/xml":
        case "text/xml": return "xml";

        case "application/zip": return "zip";
        case "application/x-rar-compressed": return "rar";
        case "application/gzip": return "gz";
        case "application/x-tar": return "tar";

        case "application/vnd.android.package-archive": return "apk";
        case "application/msword": return "doc";
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx";
        case "application/vnd.ms-excel": return "xls";
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx";
        case "application/vnd.ms-powerpoint": return "ppt";
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx";

        // Fallback for general binary data
        case "application/octet-stream": return "bin";

        // If a highly specific MIME type isn't covered, it will fall through to null.
        default: return null;
    }
}

@Override
@Override
protected void onUserLeaveHint() {
    super.onUserLeaveHint();
    if (pipEnabled && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
        try {
            PictureInPictureParams params = new PictureInPictureParams.Builder().build();
            enterPictureInPictureMode(params);
        } catch (Exception e) {
            Log.e("WebToApk", "PiP not supported on this device", e);
        }
    }
}

protected void onPause() {
    super.onPause();
    if (webview != null) webview.onPause();
}

@Override
protected void onResume() {
    super.onResume();
    if (webview != null) webview.onResume();
    
    if (biometricLockEnabled && biometricAuthManager != null && isAuthenticated) {
        if (biometricAuthManager.needsReauthentication()) {
            isAuthenticated = false;
            biometricOverlay.setVisibility(View.VISIBLE);
            startPulseAnimation();
            promptBiometricAuth();
        }
    }
}

@Override
protected void onRestoreInstanceState(Bundle savedInstanceState) {
    super.onRestoreInstanceState(savedInstanceState);
    if (webview != null && savedInstanceState != null) {
        webview.restoreState(savedInstanceState);
    }
}

@Override
public void onLowMemory() {
    super.onLowMemory();
    if (webview != null) webview.stopLoading();
}

private void startPulseAnimation() {
    if (lockPulseRing == null) return;
    
    android.animation.ObjectAnimator scaleX = android.animation.ObjectAnimator.ofFloat(lockPulseRing, "scaleX", 1f, 1.3f, 1f);
    android.animation.ObjectAnimator scaleY = android.animation.ObjectAnimator.ofFloat(lockPulseRing, "scaleY", 1f, 1.3f, 1f);
    android.animation.ObjectAnimator alpha = android.animation.ObjectAnimator.ofFloat(lockPulseRing, "alpha", 0.4f, 0.1f, 0.4f);
    
    android.animation.AnimatorSet pulseSet = new android.animation.AnimatorSet();
    pulseSet.playTogether(scaleX, scaleY, alpha);
    pulseSet.setDuration(2000);
    pulseSet.setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator());
    pulseSet.addListener(new android.animation.AnimatorListenerAdapter() {
        @Override
        public void onAnimationEnd(android.animation.Animator animation) {
            if (biometricOverlay != null && biometricOverlay.getVisibility() == View.VISIBLE) {
                pulseSet.start();
            }
        }
    });
    pulseSet.start();
}

private void promptBiometricAuth() {
    if (biometricAuthManager == null) return;
    
    biometricAuthManager.authenticate(new BiometricAuthManager.AuthCallback() {
        @Override
        public void onAuthSuccess() {
            runOnUiThread(() -> {
                isAuthenticated = true;
                biometricOverlay.setVisibility(View.GONE);
                Log.i("WebToApk", "Biometric authentication successful");
            });
        }

        @Override
        public void onAuthError(String error) {
            runOnUiThread(() -> {
                Toast.makeText(MainActivity.this, "Authentication failed: " + error, Toast.LENGTH_LONG).show();
                Log.e("WebToApk", "Biometric auth error: " + error);
            });
        }

        @Override
        public void onAuthCancelled() {
            runOnUiThread(() -> {
                Toast.makeText(MainActivity.this, "Tap to unlock", Toast.LENGTH_SHORT).show();
            });
        }
    });
}
}
