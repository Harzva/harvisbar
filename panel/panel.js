const shell = document.querySelector(".shell");
const rootInput = document.getElementById("rootInput");
const profileInput = document.getElementById("profileInput");
const tokenInput = document.getElementById("tokenInput");
const stateText = document.getElementById("stateText");
const presenceCaption = document.getElementById("presenceCaption");
const summaryLine = document.getElementById("summaryLine");
const runtimeStamp = document.getElementById("runtimeStamp");
const packetMetric = document.getElementById("packetMetric");
const errorMetric = document.getElementById("errorMetric");
const modeMetric = document.getElementById("modeMetric");
const packetCount = document.getElementById("packetCount");
const eventCount = document.getElementById("eventCount");
const packetList = document.getElementById("packetList");
const eventList = document.getElementById("eventList");
const outputLog = document.getElementById("outputLog");
const outputKind = document.getElementById("outputKind");
const healthSignal = document.getElementById("panelHealthSignal");
const activeSignal = document.getElementById("panelActiveSignal");
const blockedSignal = document.getElementById("panelBlockedSignal");
const approvalSignal = document.getElementById("panelApprovalSignal");
const larkSignal = document.getElementById("panelLarkSignal");
const healthValue = document.getElementById("panelHealthValue");
const healthDetail = document.getElementById("panelHealthDetail");
const activeValue = document.getElementById("panelActiveValue");
const activeDetail = document.getElementById("panelActiveDetail");
const blockedValue = document.getElementById("panelBlockedValue");
const blockedDetail = document.getElementById("panelBlockedDetail");
const approvalValue = document.getElementById("panelApprovalValue");
const approvalDetail = document.getElementById("panelApprovalDetail");
const larkValue = document.getElementById("panelLarkValue");
const larkDetail = document.getElementById("panelLarkDetail");
const nextAction = document.getElementById("panelNextAction");
const nextTitle = document.getElementById("panelNextTitle");
const nextDetail = document.getElementById("panelNextDetail");
const nextImpact = document.getElementById("panelNextImpact");
const nextLink = document.getElementById("panelNextLink");
const lineageNode = document.getElementById("panelLineage");
const confirmDialog = document.getElementById("panelConfirmDialog");

const buttons = {
  refresh: document.getElementById("refreshButton"),
  scan: document.getElementById("scanButton"),
  tick: document.getElementById("tickButton"),
  snapshot: document.getElementById("snapshotButton"),
  workbench: document.getElementById("workbenchButton"),
};

let runtimeRoot = "";
profileInput.value = "~/.harvis";
const presenceCaptions = {
  idle: "Standing by.",
  reading: "Reading local state.",
  thinking: "Planning the next safe move.",
  acting: "Running an approved local action.",
  verified: "Checked and ready.",
  blocked: "Needs human review.",
};

function setState(state, summary) {
  shell.dataset.state = state;
  shell.dataset.runtimeState = state;
  stateText.textContent = state;
  presenceCaption.textContent = presenceCaptions[state] || "Watching the runtime.";
  if (summary) summaryLine.textContent = summary;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function statusIsBlocked(value) {
  return /blocked|failed|error|denied|cancelled/.test(String(value || "").toLowerCase());
}

function statusIsActive(value) {
  return /running|acting|working|planning|in_progress|executing/.test(String(value || "").toLowerCase());
}

function statusIsComplete(value) {
  return /done|complete|completed|reviewed|verified|approved|accepted|success/.test(String(value || "").toLowerCase());
}

function shortRef(value) {
  const label = String(value || "");
  if (!label) return "not linked";
  return label.length <= 15 ? label : `…${label.slice(-12)}`;
}

function setSignal(node, valueNode, detailNode, value, detail, runtimeState) {
  node.dataset.state = runtimeState;
  node.dataset.runtimeState = runtimeState;
  valueNode.textContent = value;
  detailNode.textContent = detail;
}

function explicitLineage(tasks, approvals, handoffs, runs) {
  const task = tasks.find((entry) => statusIsActive(entry.status) || statusIsBlocked(entry.status) || entry.approval_id || entry.handoff_id || entry.run_id) || tasks[0] || null;
  const approvalId = task && task.approval_id;
  const approval = approvalId ? approvals.find((entry) => entry.approval_id === approvalId) || null : null;
  const handoffId = (task && task.handoff_id) || (approval && approval.handoff_id) || "";
  const handoff = handoffId ? handoffs.find((entry) => entry.handoff_id === handoffId) || null : null;
  const runId = (task && task.run_id) || (approval && approval.run_id) || (handoff && handoff.run_id) || "";
  const run = runId ? runs.find((entry) => entry.run_id === runId) || null : null;
  const stages = [
    ["task", task, task && task.status, task && task.task_id],
    ["approval", approval, approval && approval.status, approval && approval.approval_id],
    ["handoff", handoff, handoff && (handoff.state || handoff.status), handoff && handoff.handoff_id],
    ["run", run, run && (run.state || run.status), run && run.run_id],
  ];
  return stages.map(([stage, entry, status, id]) => ({
    stage,
    state: !entry ? "idle" : statusIsBlocked(status) ? "blocked" : statusIsComplete(status) ? "verified" : statusIsActive(status) ? "acting" : "thinking",
    detail: entry ? `${String(status || "linked").replaceAll("_", " ")} · ${shortRef(id)}` : "not linked",
  })).concat([{
    stage: "review",
    state: handoff && statusIsComplete(handoff.state || handoff.status) ? "verified" : "idle",
    detail: handoff && statusIsComplete(handoff.state || handoff.status) ? "evidence recorded" : "not linked",
  }]);
}

function renderLineage(steps) {
  for (const step of steps) {
    const node = lineageNode.querySelector(`[data-stage="${step.stage}"]`);
    if (!node) continue;
    node.dataset.state = step.state;
    node.querySelector("small").textContent = step.detail;
  }
}

function renderFixture() {
  const fixture = window.HarvisOperator.renderFixture(document);
  if (!fixture) return false;
  const deck = document.querySelector(".panel-command-deck");
  shell.dataset.uiState = fixture.name;
  shell.setAttribute("aria-busy", fixture.name === "loading" ? "true" : "false");
  deck.dataset.uiState = fixture.name;
  deck.setAttribute("aria-busy", fixture.name === "loading" ? "true" : "false");
  const signalStates = {
    loading: ["reading", "idle", "idle", "idle", "reading"],
    empty: ["verified", "idle", "idle", "idle", "verified"],
    error: ["blocked", "idle", "blocked", "idle", "blocked"],
    blocked: ["verified", "idle", "blocked", "idle", "verified"],
    permission: ["verified", "idle", "blocked", "idle", "verified"],
    approval: ["verified", "idle", "idle", "thinking", "verified"],
    success: ["verified", "idle", "idle", "idle", "verified"],
  };
  const values = {
    loading: ["Checking", "Unknown", "—", "—", "Checking"], empty: ["Healthy", "None", "0", "0", "Online"],
    error: ["Unavailable", "Unknown", "1", "Unknown", "Needs attention"], blocked: ["Healthy", "None", "1", "0", "Online"],
    permission: ["Healthy", "None", "Permission", "0", "Online"], approval: ["Healthy", "None", "0", "1", "Online"],
    success: ["Healthy", "None", "0", "0", "Online"],
  };
  [healthSignal, activeSignal, blockedSignal, approvalSignal, larkSignal].forEach((node, index) => {
    node.dataset.state = signalStates[fixture.name][index];
    node.dataset.runtimeState = signalStates[fixture.name][index];
  });
  [healthValue, activeValue, blockedValue, approvalValue, larkValue].forEach((node, index) => { node.textContent = values[fixture.name][index]; });
  healthDetail.textContent = fixture.detail;
  activeDetail.textContent = fixture.name === "loading" ? "No active state inferred while evidence is loading." : fixture.detail;
  blockedDetail.textContent = fixture.name === "permission" ? "Required scope unavailable; reads remain available." : fixture.detail;
  approvalDetail.textContent = fixture.name === "approval" ? "Risk, scope, and impact require review." : fixture.detail;
  larkDetail.textContent = fixture.name === "error" ? "No online state inferred." : fixture.detail;
  nextAction.dataset.state = fixture.name;
  nextTitle.textContent = fixture.title;
  nextDetail.textContent = fixture.detail;
  nextImpact.textContent = fixture.next;
  nextLink.href = ["approval", "blocked", "permission"].includes(fixture.name) ? "/studio/?view=review" : "/studio/?view=work";
  Object.values(buttons).forEach((button) => {
    button.disabled = fixture.name === "loading";
    button.setAttribute("aria-disabled", button.disabled ? "true" : "false");
  });
  nextLink.setAttribute("aria-disabled", fixture.name === "loading" ? "true" : "false");
  nextLink.tabIndex = fixture.name === "loading" ? -1 : 0;
  return true;
}

function saveInputs() {
  // Connection details are intentionally page-memory only.
}

function root() {
  const value = runtimeRoot;
  if (!value) throw new Error("Workspace root is required.");
  return value;
}

function profileRoot() {
  return profileInput.value.trim() || "~/.harvis";
}

function qs(data) {
  return new URLSearchParams(data).toString();
}

async function api(method, path, body) {
  const options = { method, headers: { ...window.HarvisRuntime.bearerHeaders(tokenInput) } };
  if (body) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const response = await fetch(path, options);
  const payload = await response.json();
  if (!payload.ok) {
    const message = payload.error ? payload.error.message : "API request failed.";
    throw new Error(message);
  }
  return { ...payload, data: window.HarvisRuntime.scrub(payload.data, runtimeRoot) };
}

function writeOutput(kind, payload) {
  outputKind.textContent = kind;
  outputLog.textContent = JSON.stringify(payload, null, 2);
}

function itemTemplate(title, meta, code) {
  const node = document.createElement("div");
  node.className = "item";
  const strong = document.createElement("strong");
  strong.textContent = title;
  node.appendChild(strong);
  if (meta) {
    const span = document.createElement("span");
    span.textContent = meta;
    node.appendChild(span);
  }
  if (code) {
    const codeNode = document.createElement("code");
    codeNode.textContent = code;
    node.appendChild(codeNode);
  }
  return node;
}

function renderPackets(packets) {
  packetList.innerHTML = "";
  packetList.classList.toggle("empty", packets.length === 0);
  packetCount.textContent = String(packets.length);
  if (!packets.length) {
    packetList.textContent = "No packets.";
    return;
  }
  for (const packet of packets) {
    packetList.appendChild(
      itemTemplate(
        packet.workspace_path || packet.path,
        `status: ${packet.status || "unknown"} | bytes: ${packet.bytes || 0}`,
        packet.preview || "",
      ),
    );
  }
}

function renderEvents(events) {
  eventList.innerHTML = "";
  eventList.classList.toggle("empty", events.length === 0);
  eventCount.textContent = String(events.length);
  if (!events.length) {
    eventList.textContent = "No events.";
    return;
  }
  for (const event of events.slice().reverse()) {
    eventList.appendChild(
      itemTemplate(
        event.type || "event",
        event.at || event.status || "",
        JSON.stringify(event),
      ),
    );
  }
}

function deriveBlocked(status, packets) {
  const errors = Array.isArray(status.errors) ? status.errors.length : 0;
  const blockedPackets = packets.filter((packet) => packet.status === "blocked").length;
  return errors > 0 || blockedPackets > 0;
}

async function refreshAll(nextState = "verified") {
  saveInputs();
  setState("reading", "Reading local runtime state.");
  const workspace = root();
  const [statusPayload, packetsPayload, eventsPayload, tasksResult, approvalsResult, handoffsResult, runsResult, integrationsResult] = await Promise.all([
    api("GET", `/status?${qs({ root: workspace })}`),
    api("GET", `/packets?${qs({ root: workspace, limit: 12, include_preview: false })}`),
    api("GET", `/events?${qs({ root: workspace, limit: 12 })}`),
    api("GET", `/agent-room/tasks?${qs({ root: workspace, limit: 40 })}`).catch(() => null),
    api("GET", `/approvals?${qs({ root: workspace, limit: 50 })}`).catch(() => null),
    api("GET", `/handoffs?${qs({ root: workspace, limit: 30 })}`).catch(() => null),
    api("GET", `/runs?${qs({ root: workspace, limit: 20 })}`).catch(() => null),
    api("GET", `/ui/integrations?${qs({ root: workspace })}`).catch(() => null),
  ]);

  const status = statusPayload.data.status;
  const packets = packetsPayload.data.packets || [];
  const events = eventsPayload.data.events || [];
  const errors = Array.isArray(status.errors) ? status.errors.length : 0;
  const packetTotal = packets.length || Object.values(status.packet_status_counts || {}).reduce((a, b) => a + b, 0);

  runtimeStamp.textContent = status.last_tick_at || "synced";
  packetMetric.textContent = String(packetTotal);
  errorMetric.textContent = String(errors);
  modeMetric.textContent = status.mode || "-";
  renderPackets(packets);
  renderEvents(events);

  const tasks = asArray(tasksResult && tasksResult.data && (tasksResult.data.tasks || tasksResult.data.items));
  const approvals = asArray(approvalsResult && approvalsResult.data && approvalsResult.data.approvals);
  const handoffs = asArray(handoffsResult && handoffsResult.data && handoffsResult.data.handoffs);
  const runs = asArray(runsResult && runsResult.data && runsResult.data.runs);
  const pending = approvals.filter((entry) => !entry.status || ["pending", "waiting", "requested"].includes(String(entry.status).toLowerCase()));
  const activeRun = runs.find((entry) => statusIsActive(entry.state || entry.status)) || null;
  const blockedCount = tasks.filter((entry) => statusIsBlocked(entry.status)).length
    + runs.filter((entry) => statusIsBlocked(entry.state || entry.status)).length
    + packets.filter((entry) => statusIsBlocked(entry.status)).length;
  const lark = integrationsResult && integrationsResult.data && integrationsResult.data.lark;
  const listenerOnline = Boolean(lark && lark.listener_health === "online");
  const larkVerified = Boolean(listenerOnline && lark.smoke && lark.smoke.live_complete && lark.membership_status === "verified");

  shell.dataset.uiState = blockedCount ? "blocked" : pending.length ? "approval" : "success";
  shell.setAttribute("aria-busy", "false");
  const commandDeck = document.querySelector(".panel-command-deck");
  commandDeck.dataset.uiState = shell.dataset.uiState;
  commandDeck.setAttribute("aria-busy", "false");
  setSignal(healthSignal, healthValue, healthDetail, "Healthy", "Local runtime is reachable.", "verified");
  setSignal(activeSignal, activeValue, activeDetail, activeRun ? "Running" : "None", activeRun ? `${String(activeRun.state || activeRun.status).replaceAll("_", " ")} · ${shortRef(activeRun.run_id)}` : "No approved action is running.", activeRun ? "acting" : "idle");
  setSignal(blockedSignal, blockedValue, blockedDetail, String(blockedCount), blockedCount ? "Stopped work needs evidence review." : "No work is stopped.", blockedCount ? "blocked" : "idle");
  setSignal(approvalSignal, approvalValue, approvalDetail, String(pending.length), pending.length ? "Explicit decisions are waiting." : "No decision is waiting.", pending.length ? "thinking" : "idle");
  setSignal(
    larkSignal, larkValue, larkDetail,
    larkVerified ? "Verified" : listenerOnline ? "Listeners online" : "Needs attention",
    lark ? `Live E2E ${larkVerified ? "verified" : "pending owner confirmation"}.` : "Bridge evidence unavailable; no success inferred.",
    larkVerified ? "verified" : listenerOnline ? "thinking" : "blocked",
  );
  renderLineage(explicitLineage(tasks, approvals, handoffs, runs));

  let next = { state: "success", title: "No urgent action", detail: "Runtime is healthy and no decision is waiting.", impact: "Read-only · no state change", href: "/studio/?view=work" };
  if (pending.length) next = { state: "approval", title: `Review ${pending.length} pending decision${pending.length === 1 ? "" : "s"}`, detail: "Inspect risk, scope, impact, and evidence before deciding.", impact: "State change requires confirmation", href: "/studio/?view=review" };
  else if (blockedCount) next = { state: "blocked", title: "Inspect blocked work", detail: "Open the explicit lineage and find the first stopped stage.", impact: "Read-only until an approval is requested", href: "/studio/?view=work" };
  else if (activeRun) next = { state: "active", title: "Follow the active run", detail: "Monitor this run through verification and review.", impact: "Read-only monitoring", href: "/studio/?view=work" };
  else if (!larkVerified) next = { state: "blocked", title: "Complete Lark live verification", detail: listenerOnline ? "Listeners are online; group membership and live E2E still need owner confirmation." : "Restore listener evidence before live verification.", impact: "No message will be sent from this screen", href: "/studio/?view=bridge" };
  nextAction.dataset.state = next.state;
  nextTitle.textContent = next.title;
  nextDetail.textContent = next.detail;
  nextImpact.textContent = next.impact;
  nextLink.href = next.href;

  const fixtureRendered = renderFixture();

  if (fixtureRendered) {
    setState(window.HarvisOperator.fixtureName() === "error" ? "blocked" : "verified", "Fixture evidence rendered.");
  } else if (deriveBlocked(status, packets)) {
    setState("blocked", "Human review required.");
  } else {
    setState(nextState, "Runtime synchronized.");
  }
  writeOutput("status", statusPayload.data);
  shell.dataset.connected = "true";
}

async function runAction(kind, request) {
  saveInputs();
  const actionState = kind === "scan" ? "reading" : kind === "tick" ? "acting" : "thinking";
  setState(actionState, `${kind} in progress.`);
  const payload = await request();
  writeOutput(kind, payload.data);
  await refreshAll("verified");
}

async function confirmAction(kind, detail, impact, request, button) {
  const approved = await window.HarvisOperator.confirm(confirmDialog, {
    title: `Confirm ${kind}`,
    detail,
    impact,
    accept: `Run ${kind}`,
    danger: kind === "tick",
  });
  if (!approved) return;
  await window.HarvisOperator.action(button, () => runAction(kind, request), {
    loading: `Running ${kind}…`, success: `${kind} complete`, error: `${kind} failed`,
  });
}

function guard(handler) {
  return async () => {
    try {
      await handler();
    } catch (error) {
      setState("blocked", error.message);
      writeOutput("error", { message: error.message });
    }
  };
}

buttons.refresh.addEventListener("click", guard(() => refreshAll("verified")));
buttons.scan.addEventListener("click", guard(() =>
  confirmAction("scan", "Scan the inbox and create packets for newly discovered work.", "Scope: current workspace inbox · may create packet state", () => api("POST", "/scan-inbox", { root: root() }), buttons.scan),
));
buttons.tick.addEventListener("click", guard(() =>
  confirmAction("tick", "Advance the local runtime by one approved scheduling tick.", "Scope: current workspace · may update run, event, and approval state", () => api("POST", "/run-tick", { root: root(), profile_root: profileRoot(), interval: 5 }), buttons.tick),
));
buttons.snapshot.addEventListener("click", guard(() =>
  confirmAction("snapshot", "Create a local memory snapshot from the current approved state.", "Scope: local profile · writes a reviewable snapshot", () => api("POST", "/memory-snapshot", { root: root(), profile_root: profileRoot(), max_excerpt_chars: 240 }), buttons.snapshot),
));
buttons.workbench.addEventListener("click", guard(() =>
  confirmAction("workbench", "Prepare one reviewable workbench item from current candidates.", "Scope: one item · no automatic adoption", () => api("POST", "/prepare-workbench", { root: root(), profile_root: profileRoot(), limit: 1 }), buttons.workbench),
));

profileInput.addEventListener("change", saveInputs);
tokenInput.addEventListener("change", saveInputs);

window.HarvisRuntime.bootstrap()
  .then((bootstrap) => {
    runtimeRoot = bootstrap.workspaceRoot;
    window.HarvisRuntime.applyWorkspaceLabel(rootInput, bootstrap.workspaceLabel);
    return api("GET", "/health");
  })
  .then((payload) => {
    writeOutput("health", payload.data);
    if (runtimeRoot) {
      return refreshAll("verified");
    }
    setState("idle", "Awaiting workspace.");
    return null;
  })
  .catch((error) => {
    setState("blocked", error.message);
    writeOutput("error", { message: error.message });
  });

window.setInterval(() => {
  if (!runtimeRoot) return;
  refreshAll("idle").catch(() => {
    /* Keep explicit user-triggered errors in the output panel. */
  });
}, 15000);
