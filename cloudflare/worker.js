// Taurus Shield — Cloudflare Worker
// Routes: /game-dump  /upload-asset  /dispatch-mod-build
//         /find-run   /status        /job-live
//         /mod-result /dump-result
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

    // ── POST /dispatch-mod-build ─────────────────────────────────────────────
    // Body = features JSON string. Dispatches mod-build.yml.
    if (method === 'POST' && path === '/dispatch-mod-build') {
      try {
        const assetId    = url.searchParams.get('asset_id');
        const jobId      = url.searchParams.get('job_id');
        const gameName   = url.searchParams.get('game_name') || 'game';

        if (!assetId || !jobId) return json({ error: 'asset_id and job_id required' }, 400);

        const featuresJson = await request.text();

        const dispatch = await fetch(
          `https://api.github.com/repos/${REPO}/actions/workflows/mod-build.yml/dispatches`,
          {
            method: 'POST',
            headers: { ...ghHeaders(env), 'Content-Type': 'application/json' },
            body: JSON.stringify({
              ref: 'main',
              inputs: {
                asset_id:      assetId,
                job_id:        jobId,
                game_name:     gameName,
                features_json: featuresJson,
              },
            }),
          }
        );
        if (!dispatch.ok) {
          const err = await dispatch.text();
          return json({ error: 'Dispatch failed', detail: err, status: dispatch.status }, 500);
        }
        return json({ dispatched: true, job_id: jobId });
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

    // ── GET /mod-result ──────────────────────────────────────────────────────
    if (method === 'GET' && path === '/mod-result') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `modded_${jobId}.apk`, 'application/vnd.android.package-archive');
    }

    // ── GET /dump-result ─────────────────────────────────────────────────────
    if (method === 'GET' && path === '/dump-result') {
      const jobId = url.searchParams.get('job_id');
      if (!jobId) return json({ error: 'job_id required' }, 400);
      return proxyReleaseAsset(env, `dump_offsets_${jobId}.json`, 'application/json');
    }

    return new Response('Not found.', { status: 404 });
  },
};
