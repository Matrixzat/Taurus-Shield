package com.matrix.webtoapk;

import android.content.Context;
import android.webkit.JavascriptInterface;
import android.util.Log;
import android.widget.Toast;

public class WebAppInterface {
    Context mContext;

    /** Instantiate the interface and set the context */
    WebAppInterface(Context c) {
        mContext = c;
    }

    /** Show a toast from the web page */
    @JavascriptInterface
    public void showToast(String toast) {
        Toast.makeText(mContext, toast, Toast.LENGTH_SHORT).show();
    }
    
    /** Log a message from the web page */
    @JavascriptInterface
    public void log(String tag, String message) {
        Log.d(tag, message);
    }
}