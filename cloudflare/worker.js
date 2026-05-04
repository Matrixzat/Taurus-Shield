// Taurus Shield — Cloudflare Worker
// Routes: /game-dump        /upload-asset   /dump-result
//         /find-run         /status         /job-live      /cancel-run
//         /dispatch-job     /dex2c          /analyze       /dptshell
//         /artifact         /asset(DELETE)  /job-error
//         /dump-cs          /dump-il2cpp-h  /dump-script-json
//         /dump-stringliteral /dump-ida     /dump-ida-struct /dump-ghidra
//
// Required Cloudflare secret: GH_TOKEN  (GitHub PAT with repo + actions scope)

const REPO        = 'Matrixzat/Taurus-Shield';
const RELEASE_TAG = 'analyze-queue';

function ghHeaders(env) {
  return {
    'Authorization': `Bearer ${env.GH_TOKEN}`,
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'TaurusShield-Worker/2.0',
    'X-GitHub-Api-Version': '2022-11-28',
  };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function makeJobId() {
  return String(Date.now());
}

async function getReleaseId(env) {
  const r = await fetch(
    `https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}`,
    { headers: ghHeaders(env) }
  );
  const d = await r.json();
  if (!d.id) throw new Error('analyze-queue release not found');
  return d.id;
}

async function uploadToRelease(env, releaseId, body, filename, contentType) {
  const r = await fetch(
    `https://uploads.github.com/repos/${REPO}/releases/${releaseId}/assets?name=${encodeURIComponent(filename)}`,
    {
      method: 'POST',
      headers: { ...ghHeaders(env), 'Content-Type': contentType },
      body,
    }
  );
  return r.json();
}

async function proxyReleaseAsset(env, filename, contentType) {
  try {
    const r = await fetch(
      `https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}`,
      { headers: ghHeaders(env) }
    );
    const release = await r.json();
    const asset = (release.assets || []).find(a => a.name === filename);
    if (!asset) return json({ error: `Result not ready: ${filename}` }, 404);

    const dl = await fetch(asset.browser_download_url, {
      headers: {
        'Authorization': `Bearer ${env.GH_TOKEN}`,
        'Accept': 'application/octet-stream',
      },
    });
    return new Response(dl.body, {
      status: 200,
      headers: {
        'Content-Type': contentType,
        'Content-Disposition': `attachment; filename="${filename}"`,
      },
    });
  } catch (e) {
    return json({ error: e.message }, 500);
  }
}

export default {
  async fetch(request, env) {
    const url    = new URL(request.url);
    const path   = url.pathname;
    const method = request.method;

    // ── POST /game-dump ─────────────────────────────────────────────────────
    // Receives raw APK bytes, uploads to release, dispatches game-dump.yml
    if (method === 'POST' && path === '/game-dump') {
      try {
        const jobId     = makeJobId();
        const releaseId = await getReleaseId(env);
        const apkBytes  = await request.arrayBuffer();

        const asset = await uploadToRelease(
          env, releaseId, apkBytes,
          `input_dump_${jobId}.apk`,
          'application/vnd.android.package-archive'
        );
        if (!asset.id) return json({ error: 'APK upload failed', detail: asset }, 500);

        const triggeredAt = Date.now();
        const dispatch = await fetch(
          `https://api.github.com/repos/${REPO}/actions/workflows/game-dump.yml/dispatches`,
          {
            method: 'POST',
            headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
            body: JSON.stringify({
              ref: 'main',
              inputs: { asset_id: String(asset.id), job_id: jobId },
            }),
          }
        );
        if (!dispatch.ok) {
          const err = await dispatch.text();
          return json({ error: 'Workflow dispatch failed', detail: err }, 500);
        }
        return json({ job_id: jobId, asset_id: asset.id, triggered_at: triggeredAt });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── POST /upload-asset ───────────────────────────────────────────────────
    // Receives raw file bytes, uploads to release, returns {job_id, asset_id}
    if (method === 'POST' && path === '/upload-asset') {
      try {
        const ext       = url.searchParams.get('ext') || 'apk';
        const jobId     = makeJobId();
        const releaseId = await getReleaseId(env);
        const fileBytes = await request.arrayBuffer();

        const asset = await uploadToRelease(
          env, releaseId, fileBytes,
          `input_mod_${jobId}.${ext}`,
          'application/vnd.android.package-archive'
        );
        if (!asset.id) return json({ error: 'Upload failed', detail: asset }, 500);
        return json({ job_id: jobId, asset_id: asset.id });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── GET /find-run ────────────────────────────────────────────────────────
    if (method === 'GET' && path === '/find-run') {
      const after    = parseInt(url.searchParams.get('after') || '0');
      const workflow = url.searchParams.get('workflow') || 'mod-build.yml';
      try {
        const r = await fetch(
          `https://api.github.com/repos/${REPO}/actions/runs?per_page=10`,
          { headers: ghHeaders(env) }
        );
        const d    = await r.json();
        const runs = d.workflow_runs || [];

        for (const run of runs) {
          const createdMs = new Date(run.created_at).getTime();
          if (run.path?.includes(workflow) && createdMs >= after) {
            return json({
              found:      true,
              run_id:     run.id,
              run_number: run.run_number,
              status:     run.status,
              conclusion: run.conclusion,
            });
          }
        }
        return json({ found: false });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── GET /status ──────────────────────────────────────────────────────────
    if (method === 'GET' && path === '/status') {
      const runId = url.searchParams.get('run_id');
      if (!runId) return json({ error: 'run_id required' }, 400);
      try {
        const r = await fetch(
          `https://api.github.com/repos/${REPO}/actions/runs/${runId}`,
          { headers: ghHeaders(env) }
        );
        const d = await r.json();
        if (!d.id) return json({ error: 'Could not fetch run status' }, 404);
        return json({
          run_id:     d.id,
          status:     d.status,
          conclusion: d.conclusion,
          run_number: d.run_number,
        });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── GET /job-live ────────────────────────────────────────────────────────
    if (method === 'GET' && path === '/job-live') {
      const runId = url.searchParams.get('run_id');
      if (!runId) return json({ error: 'run_id required' }, 400);
      try {
        const r = await fetch(
          `https://api.github.com/repos/${REPO}/actions/runs/${runId}/jobs`,
          { headers: ghHeaders(env) }
        );
        const d = await r.json();
        if (!d.jobs) return json({ error: 'Failed to fetch jobs' }, 500);

        const allSteps  = d.jobs.flatMap(j => j.steps || []);
        const inProgress = allSteps.find(s => s.status === 'in_progress');
        const completed  = allSteps.filter(s => s.status === 'completed');

        return json({
          current_step:    inProgress?.name || '',
          completed_count: completed.length,
          total_steps:     allSteps.length,
          status:          d.jobs[0]?.status || 'unknown',
        });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── POST /cancel-run ─────────────────────────────────────────────────────
    // Cancels a queued or in-progress cloud build run immediately.
    if (method === 'POST' && path === '/cancel-run') {
      const runId = url.searchParams.get('run_id');
      if (!runId) return json({ error: 'run_id required' }, 400);
      try {
        const r = await fetch(
          `https://api.github.com/repos/${REPO}/actions/runs/${runId}/cancel`,
          { method: 'POST', headers: ghHeaders(env) }
        );
        // GitHub returns 202 on success, 409 if already finished — both are fine
        return json({ cancelled: true, run_id: Number(runId), status: r.status });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── GET /dump-result ─────────────────────────────────────────────────────
    if (method === 'GET' && path === '/dump-result') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_offsets_${jobId}.json`, 'application/json');
    }

    // ── GET /dump-cs ──────────────────────────────────────────────────────────
    if (method === 'GET' && path === '/dump-cs') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_cs_${jobId}.txt`, 'text/plain');
    }

    // ── GET /dump-il2cpp-h ────────────────────────────────────────────────────
    // Serves il2cpp.h (C structure header for IDA Pro / Ghidra).
    if (method === 'GET' && path === '/dump-il2cpp-h') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_il2cpp_h_${jobId}.txt`, 'text/plain');
    }

    // ── GET /dump-script-json ─────────────────────────────────────────────────
    // Serves script.json (raw RVA/offset table, for IDA/Ghidra scripts).
    if (method === 'GET' && path === '/dump-script-json') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_script_${jobId}.json`, 'application/json');
    }

    // ── GET /dump-stringliteral ───────────────────────────────────────────────
    // Serves stringliteral.json (all game string literals).
    if (method === 'GET' && path === '/dump-stringliteral') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_stringliteral_${jobId}.json`, 'application/json');
    }

    // ── GET /dump-ida ─────────────────────────────────────────────────────────
    // Serves ida.py (IDA Pro labelling script).
    if (method === 'GET' && path === '/dump-ida') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_ida_${jobId}.py`, 'text/plain');
    }

    // ── GET /dump-ida-struct ──────────────────────────────────────────────────
    // Serves ida_with_struct.py (IDA Pro script + il2cpp.h struct info).
    if (method === 'GET' && path === '/dump-ida-struct') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_ida_struct_${jobId}.py`, 'text/plain');
    }

    // ── GET /dump-ghidra ──────────────────────────────────────────────────────
    // Serves ghidra.py (Ghidra labelling script).
    if (method === 'GET' && path === '/dump-ghidra') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_ghidra_${jobId}.py`, 'text/plain');
    }

    // ── GET /dispatch-job ──────────────────────────────────────────────────────
    // Dispatches any named workflow. All query params (except 'workflow') become
    // workflow inputs so the caller can pass sign_apk, mode, etc. freely.
    if (method === 'GET' && path === '/dispatch-job') {
      const workflow = url.searchParams.get('workflow');
      if (!workflow) return json({ error: 'workflow required' }, 400);
      const inputs = {};
      for (const [k, v] of url.searchParams.entries()) {
        if (k !== 'workflow') inputs[k] = v;
      }
      try {
        const dispatch = await fetch(
          `https://api.github.com/repos/${REPO}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`,
          {
            method: 'POST',
            headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
            body: JSON.stringify({ ref: 'main', inputs }),
          }
        );
        if (!dispatch.ok) {
          const err = await dispatch.text();
          return json({ error: 'Dispatch failed', detail: err }, 502);
        }
        return json({ ok: true, workflow, job_id: inputs.job_id ?? null });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── POST /dex2c ────────────────────────────────────────────────────────────
    // Upload a dex2c ZIP then dispatch dex2c.yml. Returns {job_id, asset_id}.
    if (method === 'POST' && path === '/dex2c') {
      try {
        const sign     = url.searchParams.get('sign') || 'true';
        const jobId    = makeJobId();
        const releaseId = await getReleaseId(env);
        const fileBytes = await request.arrayBuffer();
        const asset = await uploadToRelease(
          env, releaseId, fileBytes,
          `input_dex2c_${jobId}.zip`, 'application/zip'
        );
        if (!asset.id) return json({ error: 'Upload failed', detail: asset }, 500);
        const dispatch = await fetch(
          `https://api.github.com/repos/${REPO}/actions/workflows/dex2c.yml/dispatches`,
          {
            method: 'POST',
            headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
            body: JSON.stringify({
              ref: 'main',
              inputs: { asset_id: String(asset.id), job_id: jobId, sign_apk: sign },
            }),
          }
        );
        if (!dispatch.ok) {
          const err = await dispatch.text();
          return json({ error: 'Workflow dispatch failed', detail: err }, 500);
        }
        return json({ job_id: jobId, asset_id: asset.id });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── POST /analyze ──────────────────────────────────────────────────────────
    // Upload a Flutter APK/ZIP then dispatch blutter.yml. Returns {job_id, asset_id}.
    if (method === 'POST' && path === '/analyze') {
      try {
        const ext       = url.searchParams.get('ext') || 'apk';
        const jobId     = makeJobId();
        const releaseId = await getReleaseId(env);
        const fileBytes = await request.arrayBuffer();
        const asset = await uploadToRelease(
          env, releaseId, fileBytes,
          `input_blutter_${jobId}.${ext}`,
          ext === 'zip' ? 'application/zip' : 'application/vnd.android.package-archive'
        );
        if (!asset.id) return json({ error: 'Upload failed', detail: asset }, 500);
        const dispatch = await fetch(
          `https://api.github.com/repos/${REPO}/actions/workflows/blutter.yml/dispatches`,
          {
            method: 'POST',
            headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
            body: JSON.stringify({
              ref: 'main',
              inputs: { asset_id: String(asset.id), job_id: jobId },
            }),
          }
        );
        if (!dispatch.ok) {
          const err = await dispatch.text();
          return json({ error: 'Workflow dispatch failed', detail: err }, 500);
        }
        return json({ job_id: jobId, asset_id: asset.id });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── POST /dptshell ─────────────────────────────────────────────────────────
    // Upload a DPT-Shell ZIP then dispatch dptshell.yml. Returns {job_id, asset_id}.
    if (method === 'POST' && path === '/dptshell') {
      try {
        const sign      = url.searchParams.get('sign') || 'true';
        const jobId     = makeJobId();
        const releaseId = await getReleaseId(env);
        const fileBytes = await request.arrayBuffer();
        const asset = await uploadToRelease(
          env, releaseId, fileBytes,
          `input_dptshell_${jobId}.zip`, 'application/zip'
        );
        if (!asset.id) return json({ error: 'Upload failed', detail: asset }, 500);
        const dispatch = await fetch(
          `https://api.github.com/repos/${REPO}/actions/workflows/dptshell.yml/dispatches`,
          {
            method: 'POST',
            headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
            body: JSON.stringify({
              ref: 'main',
              inputs: { asset_id: String(asset.id), job_id: jobId, sign_apk: sign },
            }),
          }
        );
        if (!dispatch.ok) {
          const err = await dispatch.text();
          return json({ error: 'Workflow dispatch failed', detail: err }, 500);
        }
        return json({ job_id: jobId, asset_id: asset.id });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── GET /artifact ──────────────────────────────────────────────────────────
    // Downloads a completed job's output ZIP from the release assets.
    // Asset name convention: <prefix>_<job_id>.zip  (or output_<job_id>.zip if
    // no prefix supplied — used by Blutter / generic jobs).
    if (method === 'GET' && path === '/artifact') {
      const jobId  = url.searchParams.get('job_id');
      const prefix = url.searchParams.get('prefix') || '';
      if (!jobId) return json({ error: 'job_id required' }, 400);
      const filename = prefix ? `${prefix}_${jobId}.zip` : `output_${jobId}.zip`;
      return proxyReleaseAsset(env, filename, 'application/zip');
    }

    // ── DELETE /asset ──────────────────────────────────────────────────────────
    // Deletes a specific release asset (used to clean up input/output files).
    if (method === 'DELETE' && path === '/asset') {
      const assetId = url.searchParams.get('asset_id');
      if (!assetId) return json({ error: 'asset_id required' }, 400);
      try {
        const r = await fetch(
          `https://api.github.com/repos/${REPO}/releases/assets/${assetId}`,
          { method: 'DELETE', headers: ghHeaders(env) }
        );
        return json({ deleted: true, asset_id: Number(assetId), status: r.status });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    // ── GET /job-error ─────────────────────────────────────────────────────────
    // Returns the names of any failed steps for a given run, used to surface
    // error context in the app log panel when a cloud job fails.
    if (method === 'GET' && path === '/job-error') {
      const runId = url.searchParams.get('run_id');
      if (!runId) return json({ error: 'run_id required' }, 400);
      try {
        const r = await fetch(
          `https://api.github.com/repos/${REPO}/actions/runs/${runId}/jobs`,
          { headers: ghHeaders(env) }
        );
        const d = await r.json();
        if (!d.jobs) return json({ error: 'Could not fetch jobs' }, 500);
        const failedSteps = d.jobs
          .flatMap(j => j.steps || [])
          .filter(s => s.conclusion === 'failure')
          .map(s => `[FAILED] ${s.name}`);
        const errorLines = failedSteps.length
          ? failedSteps.join('\n')
          : 'No failed steps found — job may have been cancelled or timed out.';
        return new Response(errorLines, {
          status: 200,
          headers: { 'Content-Type': 'text/plain' },
        });
      } catch (e) {
        return json({ error: e.message }, 500);
      }
    }

    return new Response('Not found.', { status: 404 });
  },
};
