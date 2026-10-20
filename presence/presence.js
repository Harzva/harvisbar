const shell = document.querySelector(".presence-shell");
const presenceRootInput = document.getElementById("presenceRootInput");
const presenceTokenInput = document.getElementById("presenceTokenInput");
const presenceRefreshButton = document.getElementById("presenceRefreshButton");
const presenceStateText = document.getElementById("presenceStateText");
const presenceCaption = document.getElementById("presenceCaption");

const captions = {
  idle: "Standing by.",
  reading: "Scanning local runtime.",
  thinking: "Reasoning over status.",
  acting: "Running a local action.",
  verified: "Healthy and ready.",
  blocked: "Human review required.",
};

function normalizeState(value, fallback = "idle") {
  const label = String(value || "").toLowerCase().replaceAll("_", "-").trim();
  const canonical = ["idle", "reading", "thinking", "acting", "verified", "blocked"];
  if (canonical.includes(label)) {
    return label;
  }
  if (["online", "ready", "healthy", "ok", "seen"].includes(label)) {
    return "verified";
  }
  if (["degraded", "offline", "down", "failed", "error", "warn", "approval-required", "waiting-approval"].includes(label)) {
    return "blocked";
  }
  if (["scanning", "loading", "refreshing", "probing"].includes(label)) {
    return "reading";
  }
  if (["planning", "reasoning", "queued", "pending"].includes(label)) {
    return "thinking";
  }
  if (["running", "executing", "initializing", "writing", "working"].includes(label)) {
    return "acting";
  }
  return fallback;
}

let runtimeRoot = "";

function setState(state) {
  const normalized = normalizeState(state);
  shell.dataset.state = normalized;
  presenceStateText.textContent = normalized;
  presenceCaption.textContent = captions[normalized] || "Watching H.A.R.V.I.S.";
  document.title = `H.A.R.V.I.S. Presence - ${normalized}`;
}

function qs(data) {
  return new URLSearchParams(data).toString();
}

async function api(path) {
  const options = { method: "GET", headers: { ...window.HarvisRuntime.bearerHeaders(presenceTokenInput) } };
  const response = await fetch(path, options);
  const payload = await response.json();
  if (!payload.ok) {
    throw new Error(payload.error ? payload.error.message : "Request failed.");
  }
  return window.HarvisRuntime.scrub(payload.data, runtimeRoot);
}

function inferFromBarStatus(payload) {
  const runtime = payload && payload.runtime ? payload.runtime : {};
  const direct = normalizeState(runtime.state, "");
  if (direct) {
    return direct;
  }
  const work = payload && payload.work ? payload.work : {};
  if (work.currentAction || work.activeRunId) {
    return "acting";
  }
  if (work.lastTickAt || work.last_tick_at) {
    return "verified";
  }
  return "thinking";
}

function inferFromStatus(payload) {
  const status = payload && payload.status ? payload.status : {};
  const errors = Array.isArray(status.errors) ? status.errors.length : 0;
  const counts = status.packet_status_counts || {};
  if (errors > 0 || Number(counts.blocked || 0) > 0) {
    return "blocked";
  }
  if (Number(counts.running || 0) > 0 || Number(counts.acting || 0) > 0) {
    return "acting";
  }
  if (Number(counts.pending || 0) > 0 || Number(counts.queued || 0) > 0) {
    return "thinking";
  }
  if (status.last_tick_at) {
    return "verified";
  }
  return "thinking";
}

async function refreshPresence() {
  setState("reading");
  const root = runtimeRoot;
  await api("/health");
  if (!root) {
    setState("idle");
    return;
  }
  if (presenceTokenInput.value.trim()) {
    try {
      const barPayload = await api(`/bar/status?${qs({ root })}`);
      setState(inferFromBarStatus(barPayload));
      shell.dataset.connected = "true";
      return;
    } catch (_) {
      // Fall through to the public legacy status route when the bar contract is unavailable.
    }
  }
  const statusPayload = await api(`/status?${qs({ root })}`);
  setState(inferFromStatus(statusPayload));
  shell.dataset.connected = "true";
}

presenceRefreshButton.addEventListener("click", () => {
  refreshPresence().catch(() => setState("blocked"));
});
presenceTokenInput.addEventListener("change", () => refreshPresence().catch(() => setState("blocked")));

window.HarvisRuntime.bootstrap()
  .then((bootstrap) => {
    runtimeRoot = bootstrap.workspaceRoot;
    window.HarvisRuntime.applyWorkspaceLabel(presenceRootInput, bootstrap.workspaceLabel);
    return refreshPresence();
  })
  .catch(() => setState("blocked"));
window.setInterval(() => {
  refreshPresence().catch(() => setState("blocked"));
}, 15000);
