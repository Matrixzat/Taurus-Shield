const OWNER = "Matrixzat";
const REPO  = "Taurus-blutter-api";
const API   = `https://api.github.com/repos/${OWNER}/${REPO}`;
const UPLOAD = `https://uploads.github.com/repos/${OWNER}/${REPO}`;

function ghHeaders(token) {
  return {
    "Authorization": `token ${token}`,
    "Accept":        "application/vnd.github.v3+json",
    "User-Agent":    "TaurusShield-Worker/1.0"
  };
}

const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type"
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" }
  });
}

async function getOrCreateRelease(token) {
  const res = await fetch(`${API}/releases/tags/analyze-queue`, { headers: ghHeaders(token) });
  if (res.ok) return (await res.json()).id;

  const create = await fetch(`${API}/releases`, {
    method:  "POST",
    headers: { ...ghHeaders(token), "Content-Type": "application/json" },
    body: JSON.stringify({
      tag_name:   "analyze-queue",
      name:       "Analysis Queue",
      body:       "Temporary upload slot for Taurus Shield analysis. Files are auto-deleted.",
      draft:      false,
      prerelease: true
    })
  });
  if (!create.ok) return null;
  return (await create.json()).id;
}

async function uploadAndTrigger(request, token, workflowFile, extraInputs = {}, assetExt = 'zip') {
  const jobId     = Date.now().toString();
  const assetName = `job_${jobId}.${assetExt}`;

  const releaseId = await getOrCreateRelease(token);
  if (!releaseId) return json({ error: "Could not get upload release" }, 500);

  // Stream the body directly to GitHub without buffering it in the worker.
  // Buffering large APKs with request.arrayBuffer() hits Cloudflare's wall-clock
  // timeout (~60 s) on slow mobile connections; streaming avoids that entirely.
  const contentLength = request.headers.get("content-length");
  const uploadHeaders = {
    ...ghHeaders(token),
    "Content-Type": "application/zip",
  };
  if (contentLength) uploadHeaders["Content-Length"] = contentLength;

  const uploadRes = await fetch(
    `${UPLOAD}/releases/${releaseId}/assets?name=${encodeURIComponent(assetName)}`, {
      method:  "POST",
      headers: uploadHeaders,
      body:    request.body,   // ReadableStream — no buffering
      duplex:  "half"          // required by some runtimes for streaming uploads
    }
  );
  if (!uploadRes.ok) {
    return json({ error: "ZIP upload failed", detail: await uploadRes.text() }, 500);
  }
  const assetId = (await uploadRes.json()).id;

  const triggerRes = await fetch(`${API}/actions/workflows/${workflowFile}/dispatches`, {
    method:  "POST",
    headers: { ...ghHeaders(token), "Content-Type": "application/json" },
    body: JSON.stringify({
      ref:    "main",
      inputs: { asset_id: assetId.toString(), job_id: jobId, ...extraInputs }
    })
  });
  if (!triggerRes.ok) {
    await fetch(`${API}/releases/assets/${assetId}`, {
      method: "DELETE", headers: ghHeaders(token)
    });
    return json({ error: "Failed to trigger GitHub workflow" }, 500);
  }

  return json({ job_id: jobId, asset_id: assetId, triggered_at: Date.now() });
}

const GH_TOKEN = "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";

export default {
  async fetch(request, env, ctx) {
    const url   = new URL(request.url);
    const path  = url.pathname;
    const token = GH_TOKEN;

    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });

    // ── POST /analyze ────────────────────────────────────────────────────────
    if (path === "/analyze" && request.method === "POST") {
      return uploadAndTrigger(request, token, "analyze.yml");
    }

    // ── POST /dex2c ──────────────────────────────────────────────────────────
    if (path === "/dex2c" && request.method === "POST") {
      const sign = url.searchParams.get("sign") || "true";
      return uploadAndTrigger(request, token, "dex2c.yml", { sign_apk: sign });
    }

    // ── POST /dptshell ────────────────────────────────────────────────────────
    if (path === "/dptshell" && request.method === "POST") {
      const sign = url.searchParams.get("sign") || "true";
      return uploadAndTrigger(request, token, "dptshell.yml", { sign_apk: sign });
    }

    // ── POST /flutter-build ───────────────────────────────────────────────────
    if (path === "/flutter-build" && request.method === "POST") {
      return uploadAndTrigger(request, token, "flutter-build.yml");
    }

    // ── GET /find-run?after=<epoch_ms>&workflow=<file> ─────────────────────
    if (path === "/find-run" && request.method === "GET") {
      const afterMs  = parseInt(url.searchParams.get("after") || "0");
      const workflow = url.searchParams.get("workflow") || "analyze.yml";
      const minMs    = afterMs - 20000;

      const res = await fetch(
        `${API}/actions/workflows/${workflow}/runs?per_page=5&event=workflow_dispatch`,
        { headers: ghHeaders(token) }
      );
      if (!res.ok) return json({ found: false });

      const runs = (await res.json()).workflow_runs || [];
      for (const run of runs) {
        if (new Date(run.created_at).getTime() >= minMs) {
          return json({ found: true, run_id: run.id, run_number: run.run_number });
        }
      }
      return json({ found: false });
    }

    // ── GET /status?run_id=X ─────────────────────────────────────────────────
    if (path === "/status" && request.method === "GET") {
      const runId = url.searchParams.get("run_id");
      if (!runId) return json({ error: "run_id required" }, 400);

      const res = await fetch(`${API}/actions/runs/${runId}`, { headers: ghHeaders(token) });
      if (!res.ok) return json({ error: "Could not fetch run status" }, res.status);
      const data = await res.json();
      return json({ status: data.status, conclusion: data.conclusion, run_number: data.run_number });
    }

    // ── GET /artifact?run_id=X&job_id=Y&prefix=Z ─────────────────────────────
    if (path === "/artifact" && request.method === "GET") {
      const runId  = url.searchParams.get("run_id");
      const jobId  = url.searchParams.get("job_id");
      const prefix = url.searchParams.get("prefix") || "blutter";
      if (!runId || !jobId) return json({ error: "run_id and job_id required" }, 400);

      const listRes = await fetch(`${API}/actions/runs/${runId}/artifacts`, { headers: ghHeaders(token) });
      if (!listRes.ok) return json({ error: "Could not list artifacts" }, 500);

      const artifactName = `${prefix}-${jobId}`;
      const artifact = ((await listRes.json()).artifacts || [])
        .find(a => a.name === artifactName);
      if (!artifact) return json({ error: `Artifact ${artifactName} not found` }, 404);

      const dlRes = await fetch(`${API}/actions/artifacts/${artifact.id}/zip`, {
        headers:  ghHeaders(token),
        redirect: "manual"
      });
      const s3Url = dlRes.headers.get("location");

      const fileRes = await fetch(s3Url || `${API}/actions/artifacts/${artifact.id}/zip`, {
        headers: s3Url ? undefined : ghHeaders(token)
      });
      if (!fileRes.ok) return json({ error: "Artifact download failed" }, 500);

      // Delete artifact from GitHub in the background after serving it
      const artifactId = artifact.id;
      ctx.waitUntil(
        fetch(`${API}/actions/artifacts/${artifactId}`, {
          method: "DELETE", headers: ghHeaders(token)
        }).catch(() => {})
      );

      return new Response(fileRes.body, {
        headers: { ...CORS, "Content-Type": "application/zip" }
      });
    }

    // ── POST /cancel-run?run_id=X ─────────────────────────────────────────────
    if (path === "/cancel-run" && request.method === "POST") {
      const runId = url.searchParams.get("run_id");
      if (!runId) return json({ error: "run_id required" }, 400);

      const res = await fetch(`${API}/actions/runs/${runId}/cancel`, {
        method:  "POST",
        headers: ghHeaders(token)
      });
      if (res.status === 202 || res.status === 409) {
        return json({ ok: true, status: res.status });
      }
      return json({ error: "Failed to cancel run", status: res.status }, res.status);
    }

    // ── DELETE /asset?asset_id=X ─────────────────────────────────────────────
    if (path === "/asset" && request.method === "DELETE") {
      const assetId = url.searchParams.get("asset_id");
      if (!assetId) return json({ error: "asset_id required" }, 400);
      await fetch(`${API}/releases/assets/${assetId}`, {
        method: "DELETE", headers: ghHeaders(token)
      });
      return json({ ok: true });
    }

    // ── GET /job-live?run_id=X ────────────────────────────────────────────────
    if (path === "/job-live" && request.method === "GET") {
      const runId = url.searchParams.get("run_id");
      if (!runId) return json({ error: "run_id required" }, 400);

      const jobsRes = await fetch(`${API}/actions/runs/${runId}/jobs`, { headers: ghHeaders(token) });
      if (!jobsRes.ok) return json({ error: "Failed to fetch jobs" }, 500);
      const jobs = (await jobsRes.json()).jobs || [];
      if (jobs.length === 0) return json({ current_step: "Queued", steps: [] });

      const job = jobs.find(j => j.status === "in_progress")
              || jobs.find(j => j.status === "queued")
              || jobs[0];
      const steps = (job.steps || []).map(s => ({
        name: s.name,
        status: s.status,
        conclusion: s.conclusion || null
      }));

      const active = steps.find(s => s.status === "in_progress");
      const completed = steps.filter(s => s.status === "completed");
      const current = active ? active.name : (job.status === "queued" ? "Queued" : "Finishing");

      return json({
        current_step: current,
        completed_count: completed.length,
        total_steps: steps.length,
        steps: steps
      });
    }

    // ── GET /job-error?run_id=X ──────────────────────────────────────────────
    if (path === "/job-error" && request.method === "GET") {
      const runId = url.searchParams.get("run_id");
      if (!runId) return json({ error: "run_id required" }, 400);

      const jobsRes = await fetch(`${API}/actions/runs/${runId}/jobs`, { headers: ghHeaders(token) });
      if (!jobsRes.ok) return json({ error: "Failed to fetch jobs" }, 500);
      const failedJob = ((await jobsRes.json()).jobs || []).find(j => j.conclusion === "failure");
      if (!failedJob) return json({ error: "No failed job found" }, 404);

      const logRes = await fetch(`${API}/actions/jobs/${failedJob.id}/logs`, {
        headers: { ...ghHeaders(token), "Accept": "application/vnd.github.v3+json" },
        redirect: "manual"
      });
      const logUrl = logRes.headers.get("location");
      if (!logUrl) return json({ error: "Log URL unavailable" }, 500);

      const logText = await (await fetch(logUrl)).text();

      // Clean each line: strip timestamp + ANSI codes
      const cleaned = logText.split("\n")
        .map(l => l.replace(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\s*/, ""))
        .map(l => l.replace(/\x1b\[[0-9;]*m/g, "").replace(/\x1b\[[\x20-\x3f]*[\x40-\x7e]/g, ""))
        .map(l => l.trim());

      // Split into step sections using ##[group] / ##[endgroup] markers
      const sections = [];
      let cur = { name: "preamble", lines: [] };
      for (const l of cleaned) {
        if (l.startsWith("##[group]")) {
          if (cur.lines.length) sections.push(cur);
          cur = { name: l.replace("##[group]", "").trim(), lines: [] };
        } else if (l.startsWith("##[endgroup]")) {
          sections.push(cur);
          cur = { name: "", lines: [] };
        } else {
          cur.lines.push(l);
        }
      }
      if (cur.lines.length) sections.push(cur);

      // Drop noise lines within each section
      const clean = lines => lines.filter(l =>
        l.length > 0 &&
        !/^echo\s+['"]/.test(l) &&
        !/^##\[command\]/.test(l) &&
        !/^Run\s/.test(l)
      );

      // Find the section that contains the actual error
      const hasError = s => s.lines.some(l =>
        /error|fail|exception|unrecognized|invalid|traceback|not found|no such file|exit code [^0]/i.test(l)
      );

      const errorSection = [...sections].reverse().find(hasError);
      let output;
      if (errorSection) {
        const header = errorSection.name ? `[${errorSection.name}]\n` : "";
        const body = clean(errorSection.lines).slice(-30).join("\n");
        output = header + body;
      } else {
        // Fallback: last 25 cleaned lines from entire log
        const all = clean(sections.flatMap(s => s.lines));
        output = all.slice(-25).join("\n");
      }

      return new Response(output.slice(0, 2000), { headers: { ...CORS, "Content-Type": "text/plain" } });
    }

    // ── GET /prepare-upload?ext=apk|zip ──────────────────────────────────────
    // Creates a GitHub release slot and returns upload credentials so the phone
    // can upload large files DIRECTLY to GitHub, bypassing this Worker entirely
    // (avoids Cloudflare's ~60 s proxy timeout for large binary uploads).
    if (path === "/prepare-upload" && request.method === "GET") {
      const ext       = url.searchParams.get("ext") || "apk";
      const jobId     = Date.now().toString();
      const assetName = `job_${jobId}.${ext}`;

      const releaseId = await getOrCreateRelease(token);
      if (!releaseId) return json({ error: "Could not get upload release" }, 500);

      return json({
        job_id:     jobId,
        asset_name: assetName,
        upload_url: `${UPLOAD}/releases/${releaseId}/assets`,
        auth:       `token ${token}`,
      });
    }

    // ── GET /dispatch-job?workflow=X&asset_id=Y&job_id=Z&... ─────────────────
    // Called by the phone after it has uploaded its asset directly to GitHub.
    // Triggers the GitHub Actions workflow and cleans up the asset on failure.
    if (path === "/dispatch-job" && request.method === "GET") {
      const workflow = url.searchParams.get("workflow");
      const assetId  = url.searchParams.get("asset_id");
      const jobId    = url.searchParams.get("job_id");
      if (!workflow || !assetId || !jobId) return json({ error: "Missing params" }, 400);

      const extraInputs = {};
      for (const [key, val] of url.searchParams.entries()) {
        if (!["workflow", "asset_id", "job_id"].includes(key)) extraInputs[key] = val;
      }

      const triggerRes = await fetch(`${API}/actions/workflows/${workflow}/dispatches`, {
        method:  "POST",
        headers: { ...ghHeaders(token), "Content-Type": "application/json" },
        body:    JSON.stringify({
          ref:    "main",
          inputs: { asset_id: assetId, job_id: jobId, ...extraInputs }
        })
      });

      if (!triggerRes.ok) {
        const ghErr = await triggerRes.text().catch(() => "");
        await fetch(`${API}/releases/assets/${assetId}`, {
          method: "DELETE", headers: ghHeaders(token)
        });
        return json({ error: "Failed to trigger workflow", github_status: triggerRes.status, github_error: ghErr }, 500);
      }

      return json({ ok: true, triggered_at: Date.now() });
    }

    // ── POST /ads-patch ───────────────────────────────────────────────────────
    // Streams the uploaded APK directly to GitHub then triggers ads-patch.yml.
    if (path === "/ads-patch" && request.method === "POST") {
      const patchLevel = url.searchParams.get("patch_level") || "advance";
      const signApk    = url.searchParams.get("sign_apk")    || "true";
      return uploadAndTrigger(request, token, "ads-patch.yml",
        { patch_level: patchLevel, sign_apk: signApk }, "apk");
    }

    // ── GET /patch-script ─────────────────────────────────────────────────────
    // Returns a Node.js patch script with embedded regex patterns.
    // Used by ads-patch.yml to apply smali bytecode patches without exposing
    // the regex logic in the public repository.
    if (path === "/patch-script" && request.method === "GET") {
      const script = buildPatchScript();
      return new Response(script, {
        status: 200,
        headers: { ...CORS, "Content-Type": "application/javascript" }
      });
    }

    // ── POST /anti-killer ─────────────────────────────────────────────────────
    if (path === "/anti-killer" && request.method === "POST") {
      const mainActivity = url.searchParams.get("main_activity") || "";
      const signApk      = url.searchParams.get("sign_apk")      || "true";
      return uploadAndTrigger(request, token, "anti-killer.yml",
        { main_activity: mainActivity, sign_apk: signApk }, "apk");
    }

    // ── GET /anti-killer-dex ──────────────────────────────────────────────────
    // Serves the pre-compiled AntiDialogKiller DEX binary.
    if (path === "/anti-killer-dex" && request.method === "GET") {
      const dexB64 = ANTI_KILLER_DEX_B64;
      const dexBytes = Uint8Array.from(atob(dexB64), c => c.charCodeAt(0));
      return new Response(dexBytes.buffer, {
        status: 200,
        headers: { ...CORS, "Content-Type": "application/octet-stream",
                   "Content-Disposition": "attachment; filename=anti_dialog_killer.dex" }
      });
    }

    // ── GET /anti-killer-script ───────────────────────────────────────────────
    // Returns the Node.js hook-injection script used by anti-killer.yml.
    if (path === "/anti-killer-script" && request.method === "GET") {
      const script = buildAntiKillerScript();
      return new Response(script, {
        status: 200,
        headers: { ...CORS, "Content-Type": "application/javascript" }
      });
    }

    return new Response("Not found.", { status: 404, headers: CORS });
  }
};

// ─────────────────────────────────────────────────────────────────────────────
// Patch script builder — returns the full Node.js source with embedded patterns
// ─────────────────────────────────────────────────────────────────────────────
function buildPatchScript() {
  return `#!/usr/bin/env node
'use strict';

const fs   = require('fs');
const path = require('path');

const PATCH_LEVEL = (process.env.PATCH_LEVEL || 'advance').toLowerCase();
const ROOT_DIR    = process.argv[2] || 'decompiled';

if (!fs.existsSync(ROOT_DIR)) {
  console.error('ERROR: directory not found:', ROOT_DIR);
  process.exit(1);
}

console.log('Ads patch engine starting — level: ' + PATCH_LEVEL);

// ── Helpers ─────────────────────────────────────────────────────────────────

function walkDir(dir, cb) {
  try {
    if (!fs.existsSync(dir)) return;
    for (const f of fs.readdirSync(dir)) {
      const full = path.join(dir, f);
      try {
        if (fs.statSync(full).isDirectory()) walkDir(full, cb);
        else cb(full, f);
      } catch (e) {}
    }
  } catch (e) {}
}

function walkSmali(baseDir, cb) {
  try {
    for (const entry of fs.readdirSync(baseDir)) {
      if (entry.startsWith('smali')) walkDir(path.join(baseDir, entry), cb);
    }
  } catch (e) {}
}

// ── Step 1: AdsActivity if-eqz → if-nez (ALWAYS, every level) ───────────────
// Search by filename: any .smali file whose name contains "adsactivity" or
// "adactivity" (case-insensitive). Replace ALL if-eqz with if-nez inside it.

let adActivityFiles = [];
let adActivityPatches = 0;

walkSmali(ROOT_DIR, (filePath, fileName) => {
  const lower = fileName.toLowerCase();
  if (fileName.endsWith('.smali') &&
      (lower.includes('adsactivity') || lower.includes('adactivity'))) {
    adActivityFiles.push(filePath);
  }
});

for (const filePath of adActivityFiles) {
  try {
    const original = fs.readFileSync(filePath, 'utf8');
    const patched  = original.replace(/if-eqz/g, 'if-nez');
    if (patched !== original) {
      fs.writeFileSync(filePath, patched);
      adActivityPatches += (original.match(/if-eqz/g) || []).length;
    }
  } catch (e) {}
}

console.log('AdsActivity files found: ' + adActivityFiles.length + ', if-eqz patches: ' + adActivityPatches);

// ── Step 2: Layout XML — set ad view dimensions to 0dp (ALWAYS) ─────────────

const AD_VIEW_PATTERNS = [
  /AdView/i, /BannerView/i, /NativeAdView/i, /NativeExpressAdView/i,
  /UnifiedNativeAdView/i, /com\\.google\\.android\\.gms\\.ads/i,
  /com\\.facebook\\.ads/i, /com\\.mopub/i, /com\\.applovin/i,
  /com\\.unity3d\\.ads/i, /com\\.vungle/i, /com\\.ironsource/i,
  /com\\.chartboost/i, /com\\.inmobi/i, /com\\.startapp/i,
  /com\\.tapjoy/i, /com\\.adcolony/i, /AdMobView/i,
  /AdContainer/i, /adContainer/i, /ad_container/i,
  /adBanner/i, /ad_banner/i, /bannerAd/i, /banner_ad/i,
  /adFrame/i, /ad_frame/i, /adLayout/i, /ad_layout/i,
  /adWrapper/i, /ad_wrapper/i, /nativeAd/i, /native_ad/i
];

const VISIBILITY_PATTERNS = [
  /ad_container/i, /adContainer/i, /ad_banner/i,
  /adBanner/i, /banner_container/i, /bannerContainer/i
];

let layoutFilesPatched = 0;
let layoutPatches = 0;

function patchLayoutXml(filePath) {
  try {
    let content  = fs.readFileSync(filePath, 'utf8');
    const orig   = content;
    let count    = 0;
    let hasAd    = AD_VIEW_PATTERNS.some(p => p.test(content));
    if (!hasAd) return 0;

    for (const p of AD_VIEW_PATTERNS) {
      const src = p.source;
      content = content.replace(
        new RegExp('(<[^>]*(?:' + src + ')[^>]*)(android:layout_width="[^"]*")([^>]*)(android:layout_height="[^"]*")([^>]*/?>)', 'gi'),
        (m, a, b, c, d, e) => { count++; return a + 'android:layout_width="0dp"' + c + 'android:layout_height="0dp"' + e; }
      );
      content = content.replace(
        new RegExp('(<[^>]*(?:' + src + ')[^>]*)(android:layout_height="[^"]*")([^>]*)(android:layout_width="[^"]*")([^>]*/?>)', 'gi'),
        (m, a, b, c, d, e) => { count++; return a + 'android:layout_height="0dp"' + c + 'android:layout_width="0dp"' + e; }
      );
    }
    for (const p of VISIBILITY_PATTERNS) {
      content = content.replace(
        new RegExp('(<[^>]+android:id="@\\\\+id/[^"]*(?:' + p.source + ')[^"]*"[^>]*)(/?>)', 'gi'),
        (m, a, b) => {
          if (!m.includes('android:visibility=')) { count++; return a + ' android:visibility="gone"' + b; }
          return m;
        }
      );
    }
    if (count > 0 && content !== orig) {
      fs.writeFileSync(filePath, content);
      return count;
    }
    return 0;
  } catch (e) { return 0; }
}

try {
  const resDir = path.join(ROOT_DIR, 'res');
  if (fs.existsSync(resDir)) {
    for (const entry of fs.readdirSync(resDir)) {
      if (entry.startsWith('layout')) {
        walkDir(path.join(resDir, entry), (fp, fn) => {
          if (fn.endsWith('.xml')) {
            const n = patchLayoutXml(fp);
            if (n > 0) { layoutPatches += n; layoutFilesPatched++; }
          }
        });
      }
    }
  }
} catch (e) {}

console.log('Layout XML files patched: ' + layoutFilesPatched + ' (' + layoutPatches + ' patches)');

// ── Step 3: Asset config files — neutralize ad URLs/IDs (ALWAYS) ─────────────

let configFilesPatched = 0;

function patchAssets(baseDir) {
  try {
    const assetsDir = path.join(baseDir, 'assets');
    if (!fs.existsSync(assetsDir)) return;
    walkDir(assetsDir, (fp, fn) => {
      if (!fn.endsWith('.json') && !fn.endsWith('.xml') && !fn.endsWith('.txt')) return;
      try {
        const orig    = fs.readFileSync(fp, 'utf8');
        let content   = orig;
        content = content.replace(/(https?:\\/\\/[^"'\\s]*(?:admob|adsdk|adcolony|applovin|ironsource|vungle|chartboost|inmobi|mopub|tapjoy|unityads|startapp)[^"'\\s]*)/gi, 'http://127.0.0.1');
        content = content.replace(/ca-app-pub-\\d{16}[~\\/]\\d{10}/g, 'ca-app-pub-0000000000000000~0000000000');
        if (content !== orig) { fs.writeFileSync(fp, content); configFilesPatched++; }
      } catch (e) {}
    });
  } catch (e) {}
}

patchAssets(ROOT_DIR);
console.log('Asset config files patched: ' + configFilesPatched);

// ── Step 4: Boolean ad-check method patches (ALWAYS) ─────────────────────────

let boolPatches = 0;

walkSmali(ROOT_DIR, (fp, fn) => {
  if (!fn.endsWith('.smali')) return;
  try {
    const orig  = fs.readFileSync(fp, 'utf8');
    let content = orig;
    content = content.replace(
      /(\\.method[\\s\\S]*?(?:shouldShowAd|showAd|isAdEnabled|hasAds|adsEnabled|canShowAd|isAdReady|isAdLoaded).*\\)Z[\\s\\S]*?const\\/4\\s+v\\d+,\\s+0x1[\\s\\S]*?return\\s+v\\d+)/gi,
      m => m.replace(/const\\/4(\\s+v\\d+,\\s+)0x1/, 'const/4$10x0')
    );
    content = content.replace(
      /(\\.method[\\s\\S]*?(?:isPremium|isAdFree|isProUser|isVip|hasPurchased|isSubscribed).*\\)Z[\\s\\S]*?const\\/4\\s+v\\d+,\\s+0x0[\\s\\S]*?return\\s+v\\d+)/gi,
      m => m.replace(/const\\/4(\\s+v\\d+,\\s+)0x0/, 'const/4$10x1')
    );
    if (content !== orig) { fs.writeFileSync(fp, content); boolPatches++; }
  } catch (e) {}
});

console.log('Boolean method files patched: ' + boolPatches);

// ── Step 5: Interstitial/Rewarded ad NOP (ALWAYS) ────────────────────────────

let interstitialPatches = 0;

walkSmali(ROOT_DIR, (fp, fn) => {
  if (!fn.endsWith('.smali')) return;
  try {
    const orig  = fs.readFileSync(fp, 'utf8');
    let content = orig;
    content = content.replace(/invoke-virtual\\s*\\{[^}]+\\},\\s*L[^;]*InterstitialAd;->show\\([^)]*\\)V/gi, 'nop');
    content = content.replace(/invoke-virtual\\s*\\{[^}]+\\},\\s*L[^;]*RewardedAd;->show\\([^)]*\\)V/gi, 'nop');
    content = content.replace(/invoke-virtual\\s*\\{[^}]+\\},\\s*L[^;]*RewardedInterstitialAd;->show\\([^)]*\\)V/gi, 'nop');
    content = content.replace(/invoke-static\\s*\\{[^}]+\\},\\s*L[^;]*(?:InterstitialAd|RewardedAd|RewardedInterstitialAd);->load\\([^)]*\\)V/gi, 'nop');
    content = content.replace(/invoke-static\\s*\\{[^}]+\\},\\s*Lcom\\/google\\/android\\/gms\\/ads\\/MobileAds;->initialize\\([^)]*\\)V/gi, 'nop');
    if (content !== orig) { fs.writeFileSync(fp, content); interstitialPatches++; }
  } catch (e) {}
});

console.log('Interstitial/rewarded files patched: ' + interstitialPatches);

// ── Step 6: Level-specific regex patches ─────────────────────────────────────

const PATCH_LEVELS = {
  basic: [
    {
      name: 'Load/Render Ad Methods',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?((loadAd|renderAd|Ad(Clicked|Dismissed|Shown))\\(.*\\)V\\n\\s+\\.registers \\d+))[\\s\\S]*?(?:return-void|[\\s\\S]*?throw.*)?(?:\\s+\\.end method)/g,
      replacement: '$1\\nreturn-void\\n.end method'
    },
    {
      name: 'Load Ad Boolean',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?loadAd\\(.*\\)Z)/g,
      replacement: '$1\\n    .registers 2\\n\\n    const/4 v0, 0x0\\n\\n    return v0\\n.end method'
    }
  ],
  low: [
    {
      name: 'Load/Render Ad Methods',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?((loadAd|renderAd|Ad(Clicked|Dismissed|Shown))\\(.*\\)V\\n\\s+\\.registers \\d+))[\\s\\S]*?(?:return-void|[\\s\\S]*?throw.*)?(?:\\s+\\.end method)/g,
      replacement: '$1\\nreturn-void\\n.end method'
    },
    {
      name: 'Load Ad Boolean',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?loadAd\\(.*\\)Z)/g,
      replacement: '$1\\n    .registers 2\\n\\n    const/4 v0, 0x0\\n\\n    return v0\\n.end method'
    },
    {
      name: 'GMS Ad Invokes',
      pattern: /(invoke.*gms.*>(loadUrl|loadDataWithBaseURL|requestInterstitialAd|showInterstitial|showVideo|showAd|loadData|onAdClicked|onAdLoaded|isLoading|loadAds|AdLoader|AdRequest|AdListener|AdView).*V)|(((invoke.*\\/ads\\/.*>((load|show)(Ad(s)?)?))\\(.*\\)V)|(invoke.*loadAd\\(.*\\)[VZ]))/g,
      replacement: '#$0'
    }
  ],
  mid: [
    {
      name: 'Load/Render Ad Methods',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?((loadAd|renderAd|Ad(Clicked|Dismissed|Shown))\\(.*\\)V\\n\\s+\\.registers \\d+))[\\s\\S]*?(?:return-void|[\\s\\S]*?throw.*)?(?:\\s+\\.end method)/g,
      replacement: '$1\\nreturn-void\\n.end method'
    },
    {
      name: 'Load Ad Boolean',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?loadAd\\(.*\\)Z)/g,
      replacement: '$1\\n    .registers 2\\n\\n    const/4 v0, 0x0\\n\\n    return v0\\n.end method'
    },
    {
      name: 'GMS Ad Invokes',
      pattern: /(invoke.*gms.*>(loadUrl|loadDataWithBaseURL|requestInterstitialAd|showInterstitial|showVideo|showAd|loadData|onAdClicked|onAdLoaded|isLoading|loadAds|AdLoader|AdRequest|AdListener|AdView).*V)|(((invoke.*\\/ads\\/.*>((load|show)(Ad(s)?)?))\\(.*\\)V)|(invoke.*loadAd\\(.*\\)[VZ]))/g,
      replacement: '#$0'
    },
    {
      name: 'Ad URL Strings',
      pattern: /"(http.*|\\/\\/.*)(61\\.145\\.124\\.238|\\-ads\\.|\\-ads\\.|\\.(ad|ads|analytics\\.localytics|mobfox|mp\\.mydas|plus1\\.wapstart|scorecardresearch|startappservice)\\.|(\\/ad\\.|\\/ads)|ad\\-mail|ad\\.*\\_logging|adcolony|adkmob|admax|admob|admost|adsafeprotected|adservice|adtag|advert|adwhirl|amazon\\-*ads|amazon\\..*ads|amobee|analytics|applovin|applvn|appnext|appodeal|burstly|cauly|cloudfront|crashlytics|crispwireless|doubleclick|duapps|flurry|googlesyndication|googletagmanager|greystripe|gstatic|inmobi|inneractive|jumptag|millennialmedia|moatads|mopub|native\\_ads|pagead|pubnative|smaato|supersonicads|tapas|tapjoy|unityads|vungle|zucks).*"/g,
      replacement: '"127.0.0.1"'
    },
    {
      name: 'AdMob Pub IDs',
      pattern: /ca-app-pub-\\d{16}\\/\\d{10}/g,
      replacement: 'ca-app-pub-0000000000000000/0000000000'
    }
  ],
  advance: [
    {
      name: 'Load/Render Ad Methods',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?((loadAd|renderAd|Ad(Clicked|Dismissed|Shown))\\(.*\\)V\\n\\s+\\.registers \\d+))[\\s\\S]*?(?:return-void|[\\s\\S]*?throw.*)?(?:\\s+\\.end method)/g,
      replacement: '$1\\nreturn-void\\n.end method'
    },
    {
      name: 'Load Ad Boolean',
      pattern: /(\\.method\\s(public|private|static)\\s\\b(?!\\babstract|native\\b)(.*)?loadAd\\(.*\\)Z)/g,
      replacement: '$1\\n    .registers 2\\n\\n    const/4 v0, 0x0\\n\\n    return v0\\n.end method'
    },
    {
      name: 'GMS Ad Invokes',
      pattern: /(invoke.*gms.*>(loadUrl|loadDataWithBaseURL|requestInterstitialAd|showInterstitial|showVideo|showAd|loadData|onAdClicked|onAdLoaded|isLoading|loadAds|AdLoader|AdRequest|AdListener|AdView).*V)|(((invoke.*\\/ads\\/.*>((load|show)(Ad(s)?)?))\\(.*\\)V)|(invoke.*loadAd\\(.*\\)[VZ]))/g,
      replacement: '#$0'
    },
    {
      name: 'SDK Invoke Void NOP',
      pattern: /(invoke(?!.*(close|Deactiv|Destroy|Dismiss|Disabl|error|player|remov|expir|fail|hide|skip|stop|Throw)).*\\/(adcolony|admob|ads|adsdk|aerserv|appbrain|applovin|appodeal|appodealx|appsflyer|bytedance\\/sdk\\/openadsdk|chartboost|flurry|fyber|hyprmx|inmobi|ironsource|mbrg|mbridge|mintegral|moat|mobfox|mobilefuse|mopub|my\\/target|ogury|Omid|onesignal|presage|smaato|smartadserver|snap\\/adkit|snap\\/appadskit|startapp|taboola|tapjoy|tappx|vungle)\\/.*>(request.*|(.*(activat|Banner|build|Event|exec|header|html|initAd|initi|JavaScript|Interstitial|load|log|MetaData|metri|Native|onAd|propert|report|response|Rewarded|show|trac|url|(fetch|refresh|render|video)Ad).*)|.*Request)\\(.*\\)V)/g,
      replacement: 'nop'
    },
    {
      name: 'SDK Invoke Boolean',
      pattern: /(invoke(?!.*(close|Deactiv|Destroy|Dismiss|Disabl|error|player|remov|expir|fail|hide|skip|stop|Throw)).*\\/(adcolony|admob|ads|adsdk|aerserv|appbrain|applovin|appodeal|appodealx|appsflyer|bytedance\\/sdk\\/openadsdk|chartboost|flurry|fyber|hyprmx|inmobi|ironsource|mbrg|mbridge|mintegral|moat|mobfox|mobilefuse|mopub|my\\/target|ogury|Omid|onesignal|presage|smaato|smartadserver|snap\\/adkit|snap\\/appadskit|startapp|taboola|tapjoy|tappx|vungle)\\/.*>(request.*|(.*(activat|Banner|build|Event|exec|header|html|initAd|initi|JavaScript|Interstitial|load|log|MetaData|metri|Native|(can|get|is|has|was)Ad|propert|report|response|Rewarded|show|trac|url|(fetch|refresh|render|video)Ad).*)|.*Request)\\(.*\\)Z\\n\\n\\s{4})move-result\\s([pv]\\d+)/g,
      replacement: 'const/4 $9, 0x0'
    },
    {
      name: 'Extended Ad URLs',
      pattern: /"(http.*|\\/\\/.*)(61\\.145\\.124\\.238|\\/2mdn\\.net|-ads\\.|\\.(5rocks|ad|adadapted|admitad|admost|ads|aerserv|airpush|batmobil|chartboost|cloudmobi|conviva|dov-e|fyber|mng-ads|mydas|predic|talkingdata|tapdaq|tele\\.fm|unity3d|unity|wapstart|xdrig|zapr)\\.|\\/ad\\.|\\/ads|a4\\.tl|accengage|ad4push|ad4screen|ad-mail|adbuddiz|adc3-launch|adcolony|adfurikun|adincube|adinformation|adkmob|admax|admixer|admob|admost|adsmogo|adsrvr|adswizz|adtag|adtech\\.de|advert|adwhirl|adz\\.wattpad|alimama|alta\\.eqmob|amazon-.*ads|amazon\\..*ads|amobee|analytics|anvato|appboy|appbrain|applovin|applvn|appmetrica|appnext|appodeal|appsdt|appsflyer|apsalar|avocarrot|axonix|brightcove|burstly|cauly|cloudfront|cmcm|comscore|crashlytics|crispwireless|criteo|doubleclick|duapps|dummy|flurry|fwmrm|gad|getads|gimbal|glispa|google\\.com\\/dfp|googleads|googleapis\\..*\\.ad-.*|googlesyndication|googletagmanager|greystripe|gstatic|heyzap|hyprmx|inmobi|inneractive|instreamatic|integralads|jumptag|kochava|localytics|madnet|mapbox|media\\.net|millennialmedia|mixpanel|mng-ads\\.com|moatads|mobclix|mobfox|mopub|native_ads|nexage|ooyala|openx|pagead|prebid|presage\\.io|pubmatic|pubnative|rayjump|saspreview|scorecardresearch|smaato|smartadserver|sponsorpay|startappservice|supersonicads|taboola|tapas|tapjoy|teads|umeng|unityads|vungle|zucks).*"/g,
      replacement: '"127.0.0.1"'
    }
  ]
};

// Build regexes for the selected level (same dedup logic as original)
let regexesToUse;
if (PATCH_LEVEL === 'all') {
  const combined = [
    ...PATCH_LEVELS.basic,
    ...PATCH_LEVELS.low,
    ...PATCH_LEVELS.mid,
    ...PATCH_LEVELS.advance
  ];
  const seen = new Set();
  regexesToUse = combined.filter(r => {
    if (seen.has(r.name)) return false;
    seen.add(r.name); return true;
  });
} else {
  regexesToUse = PATCH_LEVELS[PATCH_LEVEL] || PATCH_LEVELS.basic;
}

console.log('Applying ' + regexesToUse.length + ' level-specific patterns (' + PATCH_LEVEL + ')...');

let filesScanned = 0;
let filesPatched = 0;
let totalChanges = 0;

walkSmali(ROOT_DIR, (filePath, fileName) => {
  if (!fileName.endsWith('.smali')) return;
  filesScanned++;
  try {
    let content = fs.readFileSync(filePath, 'utf8');
    let changed = false;
    for (const r of regexesToUse) {
      try {
        const before = content;
        if (r.replacement.includes('$')) {
          content = content.replace(r.pattern, (match, ...groups) => {
            let result = r.replacement;
            groups.forEach((g, i) => {
              if (g !== undefined) result = result.replace(new RegExp('\\\\$' + (i + 1), 'g'), g);
            });
            totalChanges++;
            return result;
          });
        } else {
          const before2 = content;
          content = content.replace(r.pattern, () => { totalChanges++; return r.replacement; });
        }
        if (content !== before) changed = true;
      } catch (err) {
        console.log('Regex error in ' + r.name + ': ' + err.message);
      }
    }
    if (changed) {
      fs.writeFileSync(filePath, content);
      filesPatched++;
    }
  } catch (e) {}
});

// ── Summary ─────────────────────────────────────────────────────────────────

console.log('Smali files scanned: ' + filesScanned);
console.log('Smali files patched: ' + filesPatched + ' (' + totalChanges + ' pattern matches)');
console.log('Patch engine finished successfully');
`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Anti-Dialog Killer DEX (base64-encoded)
// ─────────────────────────────────────────────────────────────────────────────
const ANTI_KILLER_DEX_B64 = "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S5pLLTwgaT8CcR08AgwdHj0AAAABAAAAAgAAAAEAAAAQAAAAAQAAAB4AAAACAAAAEAABAAEAAAAXAAAAAQAAAAAAAAACAAAAEAAfAAEAAAABAAAAAwAAAAEAEwAVAAAAAwAAAB4AAQABAAAAAgAAAB4AEAABAAAADgAEJTAyeAAELmRleAAIPGNsaW5pdD4ABjxpbml0PgADQUVTABRBRVMvQ0JDL1BLQ1M1UGFkZGluZwAGQUVTX0lWAAdBRVNfS0VZABNBbmRyb2lkTWFuaWZlc3QueG1sABVBbnRpRGlhbG9nS2lsbGVyLmphdmEAAUIAAUkAAklMABJLSUxMRVJfQVVUSE9SSVRJRVMADktJTExFUl9DTEFTU0VTAAFMAAJMQgACTEwAA0xMSQADTExMABlMYW5kcm9pZC9jb250ZW50L0NvbnRleHQ7ACRMYW5kcm9pZC9jb250ZW50L3BtL0FwcGxpY2F0aW9uSW5mbzsAI0xhbmRyb2lkL2NvbnRlbnQvcG0vUGFja2FnZU1hbmFnZXI7ACFMYW5kcm9pZC9jb250ZW50L3BtL1Byb3ZpZGVySW5mbzsAIkxhbmRyb2lkL2NvbnRlbnQvcmVzL0Fzc2V0TWFuYWdlcjsAFExhbmRyb2lkL29zL1Byb2Nlc3M7ACpMY29tL2V4cGlyZS9kaWFsb2cvZ3VhcmQvQW50aURpYWxvZ0tpbGxlcjsAFUxqYXZhL2lvL0lucHV0U3RyZWFtOwAQTGphdmEvbGFuZy9CeXRlOwARTGphdmEvbGFuZy9DbGFzczsAIkxqYXZhL2xhbmcvQ2xhc3NOb3RGb3VuZEV4Y2VwdGlvbjsAE0xqYXZhL2xhbmcvSW50ZWdlcjsAEkxqYXZhL2xhbmcvT2JqZWN0OwATTGphdmEvbGFuZy9SdW50aW1lOwASTGphdmEvbGFuZy9TdHJpbmc7ABlMamF2YS9sYW5nL1N0cmluZ0J1aWxkZXI7ABJMamF2YS9sYW5nL1N5c3RlbTsAE0xqYXZhL3NlY3VyaXR5L0tleTsAHUxqYXZhL3NlY3VyaXR5L01lc3NhZ2VEaWdlc3Q7ACtMamF2YS9zZWN1cml0eS9zcGVjL0FsZ29yaXRobVBhcmFtZXRlclNwZWM7ABdMamF2YS91dGlsL0VudW1lcmF0aW9uOwAYTGphdmEvdXRpbC96aXAvWmlwRW50cnk7ABdMamF2YS91dGlsL3ppcC9aaXBGaWxlOwAVTGphdmF4L2NyeXB0by9DaXBoZXI7ACNMamF2YXgvY3J5cHRvL3NwZWMvSXZQYXJhbWV0ZXJTcGVjOwAhTGphdmF4L2NyeXB0by9zcGVjL1NlY3JldEtleVNwZWM7AAdTSEEtMjU2AAVVVEYtOAABVgACVkkABFZJTEwAAlZMAARWTElJAANWTEwAAVoAAlpMAAJbQgATW0xqYXZhL2xhbmcvT2JqZWN0OwATW0xqYXZhL2xhbmcvU3RyaW5nOwAJYWtfZGMuZGF0AAlha19taC5kYXQABmFwcGVuZAAJYXZhaWxhYmxlAAVjaGVjawAFY2xvc2UAHmNvbS5hYW50aWsua2lsbGVyLkRpYWxvZ0tpbGxlcgAcY29tLmFhbnRpay5raWxsZXIuSG9va0RpYWxvZwAXY29tLmFhbnRpay5raWxsZXIuZ2V0Q3gAFmNvbS5hYW50aWsua2lsbGVyLmluaXQAFmNvbS5kaWFsb2cua2lsbGVyLk1haW4AIGNvbS5raWxsZXIuZGlhbG9nLktpbGxlclByb3ZpZGVyABZjb20ua2lsbGVyLmRpYWxvZy5pbml0ABNjb21wdXRlTWFuaWZlc3RIYXNoAAhjcmFzaE5vdwAKZGVjcnlwdEFFUwAWZGlhbG9nLmtpbGxlci5wcm92aWRlcgAGZGlnZXN0AAdkb0ZpbmFsAAhlbmRzV2l0aAAHZW50cmllcwAGZXF1YWxzAARleGl0AAdmb3JOYW1lAAZmb3JtYXQAEmdldEFwcGxpY2F0aW9uSW5mbwAJZ2V0QXNzZXRzAAhnZXRFbnRyeQAOZ2V0SW5wdXRTdHJlYW0AC2dldEluc3RhbmNlAAdnZXROYW1lABFnZXRQYWNrYWdlTWFuYWdlcgAKZ2V0UnVudGltZQAEaGFsdAAPaGFzTW9yZUVsZW1lbnRzAARpbml0AAtpc0RpcmVjdG9yeQAHaXNFbXB0eQALa2lsbFByb2Nlc3MABmxlbmd0aAAFbXlQaWQAC25leHRFbGVtZW50AARvcGVuAAhwYXJzZUludAAEcmVhZAAScmVhZFN0b3JlZERleENvdW50AA5yZWFkU3RvcmVkSGFzaAAWcmVzb2x2ZUNvbnRlbnRQcm92aWRlcgAJc291cmNlRGlyAAtzdGF0aWNDaGVjawAIdG9TdHJpbmcABHRyaW0ABnVwZGF0ZQAHdmFsdWVPZgAOdmVyaWZ5RGV4Q291bnQAF3ZlcmlmeU1hbmlmZXN0SW50ZWdyaXR5AG9+fkQ4eyJiYWNrZW5kIjoiZGV4IiwiY29tcGlsYXRpb24tbW9kZSI6ImRlYnVnIiwiaGFzLWNoZWNrc3VtcyI6ZmFsc2UsIm1pbi1hcGkiOjEsInZlcnNpb24iOiIzLjMuMjAtZGV2K2Fvc3A1In0ABAALAAEaARoBGgEaB4iABKQSAYGABOQTAQn8EwEK5A0BCogWAQrcEAEK9AwBCswRAQmQFwEK1BcBCuQZAAAAAAAAAA4AAAAAAAAAAQAAAAAAAAABAAAAdAAAAHAAAAACAAAAIQAAAEACAAADAAAAJAAAAMQCAAAEAAAABQAAAHQEAAAFAAAANwAAAJwEAAAGAAAAAQAAAFQGAAABIAAACwAAAHQGAAADIAAACwAAAFMNAAABEAAADAAAACQOAAACIAAAdAAAAIoOAAAAIAAAAQAAAO0VAAADEAAAAQAAACwWAAAAEAAAAQAAADAWAAA=";

// ─────────────────────────────────────────────────────────────────────────────
// Anti-Killer injection script builder
// ─────────────────────────────────────────────────────────────────────────────
function buildAntiKillerScript() {
  return `#!/usr/bin/env node
'use strict';

const fs   = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const DECOMPILED   = process.argv[2] || 'decompiled';
const DEX_FILE     = process.argv[3] || 'anti_dialog_killer.dex';
const MAIN_ACT_ENV = (process.env.MAIN_ACTIVITY || '').trim();
const BAKSMALI_JAR = process.env.BAKSMALI_JAR   || 'baksmali.jar';

const HOOK = 'invoke-static {p0}, Lcom/expire/dialog/guard/AntiDialogKiller;->check(Landroid/content/Context;)V';

if (!fs.existsSync(DECOMPILED)) {
  console.error('ERROR: decompiled directory not found:', DECOMPILED); process.exit(1);
}
if (!fs.existsSync(DEX_FILE)) {
  console.error('ERROR: DEX file not found:', DEX_FILE); process.exit(1);
}

// ── Parse AndroidManifest.xml ──────────────────────────────────────────────

const manifestPath = path.join(DECOMPILED, 'AndroidManifest.xml');
if (!fs.existsSync(manifestPath)) {
  console.error('ERROR: AndroidManifest.xml not found'); process.exit(1);
}
const manifest = fs.readFileSync(manifestPath, 'utf8');

const pkgMatch = manifest.match(/package="([^"]+)"/);
if (!pkgMatch) { console.error('ERROR: package not found in manifest'); process.exit(1); }
const PKG = pkgMatch[1];
console.log('Package:', PKG);

function resolveClass(name) {
  if (!name) return null;
  if (name.startsWith('.')) return PKG + name;
  return name;
}

// Application class
let appClass = null;
const appMatch = manifest.match(/<application[^>]*android:name="([^"]+)"/);
if (appMatch) appClass = resolveClass(appMatch[1]);
console.log('Application class:', appClass || '(not found)');

// Main activity (env override or manifest MAIN intent-filter)
let mainActivity = MAIN_ACT_ENV || null;
if (!mainActivity) {
  const activityBlocks = [...manifest.matchAll(/<activity[^>]*android:name="([^"]+)"[\\s\\S]*?<\\/activity>/g)];
  for (const block of activityBlocks) {
    if (block[0].includes('android.intent.action.MAIN')) {
      mainActivity = resolveClass(block[1]); break;
    }
  }
  if (!mainActivity) {
    const simpMatch = manifest.match(/<activity[^>]*android:name="([^"]+)"/);
    if (simpMatch) mainActivity = resolveClass(simpMatch[1]);
  }
}
console.log('Main activity:', mainActivity || '(not found)');

// ── Find smali file for a class name ──────────────────────────────────────

function classToSmaliPath(cls) {
  return cls.replace(/\\./g, '/') + '.smali';
}

function findSmaliFile(cls) {
  if (!cls) return null;
  const rel = classToSmaliPath(cls);
  for (const entry of fs.readdirSync(DECOMPILED)) {
    if (!entry.startsWith('smali')) continue;
    const candidate = path.join(DECOMPILED, entry, rel);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// ── Inject hook into a smali method ───────────────────────────────────────

function injectHook(smaliPath, methodSig) {
  if (!smaliPath || !fs.existsSync(smaliPath)) return false;
  let content = fs.readFileSync(smaliPath, 'utf8');
  if (content.includes(HOOK)) {
    console.log('  [SKIP] hook already present in', path.basename(smaliPath));
    return false;
  }
  const lines = content.split('\\n');
  const result = [];
  let inTarget = false;
  let injected = false;

  for (const line of lines) {
    result.push(line);
    if (!inTarget && !injected && line.trim().startsWith('.method') && line.includes(methodSig)) {
      inTarget = true;
    }
    if (inTarget && !injected && line.trim().startsWith('.locals ')) {
      result.push('');
      result.push('    ' + HOOK);
      injected = true;
    }
    if (inTarget && line.trim() === '.end method') {
      inTarget = false;
    }
  }

  if (injected) {
    fs.writeFileSync(smaliPath, result.join('\\n'), 'utf8');
    console.log('  [OK] hook injected into', path.basename(smaliPath), '—', methodSig);
    return true;
  }
  console.log('  [WARN] method not found:', methodSig, 'in', path.basename(smaliPath));
  return false;
}

// ── Inject into main activity ──────────────────────────────────────────────
let totalInjections = 0;
if (mainActivity) {
  const smali = findSmaliFile(mainActivity);
  if (smali) {
    if (injectHook(smali, 'onCreate(Landroid/os/Bundle;)V')) totalInjections++;
    if (totalInjections === 0) {
      if (injectHook(smali, 'onCreate()V')) totalInjections++;
    }
  } else {
    console.log('[WARN] smali not found for activity:', mainActivity);
  }
}

// ── Inject into Application class ─────────────────────────────────────────
if (appClass && appClass !== mainActivity) {
  const smali = findSmaliFile(appClass);
  if (smali) {
    if (injectHook(smali, 'onCreate()V')) totalInjections++;
    if (injectHook(smali, 'attachBaseContext(Landroid/content/Context;)V')) totalInjections++;
  } else {
    console.log('[WARN] smali not found for application:', appClass);
  }
}

// ── Disassemble DEX into new smali folder ──────────────────────────────────

function getHighestSmaliIndex() {
  let max = 1;
  for (const entry of fs.readdirSync(DECOMPILED)) {
    const m = entry.match(/^smali_classes(\\d+)$/);
    if (m) max = Math.max(max, parseInt(m[1]));
    if (entry === 'smali') max = Math.max(max, 1);
  }
  return max;
}

const nextIndex = getHighestSmaliIndex() + 1;
const newSmaliDir = path.join(DECOMPILED, 'smali_classes' + nextIndex);
fs.mkdirSync(newSmaliDir, { recursive: true });

console.log('Disassembling AntiDialogKiller DEX to', 'smali_classes' + nextIndex + '...');
try {
  execSync('java -jar ' + BAKSMALI_JAR + ' d ' + DEX_FILE + ' -o ' + newSmaliDir, { stdio: 'inherit' });
  const smaliCount = require('child_process').execSync('find ' + newSmaliDir + ' -name "*.smali" | wc -l').toString().trim();
  console.log('DEX disassembled —', smaliCount, 'smali files added.');
} catch (e) {
  console.error('[ERROR] baksmali failed:', e.message);
  process.exit(1);
}

console.log('Anti-Dialog Killer injection complete —', totalInjections, 'hook(s) injected.');
`;
}
