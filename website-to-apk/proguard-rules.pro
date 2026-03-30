# Keep MainActivity and its members
-keepclassmembers class com.matrix.webtoapk.MainActivity {
    *;
}

# Preserve WebView and related classes
-keep class android.webkit.** { *; }
-dontwarn android.webkit.**

# Preserve Lottie animation library
-keep class com.airbnb.lottie.** { *; }
-dontwarn com.airbnb.lottie.**

# Preserve UnifiedPush library
-keep class org.unifiedpush.android.** { *; }
-dontwarn org.unifiedpush.android.**

# Preserve specific AndroidX classes used
-keep class androidx.core.content.FileProvider { *; }
-keep class androidx.localbroadcastmanager.content.LocalBroadcastManager { *; }
-keep class androidx.media.** { *; }
-dontwarn androidx.**

# Preserve JavaScript interfaces
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# Preserve Parcelable and Serializable classes (if used)
-keepnames class * implements android.os.Parcelable {
    static ** CREATOR;
}
-keepclassmembers class * implements java.io.Serializable {
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Preserve DownloadManager and related classes
-keep class android.app.DownloadManager { *; }
-dontwarn android.app.DownloadManager**

# Prevent obfuscation of custom views and layouts
-keepclassmembers class **.R$* {
    public static <fields>;
}

# Keep annotations (e.g., for JavaScriptInterface)
-keepattributes *Annotation*

# Optional: Suppress specific warnings if needed
#-dontwarn <specific-package>  # Uncomment and specify if issues arise