package com.taurus.matrix;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.ToggleButton;

public class ModMenu {

    // ── Native methods (implemented in libmatrix-hook.so) ─────────────────────
    static native void  nativeToggle(int featureId, boolean enabled);
    static native boolean nativeGetState(int featureId);

    // ── Feature IDs — must match hook.cpp order ────────────────────────────────
    static final int FEAT_NO_ADS   = 0;
    static final int FEAT_COINS    = 1;
    static final int FEAT_JUMP     = 2;
    static final int FEAT_SPEED    = 3;
    static final int FEAT_GRAVITY  = 4;
    static final int FEAT_POWERUPS = 5;
    static final int FEAT_SCORE    = 6;
    static final int FEAT_REVIVE   = 7;

    static final String[] NAMES = {
        "No Ads",
        "Coins x999,999",
        "Jump x100  /  3x Height",
        "Speed x5",
        "Low Gravity",
        "Powerups Always On",
        "Score Booster Max",
        "Unlimited Revive"
    };

    static final int[] ICONS = {
        0, 1, 2, 3, 4, 5, 6, 7
    };

    private static FrameLayout  gPanel;
    private static boolean      gPanelVisible = false;

    // ── Entry point (called from native via JNI on UI thread) ──────────────────
    public static void show(final Activity activity) {
        activity.runOnUiThread(new Runnable() {
            @Override public void run() { buildOverlay(activity); }
        });
    }

    private static void buildOverlay(Activity activity) {
        // ── Root (full-screen transparent container) ───────────────────────────
        FrameLayout root = new FrameLayout(activity);

        // ── Floating trigger button ────────────────────────────────────────────
        final TextView fab = new TextView(activity);
        fab.setText("\u26A1");
        fab.setTextSize(22);
        fab.setTextColor(Color.WHITE);
        fab.setTypeface(null, Typeface.BOLD);
        fab.setBackgroundColor(0xDD005522);
        fab.setPadding(22, 14, 22, 14);
        fab.setGravity(Gravity.CENTER);

        // ── Panel container ────────────────────────────────────────────────────
        final LinearLayout panel = new LinearLayout(activity);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackgroundColor(0xEE0A0A0A);
        panel.setPadding(20, 16, 20, 20);
        panel.setVisibility(View.GONE);

        // Title bar
        TextView title = new TextView(activity);
        title.setText("\u26A1 TAURUS SHIELD");
        title.setTextColor(0xFF00FF88);
        title.setTextSize(15);
        title.setTypeface(null, Typeface.BOLD);
        title.setLetterSpacing(0.12f);
        panel.addView(title);

        // Subtitle
        TextView sub = new TextView(activity);
        sub.setText("Subway Surfers 3.62.1  \u2014  matrix-hook");
        sub.setTextColor(0xFF888888);
        sub.setTextSize(10);
        LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(-1, -2);
        subLp.setMargins(0, 2, 0, 12);
        panel.addView(sub, subLp);

        // Divider
        View div = new View(activity);
        div.setBackgroundColor(0xFF003311);
        LinearLayout.LayoutParams divLp = new LinearLayout.LayoutParams(-1, 2);
        divLp.setMargins(0, 0, 0, 12);
        panel.addView(div, divLp);

        // Scrollable feature list
        ScrollView scroll = new ScrollView(activity);
        LinearLayout featureList = new LinearLayout(activity);
        featureList.setOrientation(LinearLayout.VERTICAL);

        for (int i = 0; i < NAMES.length; i++) {
            final int id = i;
            final ToggleButton tb = new ToggleButton(activity);
            tb.setTextOn("\u2714  " + NAMES[i]);
            tb.setTextOff("\u2716  " + NAMES[i]);
            tb.setTextSize(12);
            tb.setTextColor(Color.WHITE);
            boolean initState = nativeGetState(id);
            tb.setChecked(initState);
            updateToggleBg(tb, initState);
            tb.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(android.widget.CompoundButton v, boolean checked) {
                    nativeToggle(id, checked);
                    updateToggleBg(tb, checked);
                }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.setMargins(0, 4, 0, 4);
            featureList.addView(tb, lp);
        }

        scroll.addView(featureList);
        LinearLayout.LayoutParams scrollLp = new LinearLayout.LayoutParams(-1, 0);
        scrollLp.weight = 1;
        scrollLp.setMargins(0, 0, 0, 12);
        panel.addView(scroll, scrollLp);

        // Bottom divider
        View div2 = new View(activity);
        div2.setBackgroundColor(0xFF003311);
        LinearLayout.LayoutParams div2Lp = new LinearLayout.LayoutParams(-1, 2);
        div2Lp.setMargins(0, 0, 0, 10);
        panel.addView(div2, div2Lp);

        // Close button
        Button closeBtn = new Button(activity);
        closeBtn.setText("\u2716  CLOSE MENU");
        closeBtn.setTextColor(Color.WHITE);
        closeBtn.setTextSize(12);
        closeBtn.setBackgroundColor(0xFF880011);
        closeBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                panel.setVisibility(View.GONE);
                gPanelVisible = false;
            }
        });
        panel.addView(closeBtn);

        // ── FAB click ──────────────────────────────────────────────────────────
        fab.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                gPanelVisible = !gPanelVisible;
                panel.setVisibility(gPanelVisible ? View.VISIBLE : View.GONE);
            }
        });

        // ── Position everything ────────────────────────────────────────────────
        int dp = (int)(activity.getResources().getDisplayMetrics().density);

        FrameLayout.LayoutParams fabLp = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT
        );
        fabLp.gravity = Gravity.TOP | Gravity.END;
        fabLp.setMargins(0, 90 * dp, 8 * dp, 0);

        FrameLayout.LayoutParams panelLp = new FrameLayout.LayoutParams(
            300 * dp, 460 * dp
        );
        panelLp.gravity = Gravity.TOP | Gravity.END;
        panelLp.setMargins(0, 145 * dp, 8 * dp, 0);

        root.addView(panel, panelLp);
        root.addView(fab, fabLp);

        activity.addContentView(root, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ));

        gPanel = panel;
    }

    private static void updateToggleBg(ToggleButton tb, boolean on) {
        tb.setBackgroundColor(on ? 0xFF003311 : 0xFF220000);
    }
}
