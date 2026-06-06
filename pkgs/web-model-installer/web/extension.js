import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

/*
 * Web Model Installer - frontend extension
 *
 * - Listens for wmi.progress / wmi.done / wmi.error / wmi.cancelled WS events
 * - Renders a floating progress panel (bottom-right) that auto-collapses
 *   to a pill when idle and stays below app modals (z-index 1000)
 * - Registers window.__wmi.start, called by the patched downloadModel()
 *   in the core frontend bundle's missing-models panel
 * - On completion, triggers a model-list refresh so the "Missing Models"
 *   error indicator clears automatically
 */

const PANEL_ID = "wmi-progress-panel";
const PILL_ID = "wmi-progress-pill";
const LIST_ID = "wmi-progress-list";

const AUTOHIDE_DONE_MS = 4000;
const AUTOCOLLAPSE_MS = 2500;

const jobs = new Map();
let collapseTimer = null;
let userCollapsed = false;

function fmtBytes(n) {
  if (!n || n < 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return v.toFixed(i ? 1 : 0) + " " + u[i];
}

function isActiveStatus(status) {
  return status === "running" || status === "queued";
}

function activeCount() {
  let n = 0;
  for (const j of jobs.values()) {
    if (isActiveStatus(j.status)) n++;
  }
  return n;
}

function toast(severity, summary, detail) {
  try {
    app.extensionManager?.toast?.add?.({ severity, summary, detail, life: 4000 });
  } catch {
    /* extensionManager may not be ready yet; fall back to console */
    console.log(`[WMI] toast ${severity}: ${summary} - ${detail}`);
  }
}

function ensurePanel() {
  const existing = document.getElementById(PANEL_ID);
  if (existing) return existing;
  const p = document.createElement("div");
  p.id = PANEL_ID;
  p.style.cssText = [
    "position:fixed", "right:16px", "bottom:16px", "z-index:1000",
    "width:320px", "max-height:50vh", "overflow-y:auto",
    "background:rgba(24,24,27,0.95)", "color:#e5e7eb",
    "border:1px solid #3f3f46", "border-radius:10px",
    "box-shadow:0 10px 30px rgba(0,0,0,0.4)",
    "font:12px/1.4 system-ui,sans-serif", "padding:8px 10px",
    "backdrop-filter:blur(6px)", "display:none",
  ].join(";");
  p.innerHTML = `
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;gap:6px">
      <div style="font-weight:600;font-size:12px;color:#d4d4d8">Server downloads</div>
      <div style="display:flex;gap:2px">
        <button data-act="collapse" title="Collapse" style="background:transparent;border:0;color:#a1a1aa;cursor:pointer;font-size:14px;line-height:1;padding:2px 6px">–</button>
      </div>
    </div>
    <div id="${LIST_ID}"></div>
  `;
  document.body.appendChild(p);
  p.querySelector("[data-act=collapse]").addEventListener("click", () => setCollapsed(true));
  return p;
}

function ensurePill() {
  const existing = document.getElementById(PILL_ID);
  if (existing) return existing;
  const el = document.createElement("button");
  el.id = PILL_ID;
  el.style.cssText = [
    "position:fixed", "right:16px", "bottom:16px", "z-index:1000",
    "background:rgba(24,24,27,0.9)", "color:#e5e7eb",
    "border:1px solid #3f3f46", "border-radius:999px",
    "padding:6px 10px", "font:11px/1 system-ui,sans-serif",
    "cursor:pointer", "display:none", "box-shadow:0 4px 12px rgba(0,0,0,0.3)",
    "backdrop-filter:blur(6px)",
  ].join(";");
  el.addEventListener("click", () => setCollapsed(false));
  document.body.appendChild(el);
  return el;
}

function updatePill() {
  const pill = ensurePill();
  const active = activeCount();
  if (active === 0) {
    pill.style.display = "none";
    return;
  }
  let totalD = 0;
  let totalT = 0;
  let any = false;
  for (const j of jobs.values()) {
    if (isActiveStatus(j.status) && j.total) {
      totalD += j.downloaded;
      totalT += j.total;
      any = true;
    }
  }
  const pct = any && totalT ? ((totalD / totalT) * 100).toFixed(0) + "%" : "…";
  pill.textContent = `▼ ${active} download${active > 1 ? "s" : ""} · ${pct}`;
  pill.style.display = "inline-block";
}

function setCollapsed(collapsed) {
  userCollapsed = collapsed;
  const panel = ensurePanel();
  const pill = ensurePill();
  if (collapsed) {
    panel.style.display = "none";
    updatePill();
  } else {
    clearTimeout(collapseTimer);
    collapseTimer = null;
    panel.style.display = "block";
    pill.style.display = "none";
  }
}

function scheduleAutoCollapse() {
  if (activeCount() > 0) return;
  clearTimeout(collapseTimer);
  collapseTimer = setTimeout(() => setCollapsed(true), AUTOCOLLAPSE_MS);
}

async function cancelJob(jobId) {
  try {
    const r = await fetch("/api/wmi/cancel", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ job_id: jobId }),
    });
    if (!r.ok) {
      const d = await r.json().catch(() => ({}));
      toast("warn", "Cancel failed", d.error || `HTTP ${r.status}`);
    }
  } catch (e) {
    console.warn("[WMI] cancel request failed", e);
    toast("error", "Cancel error", e.message);
  }
}

function renderRow(job) {
  const panel = ensurePanel();
  const list = panel.querySelector("#" + LIST_ID);
  let row = list.querySelector(`[data-job="${job.job_id}"]`);
  if (!row) {
    row = document.createElement("div");
    row.dataset.job = job.job_id;
    row.style.cssText = "padding:6px 0;border-top:1px solid #27272a";
    if (!list.firstChild) row.style.borderTop = "0";
    row.innerHTML = `
      <div style="display:flex;justify-content:space-between;gap:8px;margin-bottom:3px;align-items:center">
        <span class="wmi-name" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1"></span>
        <span class="wmi-pct" style="color:#a1a1aa;flex-shrink:0"></span>
        <button class="wmi-cancel" title="Cancel" style="background:transparent;border:0;color:#a1a1aa;cursor:pointer;font-size:14px;line-height:1;padding:0 2px;display:none">×</button>
      </div>
      <div style="background:#27272a;border-radius:3px;overflow:hidden;height:4px">
        <div class="wmi-bar" style="background:#3b82f6;height:100%;width:0%;transition:width .25s"></div>
      </div>
      <div class="wmi-meta" style="color:#71717a;margin-top:3px;font-size:10px"></div>
    `;
    row.querySelector(".wmi-cancel").addEventListener("click", () => cancelJob(job.job_id));
    list.appendChild(row);
  }
  const pct = job.total > 0 ? Math.min(100, (job.downloaded / job.total) * 100) : 0;
  const nameEl = row.querySelector(".wmi-name");
  nameEl.textContent = job.filename;
  nameEl.title = `${job.directory}/${job.filename}`;
  const active = isActiveStatus(job.status);
  row.querySelector(".wmi-pct").textContent =
    job.status === "done" ? "✓"
      : job.status === "error" ? "✗"
        : job.status === "cancelled" ? "⊘"
          : (job.total ? pct.toFixed(0) + "%" : fmtBytes(job.downloaded));
  row.querySelector(".wmi-cancel").style.display = active ? "inline-block" : "none";
  const bar = row.querySelector(".wmi-bar");
  bar.style.width = (job.status === "done" ? 100 : pct) + "%";
  if (job.status === "done") bar.style.background = "#22c55e";
  else if (job.status === "error") bar.style.background = "#ef4444";
  else if (job.status === "cancelled") bar.style.background = "#71717a";
  const meta = row.querySelector(".wmi-meta");
  meta.textContent = job.status === "error"
    ? `Error: ${job.error || "unknown"}`
    : job.status === "cancelled"
      ? `${job.directory} · cancelled`
      : `${job.directory} · ${fmtBytes(job.downloaded)}${job.total ? " / " + fmtBytes(job.total) : ""}`;
}

function removeRow(jobId) {
  const panel = document.getElementById(PANEL_ID);
  if (!panel) return;
  const row = panel.querySelector(`[data-job="${jobId}"]`);
  if (row) row.remove();
  const list = panel.querySelector("#" + LIST_ID);
  if (list && !list.firstChild) setCollapsed(true);
}

function upsertJob(job) {
  const existing = jobs.get(job.job_id) ?? {};
  const merged = { ...existing, ...job };
  jobs.set(job.job_id, merged);

  if (isActiveStatus(merged.status)) {
    const panel = ensurePanel();
    if (panel.style.display === "none" && !userCollapsed) {
      setCollapsed(false);
    }
  }
  renderRow(merged);
  updatePill();

  if (merged.status === "done" || merged.status === "error" || merged.status === "cancelled") {
    setTimeout(() => {
      jobs.delete(merged.job_id);
      removeRow(merged.job_id);
      updatePill();
    }, AUTOHIDE_DONE_MS);
    scheduleAutoCollapse();
  }
}

async function refreshAfterDownload() {
  try {
    if (typeof app?.refreshComboInNodes === "function") {
      await app.refreshComboInNodes();
    }
  } catch (e) {
    console.warn("[WMI] refreshComboInNodes failed", e);
  }
}

async function startDownload(model) {
  let resp;
  try {
    resp = await fetch("/api/wmi/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: model.url,
        filename: model.name,
        directory: model.directory,
      }),
    });
  } catch (e) {
    console.warn("[WMI] download request failed", e);
    toast("error", "Server download error", e.message);
    return;
  }
  let data;
  try {
    data = await resp.json();
  } catch (e) {
    console.warn("[WMI] download response was not JSON", e);
    toast("error", "Server download failed", `HTTP ${resp.status}`);
    return;
  }
  if (!resp.ok) {
    toast("error", "Server download failed", data?.error || `HTTP ${resp.status}`);
    return;
  }
  upsertJob({
    job_id: data.job_id,
    filename: data.filename,
    directory: data.directory,
    downloaded: 0,
    total: 0,
    status: "queued",
  });
}

window.__wmi = window.__wmi ?? {};
window.__wmi.start = startDownload;

app.registerExtension({
  name: "WebModelInstaller",
  async setup() {
    api.addEventListener("wmi.progress", (ev) => upsertJob(ev.detail));
    api.addEventListener("wmi.done", async (ev) => {
      upsertJob(ev.detail);
      await refreshAfterDownload();
    });
    api.addEventListener("wmi.error", (ev) => {
      upsertJob(ev.detail);
      toast("error", "Download failed", ev.detail.error || "unknown");
    });
    api.addEventListener("wmi.cancelled", (ev) => {
      upsertJob(ev.detail);
      toast("info", "Download cancelled", `${ev.detail.directory}/${ev.detail.filename}`);
    });
    console.log("[WMI] frontend extension loaded");
  },
});

