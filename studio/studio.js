const $ = (id) => document.getElementById(id);

const els = {
  rootInput: $("rootInput"),
  tokenInput: $("tokenInput"),
  refreshButton: $("refreshButton"),
  initButton: $("initButton"),
  viewTitle: $("viewTitle"),
  runtimeState: $("runtimeState"),
  permissionState: $("permissionState"),
  reviewState: $("reviewState"),
  sideResidentState: $("sideResidentState"),
  sideResidentMeta: $("sideResidentMeta"),
  cockpitHeadline: $("cockpitHeadline"),
  cockpitSummary: $("cockpitSummary"),
  cockpitPresence: $("cockpitPresence"),
  cockpitOnline: $("cockpitOnline"),
  cockpitPermission: $("cockpitPermission"),
  cockpitReview: $("cockpitReview"),
  cockpitGraph: $("cockpitGraph"),
  activeTwinName: $("activeTwinName"),
  activeTwinMeta: $("activeTwinMeta"),
  activePersonaTag: $("activePersonaTag"),
  activeVaultTag: $("activeVaultTag"),
  activePermissionTag: $("activePermissionTag"),
  healthStamp: $("healthStamp"),
  healthList: $("healthList"),
  dashboardPortsMetric: $("dashboardPortsMetric"),
  dashboardPortsList: $("dashboardPortsList"),
  harnessPoolMetric: $("harnessPoolMetric"),
  harnessSmokeButton: $("harnessSmokeButton"),
  harnessPoolList: $("harnessPoolList"),
  harnessPresetList: $("harnessPresetList"),
  harnessModelList: $("harnessModelList"),
  harnessPolicyList: $("harnessPolicyList"),
  portImportantState: $("portImportantState"),
  portSummary: $("portSummary"),
  portList: $("portList"),
  portRefreshButton: $("portRefreshButton"),
  queueCount: $("queueCount"),
  pendingQueue: $("pendingQueue"),
  personaCount: $("personaCount"),
  vaultCount: $("vaultCount"),
  runCount: $("runCount"),
  approvalCount: $("approvalCount"),
  dashboardGraphMode: $("dashboardGraphMode"),
  dashboardGraphStage: $("dashboardGraphStage"),
  dashboardGraphMini: $("dashboardGraphMini"),
  dashboardGraphSource: $("dashboardGraphSource"),
  dashboardGraphTags: $("dashboardGraphTags"),
  dashboardGraphFocus: $("dashboardGraphFocus"),
  firstRunSummary: $("firstRunSummary"),
  firstRunList: $("firstRunList"),
  firstRunRefreshButton: $("firstRunRefreshButton"),
  recentRuns: $("recentRuns"),
  routerMetric: $("routerMetric"),
  routerEvents: $("routerEvents"),
  agentSummary: $("agentSummary"),
  workbenchMetric: $("workbenchMetric"),
  workbenchChair: $("workbenchChair"),
  workbenchSummary: $("workbenchSummary"),
  workbenchSlots: $("workbenchSlots"),
  workbenchTasks: $("workbenchTasks"),
  workbenchMailbox: $("workbenchMailbox"),
  workbenchConversations: $("workbenchConversations"),
  workbenchLinkedContext: $("workbenchLinkedContext"),
  workbenchChainDetail: $("workbenchChainDetail"),
  workbenchCodexPins: $("workbenchCodexPins"),
  workbenchCodexBindings: $("workbenchCodexBindings"),
  workbenchRunTimeline: $("workbenchRunTimeline"),
  workbenchTeamHarness: $("workbenchTeamHarness"),
  workbenchApprovals: $("workbenchApprovals"),
  workbenchRouterEvents: $("workbenchRouterEvents"),
  handoffMetric: $("handoffMetric"),
  handoffList: $("handoffList"),
  topicButton: $("topicButton"),
  personaList: $("personaList"),
  personaButton: $("personaButton"),
  editorStatus: $("editorStatus"),
  personaNameInput: $("personaNameInput"),
  visualAssetInput: $("visualAssetInput"),
  warmthInput: $("warmthInput"),
  directnessInput: $("directnessInput"),
  humorInput: $("humorInput"),
  detailInput: $("detailInput"),
  encouragementInput: $("encouragementInput"),
  criticismInput: $("criticismInput"),
  warmthValue: $("warmthValue"),
  directnessValue: $("directnessValue"),
  humorValue: $("humorValue"),
  detailValue: $("detailValue"),
  encouragementValue: $("encouragementValue"),
  criticismValue: $("criticismValue"),
  evidenceInput: $("evidenceInput"),
  challengeInput: $("challengeInput"),
  verificationInput: $("verificationInput"),
  riskInput: $("riskInput"),
  rulesInput: $("rulesInput"),
  savePersonaButton: $("savePersonaButton"),
  copyButton: $("copyButton"),
  candidateButton: $("candidateButton"),
  testPromptInput: $("testPromptInput"),
  runTestButton: $("runTestButton"),
  testPersonaName: $("testPersonaName"),
  personaPreview: $("personaPreview"),
  defaultPreview: $("defaultPreview"),
  builderStatus: $("builderStatus"),
  builderSteps: $("builderSteps"),
  builderStepTitle: $("builderStepTitle"),
  builderStepHint: $("builderStepHint"),
  builderVaultSelect: $("builderVaultSelect"),
  builderVaultMeta: $("builderVaultMeta"),
  builderPersonaSelect: $("builderPersonaSelect"),
  builderPersonaMeta: $("builderPersonaMeta"),
  builderVisualInput: $("builderVisualInput"),
  builderAppearanceSelect: $("builderAppearanceSelect"),
  builderBehaviorInput: $("builderBehaviorInput"),
  builderBehaviorMeta: $("builderBehaviorMeta"),
  builderPermRead: $("builderPermRead"),
  builderPermWriteCandidate: $("builderPermWriteCandidate"),
  builderPermWriteAccepted: $("builderPermWriteAccepted"),
  builderRunToolsSelect: $("builderRunToolsSelect"),
  builderTwinNameInput: $("builderTwinNameInput"),
  builderCreateButton: $("builderCreateButton"),
  builderCreateResult: $("builderCreateResult"),
  builderTestPromptInput: $("builderTestPromptInput"),
  builderTestButton: $("builderTestButton"),
  builderTestPreview: $("builderTestPreview"),
  builderPrevButton: $("builderPrevButton"),
  builderNextButton: $("builderNextButton"),
  builderPreviewState: $("builderPreviewState"),
  builderPreviewVault: $("builderPreviewVault"),
  builderPreviewPersona: $("builderPreviewPersona"),
  builderPreviewAppearance: $("builderPreviewAppearance"),
  builderPreviewPermissions: $("builderPreviewPermissions"),
  memorySnapshotButton: $("memorySnapshotButton"),
  reviewPersonalityCount: $("reviewPersonalityCount"),
  reviewMemoryCount: $("reviewMemoryCount"),
  reviewApprovalCount: $("reviewApprovalCount"),
  reviewCenterStatus: $("reviewCenterStatus"),
  reviewFilter: $("reviewFilter"),
  reviewList: $("reviewList"),
  reviewDetailTitle: $("reviewDetailTitle"),
  reviewDetailKind: $("reviewDetailKind"),
  reviewDetailBody: $("reviewDetailBody"),
  reviewEvidenceList: $("reviewEvidenceList"),
  reviewApproveButton: $("reviewApproveButton"),
  reviewRejectButton: $("reviewRejectButton"),
  reviewDeferButton: $("reviewDeferButton"),
  graphStatus: $("graphStatus"),
  graphNoteCount: $("graphNoteCount"),
  graphEdgeCount: $("graphEdgeCount"),
  graphTagCount: $("graphTagCount"),
  graphMissingCount: $("graphMissingCount"),
  graphSource: $("graphSource"),
  graphWarnings: $("graphWarnings"),
  graphSearchInput: $("graphSearchInput"),
  graphTagFilter: $("graphTagFilter"),
  graphModeSelect: $("graphModeSelect"),
  graphStage: $("graphStage"),
  graphSvg: $("graphSvg"),
  graphDetailTitle: $("graphDetailTitle"),
  graphDetailType: $("graphDetailType"),
  graphDetailMeta: $("graphDetailMeta"),
  graphRelatedList: $("graphRelatedList"),
  vaultList: $("vaultList"),
  candidateList: $("candidateList"),
  outputLog: $("outputLog"),
  consoleStatus: $("consoleStatus"),
  consoleStatusButton: $("consoleStatusButton"),
  consoleChannelInput: $("consoleChannelInput"),
  consoleSenderInput: $("consoleSenderInput"),
  consoleMessageIdInput: $("consoleMessageIdInput"),
  consoleMessageInput: $("consoleMessageInput"),
  consoleSendButton: $("consoleSendButton"),
  consoleClearButton: $("consoleClearButton"),
  consoleResultBadge: $("consoleResultBadge"),
  consoleSummary: $("consoleSummary"),
  consoleProjectCount: $("consoleProjectCount"),
  consoleProjects: $("consoleProjects"),
  consoleAgentPoolCount: $("consoleAgentPoolCount"),
  consoleAgentPools: $("consoleAgentPools"),
  consoleRawOutput: $("consoleRawOutput"),
  opHealthSignal: $("opHealthSignal"),
  opHealthValue: $("opHealthValue"),
  opHealthDetail: $("opHealthDetail"),
  opActiveSignal: $("opActiveSignal"),
  opActiveValue: $("opActiveValue"),
  opActiveDetail: $("opActiveDetail"),
  opBlockedSignal: $("opBlockedSignal"),
  opBlockedValue: $("opBlockedValue"),
  opBlockedDetail: $("opBlockedDetail"),
  opApprovalSignal: $("opApprovalSignal"),
  opApprovalValue: $("opApprovalValue"),
  opApprovalDetail: $("opApprovalDetail"),
  opLarkSignal: $("opLarkSignal"),
  opLarkValue: $("opLarkValue"),
  opLarkDetail: $("opLarkDetail"),
  opNextAction: $("opNextAction"),
  opNextTitle: $("opNextTitle"),
  opNextDetail: $("opNextDetail"),
  opNextButton: $("opNextButton"),
  opNextImpact: $("opNextImpact"),
  opOverviewLineage: $("opOverviewLineage"),
  opWorkLineage: $("opWorkLineage"),
  opWorkSummary: $("opWorkSummary"),
  opWorkQueue: $("opWorkQueue"),
  opWorkQueueCount: $("opWorkQueueCount"),
  opLarkSummary: $("opLarkSummary"),
  opLarkRoles: $("opLarkRoles"),
  opLarkListeners: $("opLarkListeners"),
  opLarkAge: $("opLarkAge"),
  opLarkDuplicate: $("opLarkDuplicate"),
  opLarkScope: $("opLarkScope"),
  opLarkMembership: $("opLarkMembership"),
  opLarkRefreshButton: $("opLarkRefreshButton"),
  operatorConfirmDialog: $("operatorConfirmDialog"),
};

const viewParams = new URLSearchParams(window.location.search);
let runtimeRoot = "";

const state = {
  health: null,
  bar: null,
  permission: null,
  persona: null,
  room: null,
  workspaceState: null,
  tasks: null,
  conversations: null,
  conversationBindings: null,
  handoffs: null,
  runs: null,
  runTimeline: null,
  codexBindings: null,
  codexPins: null,
  teamHarness: null,
  events: null,
  routerEvents: null,
  approvals: null,
  memoryCandidates: null,
  graph: null,
  projects: null,
  agentPools: null,
  agentHarnesses: null,
  ports: null,
  integrations: null,
  integrationError: "",
  consoleResult: null,
  errors: [],
  selectedPersonaId: "",
  builderStep: 0,
  builderVaultId: "",
  builderPersonaId: "",
  builderCreatedTwin: null,
  selectedReviewKey: "",
  selectedGraphNodeId: "",
  selectedLinkedContextKey: "",
};

function saveInputs() {
  // Workspace and credential are intentionally page-memory only.
}

function workspaceRoot() {
  const value = runtimeRoot;
  if (!value) {
    throw new Error("Workspace root is required.");
  }
  return value;
}

function profileRoot() {
  return "~/.harvis";
}

function qs(data) {
  return new URLSearchParams(data).toString();
}

async function api(method, path, body) {
  const controller = new AbortController();
  const timeoutMs = path === "/agent/step" ? 12000 : 6000;
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
  const options = {
    method,
    headers: { ...window.HarvisRuntime.bearerHeaders(els.tokenInput) },
    signal: controller.signal,
  };
  if (body) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  try {
    const response = await fetch(path, options);
    const payload = await response.json();
    if (!payload.ok) {
      const message = payload.error && payload.error.message ? payload.error.message : "Request failed.";
      throw new Error(message);
    }
    return window.HarvisRuntime.scrub(payload.data, runtimeRoot);
  } catch (error) {
    if (error && error.name === "AbortError") {
      throw new Error(`Request timed out after ${timeoutMs}ms: ${path}`);
    }
    throw error;
  } finally {
    window.clearTimeout(timeoutId);
  }
}

async function safe(label, promise) {
  try {
    return { ok: true, data: await promise };
  } catch (error) {
    return { ok: false, label, error: error.message || String(error) };
  }
}

async function runLimitedRequests(requests, concurrency = 3) {
  const results = new Array(requests.length);
  let nextIndex = 0;
  async function worker() {
    while (nextIndex < requests.length) {
      const index = nextIndex;
      nextIndex += 1;
      const request = requests[index];
      results[index] = await safe(request.key, request.run());
    }
  }
  const workerCount = Math.min(Math.max(1, concurrency), requests.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return results;
}

function normalizeRuntimeState(value, fallback = "idle") {
  const label = String(value || "").toLowerCase().replaceAll("_", "-").trim();
  const canonical = ["idle", "reading", "thinking", "acting", "verified", "blocked"];
  if (canonical.includes(label)) {
    return label;
  }
  if (["online", "ready", "healthy", "ok", "seen"].includes(label)) {
    return "verified";
  }
  if (["degraded", "offline", "down", "failed", "error", "warn", "blocked-review", "approval-required", "waiting-approval"].includes(label)) {
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

function setRuntime(label, tone = "") {
  const normalized = normalizeRuntimeState(label);
  els.runtimeState.textContent = normalized;
  els.runtimeState.dataset.state = normalized;
  els.runtimeState.dataset.tone = tone;
  els.sideResidentState.textContent = normalized;
  if (els.cockpitPresence) {
    els.cockpitPresence.dataset.state = normalized;
  }
}

function item(title, meta = "", badge = "") {
  const row = document.createElement("div");
  row.className = "item";
  const copy = document.createElement("div");
  const strong = document.createElement("strong");
  strong.textContent = title || "Untitled";
  const small = document.createElement("small");
  small.textContent = meta || "";
  copy.append(strong, small);
  row.append(copy);
  if (badge) {
    const tag = document.createElement("span");
    tag.className = "mini-tag";
    tag.textContent = badge;
    row.append(tag);
  }
  return row;
}

function setStack(container, children, emptyText) {
  container.innerHTML = "";
  if (!children.length) {
    container.classList.add("empty");
    container.textContent = emptyText;
    return;
  }
  container.classList.remove("empty");
  for (const child of children) {
    container.append(child);
  }
}

function portBadge(port) {
  if (!port.listening) {
    return "stopped";
  }
  const autostart = port.autostart || {};
  if (port.important && autostart.loaded && autostart.plistPresent) {
    return "autostart";
  }
  if (port.important) {
    return "important";
  }
  return port.known ? "known" : "local";
}

function portMeta(port) {
  const parts = [
    `${port.function || "Unregistered local listener"}`,
    `:${port.port}`,
    port.process ? `process ${port.process}` : "",
    port.uptime ? `up ${port.uptime}` : "",
    port.autostart && port.autostart.label ? `launchd ${port.autostart.loaded ? "loaded" : "not loaded"}` : "manual",
  ].filter(Boolean);
  return parts.join(" · ");
}

function portItem(port, compact = false) {
  const row = document.createElement("div");
  row.className = "port-card";
  row.dataset.important = String(Boolean(port.important));
  row.dataset.listening = String(Boolean(port.listening));
  const copy = document.createElement("div");
  const strong = document.createElement("strong");
  strong.textContent = port.label || `Port ${port.port}`;
  const small = document.createElement("small");
  small.textContent = compact ? portMeta(port).replace(/^.*? · /, "") : portMeta(port);
  copy.append(strong, small);
  const actions = document.createElement("div");
  actions.className = "port-card-actions";
  const badge = document.createElement("span");
  badge.className = "mini-tag";
  badge.textContent = portBadge(port);
  actions.append(badge);
  if (port.url && !compact) {
    const link = document.createElement("a");
    link.className = "button-link soft-action";
    link.href = port.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = "Open";
    actions.append(link);
  }
  row.append(copy, actions);
  return row;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function formatDate(value) {
  if (!value) {
    return "-";
  }
  if (typeof value === "number") {
    return new Date(value * 1000).toLocaleString();
  }
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? String(value) : new Date(parsed).toLocaleString();
}

function labelForStatus(status) {
  return status ? String(status).replaceAll("_", " ") : "unknown";
}

function routerEventMeta(event) {
  const parts = [];
  const preset = event.selected_preset && typeof event.selected_preset === "object"
    ? event.selected_preset.preset_id
    : event.selected_preset;
  if (preset) {
    parts.push(`preset ${preset}`);
  }
  if (event.repo_lookup) {
    const count = event.repo_lookup.count ?? asArray(event.repo_lookup.items).length;
    parts.push(`${count || 0} repo`);
  }
  if (event.task_enqueue) {
    parts.push(`${event.task_enqueue.packet_count || 0} packet`);
    if (event.task_enqueue.selected_preset && !preset) {
      parts.push(`preset ${event.task_enqueue.selected_preset}`);
    }
  }
  if (!parts.length && event.agent_pools) {
    parts.push(`${event.agent_pools.preset_count || 0} presets`);
  }
  parts.push(formatDate(event.recorded_at));
  return parts.filter(Boolean).join(" · ");
}

function targetLabel(target) {
  if (typeof target === "string") {
    return target;
  }
  if (target && typeof target === "object") {
    return [target.kind, target.display].filter(Boolean).join(": ") || JSON.stringify(target);
  }
  return "";
}

function currentPersonaCards() {
  return asArray(state.persona && state.persona.persona_cards);
}

function currentVaults() {
  return asArray(state.persona && state.persona.memory_vaults);
}

function currentTwins() {
  return asArray(state.persona && state.persona.twin_instances);
}

function currentMemoryCandidates() {
  return asArray(state.memoryCandidates && state.memoryCandidates.candidates);
}

function memoryCandidateRequiresReview(candidate) {
  const adoption = candidate && candidate.adoption ? candidate.adoption : {};
  return Boolean(candidate && (candidate.requires_review === true || adoption.requires_human_review === true));
}

function reviewableMemoryCandidates() {
  return currentMemoryCandidates().filter((candidate) => {
    const status = String(candidate.status || "candidate").toLowerCase();
    const adoption = candidate.adoption || {};
    const adoptionStatus = String(adoption.status || "not_adopted").toLowerCase();
    return memoryCandidateRequiresReview(candidate)
      && !["accepted", "adopted", "rejected", "dismissed", "obsolete"].includes(status)
      && !["adopted", "rejected", "dismissed"].includes(adoptionStatus);
  });
}

function selectedPersona() {
  const cards = currentPersonaCards();
  return cards.find((persona) => persona.persona_id === state.selectedPersonaId) || cards[0] || null;
}

function findPersona(personaId) {
  return currentPersonaCards().find((persona) => persona.persona_id === personaId) || null;
}

function findVault(vaultId) {
  return currentVaults().find((vault) => vault.vault_id === vaultId) || null;
}

function permissionSummary() {
  const permission = state.permission;
  if (!permission) {
    return { ok: false, text: "permission unknown", detail: "Probe has not run." };
  }
  if (permission.permission_timeout) {
    return {
      ok: false,
      text: "permission timeout",
      detail: `Resident service timed out while probing ${permission.root || "workspace root"}. Grant Full Disk Access or restart the service in a session that can read the external volume.`,
    };
  }
  const blocked = asArray(permission.checks).filter((check) => check.ok === false);
  if (permission.ok && !blocked.length) {
    return { ok: true, text: "permission ok", detail: "Workspace and profile probes passed." };
  }
  return {
    ok: false,
    text: "permission blocked",
    detail: blocked.map((check) => `${check.name || check.label || "Workspace access"}: ${check.message || "blocked"}`).join("; ") || "Probe failed.",
  };
}

function firstRunSteps() {
  const permission = permissionSummary();
  const serviceHealth = state.bar && state.bar.serviceHealth ? state.bar.serviceHealth : {};
  const workspace = state.bar && state.bar.workspace ? state.bar.workspace : {};
  const hasWorkspace = Boolean(workspace.configured || workspaceRoot());
  const hasProfile = Boolean(profileRoot());
  const hasToken = Boolean(els.tokenInput.value.trim());
  const httpReady = serviceHealth.http === "running" || Boolean(state.health);
  const tickReady = ["running", "idle", "available"].includes(String(serviceHealth.tickRunner || "").toLowerCase());
  return [
    {
      title: "Workspace",
      detail: hasWorkspace ? "Workspace root is selected." : "Choose the local workspace.",
      ok: hasWorkspace,
    },
    {
      title: "Profile",
      detail: hasProfile ? "Profile root is selected." : "Set the local profile root.",
      ok: hasProfile,
    },
    {
      title: "HTTP Token",
      detail: hasToken ? "Bearer token is available in this Studio session." : "Open via HarvisBar or paste the local token.",
      ok: hasToken,
    },
    {
      title: "Full Disk Access",
      detail: permission.ok ? permission.detail : "Grant access if external-volume probes fail.",
      ok: permission.ok,
    },
    {
      title: "LaunchAgent",
      detail: httpReady && tickReady ? "HTTP and tick runner are visible." : "Start resident services from HarvisBar.",
      ok: httpReady && tickReady,
    },
  ];
}

function renderFirstRun() {
  const steps = firstRunSteps();
  const ready = steps.filter((step) => step.ok).length;
  els.firstRunSummary.textContent = `${ready}/${steps.length} ready`;
  els.firstRunList.innerHTML = "";
  for (const step of steps) {
    const row = document.createElement("div");
    row.className = "first-run-step";
    row.dataset.state = step.ok ? "ready" : "blocked";
    const mark = document.createElement("span");
    mark.className = "first-run-mark";
    mark.textContent = step.ok ? "OK" : "!";
    const copy = document.createElement("div");
    const title = document.createElement("strong");
    title.textContent = step.title;
    const detail = document.createElement("small");
    detail.textContent = step.detail;
    copy.append(title, detail);
    row.append(mark, copy);
    els.firstRunList.append(row);
  }
}

function pendingItems() {
  const candidates = asArray(state.persona && state.persona.pending_personality_review).map((candidate) => ({
    title: candidate.trait || candidate.candidate_id,
    meta: `personality review -> ${candidate.target_persona_id || "persona"}`,
    badge: "persona",
  }));
  const approvals = asArray(state.approvals && state.approvals.approvals)
    .filter((approval) => !approval.status || approval.status === "pending")
    .map((approval) => ({
      title: approval.action_type || approval.approval_id,
      meta: targetLabel(approval.target) || approval.run_id || "approval item",
      badge: "approval",
    }));
  const memory = reviewableMemoryCandidates().map((candidate) => ({
    title: candidate.summary || candidate.name,
    meta: `memory candidate -> ${candidate.name || "signal"}`,
    badge: "memory",
  }));
  return [...candidates, ...memory, ...approvals];
}

function renderRuntime() {
  const permission = permissionSummary();
  const pending = pendingItems();
  const barState = state.bar && state.bar.runtime ? state.bar.runtime.state : "";
  const healthOk = Boolean(state.health);
  const label = normalizeRuntimeState(barState || (healthOk ? "verified" : "blocked"), healthOk ? "verified" : "blocked");
  setRuntime(label, healthOk && permission.ok ? "ok" : "warn");
  els.permissionState.textContent = permission.text;
  els.permissionState.title = permission.detail;
  els.reviewState.textContent = `${pending.length} pending`;
  els.sideResidentMeta.textContent = state.health ? `HTTP ${state.health.api_version || "local"}` : "localhost unavailable";
}

function runtimeTasks() {
  const workspaceTasks = asArray(state.workspaceState && state.workspaceState.open_tasks);
  return workspaceTasks.length ? workspaceTasks : asArray(state.tasks && (state.tasks.tasks || state.tasks.items));
}

function runtimeApprovals() {
  return asArray(state.approvals && state.approvals.approvals);
}

function pendingApprovals() {
  return runtimeApprovals().filter((approval) => !approval.status || ["pending", "waiting", "requested"].includes(String(approval.status).toLowerCase()));
}

function runtimeRuns() {
  return asArray(state.runs && state.runs.runs);
}

function runtimeHandoffs() {
  return asArray(state.handoffs && state.handoffs.handoffs);
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

function setOperatorSignal(node, valueNode, detailNode, value, detail, runtimeState) {
  if (!node) return;
  node.dataset.state = runtimeState;
  node.dataset.runtimeState = runtimeState;
  valueNode.textContent = value;
  detailNode.textContent = detail;
}

function operatorLineage() {
  const tasks = runtimeTasks();
  const approvals = runtimeApprovals();
  const handoffs = runtimeHandoffs();
  const runs = runtimeRuns();
  const task = tasks.find((entry) => statusIsActive(entry.status) || statusIsBlocked(entry.status) || entry.approval_id) || tasks[0] || null;
  const approvalId = task && task.approval_id;
  const approval = approvalId ? approvals.find((entry) => entry.approval_id === approvalId) || null : null;
  const handoffId = (task && task.handoff_id) || (approval && approval.handoff_id) || "";
  const handoff = handoffId ? handoffs.find((entry) => entry.handoff_id === handoffId) || null : null;
  const runId = (task && task.run_id) || (approval && approval.run_id) || (handoff && handoff.run_id) || "";
  const run = runId ? runs.find((entry) => entry.run_id === runId) || null : null;
  const taskState = task ? (statusIsBlocked(task.status) ? "blocked" : "verified") : "idle";
  const approvalStatus = approval && approval.status;
  const approvalState = !approval ? "idle" : statusIsBlocked(approvalStatus) ? "blocked" : statusIsComplete(approvalStatus) ? "verified" : "thinking";
  const handoffStatus = handoff && handoff.state;
  const handoffState = !handoff ? "idle" : statusIsBlocked(handoffStatus) ? "blocked" : statusIsComplete(handoffStatus) ? "verified" : "acting";
  const runStatus = run && (run.state || run.status);
  const runState = !run ? "idle" : statusIsBlocked(runStatus) ? "blocked" : statusIsComplete(runStatus) ? "verified" : "acting";
  const reviewState = handoff && /reviewed|done|complete/.test(String(handoffStatus || "").toLowerCase()) ? "verified" : "idle";
  return {
    task,
    approval,
    handoff,
    run,
    steps: [
      { stage: "task", state: taskState, detail: task ? `${labelForStatus(task.status)} · ${shortRef(task.task_id)}` : "not linked" },
      { stage: "approval", state: approvalState, detail: approval ? `${labelForStatus(approval.status)} · ${approval.risk || "risk noted"}` : "not linked" },
      { stage: "handoff", state: handoffState, detail: handoff ? `${labelForStatus(handoff.state)} · ${shortRef(handoff.handoff_id)}` : "not linked" },
      { stage: "run", state: runState, detail: run ? `${labelForStatus(runStatus)} · ${shortRef(run.run_id)}` : "not linked" },
      { stage: "review", state: reviewState, detail: reviewState === "verified" ? "evidence recorded" : "not linked" },
    ],
  };
}

function renderLineage(container, lineage) {
  if (!container) return;
  for (const step of lineage.steps) {
    const node = container.querySelector(`[data-stage="${step.stage}"]`);
    if (!node) continue;
    node.dataset.state = step.state;
    const detail = node.querySelector("small");
    if (detail) detail.textContent = step.detail;
  }
}

function renderOperatorFixture(fixture) {
  const deck = document.querySelector(".op-command-deck");
  if (!fixture || !deck) return false;
  deck.dataset.uiState = fixture.name;
  deck.setAttribute("aria-busy", fixture.name === "loading" ? "true" : "false");
  const stateMap = {
    loading: ["reading", "reading", "idle", "idle", "reading"],
    empty: ["verified", "idle", "idle", "idle", "verified"],
    error: ["blocked", "idle", "blocked", "idle", "blocked"],
    blocked: ["verified", "idle", "blocked", "idle", "verified"],
    permission: ["verified", "idle", "blocked", "idle", "verified"],
    approval: ["verified", "idle", "idle", "thinking", "verified"],
    success: ["verified", "idle", "idle", "idle", "verified"],
  };
  const values = {
    loading: ["Checking", "Unknown", "—", "—", "Checking"],
    empty: ["Healthy", "None", "0 items", "0 pending", "Online"],
    error: ["Unavailable", "Unknown", "1 error", "Unknown", "Needs attention"],
    blocked: ["Healthy", "None", "1 item", "0 pending", "Online"],
    permission: ["Healthy", "None", "Permission", "0 pending", "Online"],
    approval: ["Healthy", "None", "0 items", "1 pending", "Online"],
    success: ["Healthy", "None", "0 items", "0 pending", "Online"],
  };
  const signals = [els.opHealthSignal, els.opActiveSignal, els.opBlockedSignal, els.opApprovalSignal, els.opLarkSignal];
  const valueNodes = [els.opHealthValue, els.opActiveValue, els.opBlockedValue, els.opApprovalValue, els.opLarkValue];
  signals.forEach((signal, index) => {
    signal.dataset.state = stateMap[fixture.name][index];
    signal.dataset.runtimeState = stateMap[fixture.name][index];
    valueNodes[index].textContent = values[fixture.name][index];
  });
  els.opHealthDetail.textContent = fixture.detail;
  els.opBlockedDetail.textContent = fixture.name === "permission" ? "A required scope is missing." : fixture.detail;
  els.opApprovalDetail.textContent = fixture.name === "approval" ? "Impact review is required." : fixture.detail;
  els.opLarkDetail.textContent = fixture.name === "error" ? "No online state inferred." : fixture.detail;
  els.opNextAction.dataset.state = fixture.name;
  els.opNextTitle.textContent = fixture.title;
  els.opNextDetail.textContent = fixture.detail;
  els.opNextImpact.textContent = fixture.next;
  window.HarvisOperator.setButtonState(els.opNextButton, fixture.name === "loading" ? "disabled" : "idle", "Open evidence");
  for (const button of [els.refreshButton, els.initButton]) {
    button.disabled = fixture.name === "loading";
    button.setAttribute("aria-disabled", button.disabled ? "true" : "false");
  }
  if (fixture.name === "loading") {
    document.querySelectorAll(".workspace button").forEach((button) => {
      button.disabled = true;
      button.setAttribute("aria-disabled", "true");
    });
  }
  els.opNextButton.dataset.targetView = ["approval", "blocked", "permission"].includes(fixture.name) ? "review" : "work";
  return true;
}

function renderOperatorOverview() {
  const fixture = window.HarvisOperator.renderFixture(document);
  if (renderOperatorFixture(fixture)) return;
  const deck = document.querySelector(".op-command-deck");
  const permission = permissionSummary();
  const approvals = pendingApprovals();
  const runs = runtimeRuns();
  const tasks = runtimeTasks();
  const activeRun = runs.find((entry) => statusIsActive(entry.state || entry.status)) || null;
  const blockedTasks = tasks.filter((entry) => statusIsBlocked(entry.status));
  const blockedRuns = runs.filter((entry) => statusIsBlocked(entry.state || entry.status));
  const blockedCount = blockedTasks.length + blockedRuns.length;
  const lark = state.integrations && state.integrations.lark;
  const larkOnline = lark && lark.listener_health === "online";
  const larkE2eComplete = Boolean(larkOnline && lark.smoke && lark.smoke.live_complete && lark.membership_status === "verified");
  const healthState = state.health ? "verified" : "blocked";
  deck.dataset.uiState = state.health ? (blockedCount ? "blocked" : approvals.length ? "approval" : "success") : "error";
  deck.setAttribute("aria-busy", "false");
  setOperatorSignal(els.opHealthSignal, els.opHealthValue, els.opHealthDetail, state.health ? "Healthy" : "Unavailable", state.health ? "Local runtime is reachable." : "Read-only health check failed.", healthState);
  setOperatorSignal(els.opActiveSignal, els.opActiveValue, els.opActiveDetail, activeRun ? "Running" : "None", activeRun ? `${labelForStatus(activeRun.state || activeRun.status)} · ${shortRef(activeRun.run_id)}` : "No approved action is running.", activeRun ? "acting" : "idle");
  setOperatorSignal(els.opBlockedSignal, els.opBlockedValue, els.opBlockedDetail, permission.ok ? `${blockedCount} item${blockedCount === 1 ? "" : "s"}` : "Permission", permission.ok ? (blockedCount ? "Work has stopped and needs review." : "No work is stopped.") : "Permission and business state are reported separately.", permission.ok ? (blockedCount ? "blocked" : "idle") : "blocked");
  setOperatorSignal(els.opApprovalSignal, els.opApprovalValue, els.opApprovalDetail, `${approvals.length} pending`, approvals.length ? "Explicit decisions are waiting." : "No decision is waiting.", approvals.length ? "thinking" : "idle");
  setOperatorSignal(
    els.opLarkSignal,
    els.opLarkValue,
    els.opLarkDetail,
    larkE2eComplete ? "Verified" : larkOnline ? "Listeners online" : "Needs attention",
    lark ? `${lark.profiles.length} redacted role(s) · live E2E ${larkE2eComplete ? "verified" : "pending owner confirmation"}` : (state.integrationError || "Bridge evidence unavailable."),
    larkE2eComplete ? "verified" : larkOnline ? "thinking" : "blocked",
  );

  let next = { state: "success", title: "No urgent action", detail: "The runtime is healthy and no decision is waiting.", impact: "Read-only · no state change", target: "work" };
  const coreErrors = state.errors.filter((entry) => ["health", "bar", "workspaceState", "tasks", "runs", "approvals", "refresh"].includes(entry.label));
  if (!state.health || coreErrors.length) {
    next = { state: "error", title: "Restore runtime evidence", detail: "A core read failed. No success state is inferred from partial data.", impact: "Read-only diagnostics", target: "settings" };
  } else if (!permission.ok) {
    next = { state: "permission", title: "Review missing permission", detail: permission.detail, impact: "No access is granted from this screen", target: "review" };
  } else if (approvals.length) {
    next = { state: "approval", title: `Review ${approvals.length} pending decision${approvals.length === 1 ? "" : "s"}`, detail: "Inspect evidence and impact before approve, deny, or defer.", impact: "State change requires confirmation", target: "review" };
  } else if (blockedCount) {
    next = { state: "blocked", title: "Inspect blocked work", detail: "Open the current lineage and identify the first stopped stage.", impact: "Read-only until an approval is requested", target: "work" };
  } else if (activeRun) {
    next = { state: "active", title: "Follow the active run", detail: "Watch the lineage through verification and review.", impact: "Read-only monitoring", target: "work" };
  } else if (!larkE2eComplete) {
    next = { state: "blocked", title: "Complete Lark live verification", detail: "Listener connectivity is separate from owner group membership and live E2E proof.", impact: "No message will be sent from this screen", target: "bridge" };
  }
  els.opNextAction.dataset.state = next.state;
  deck.dataset.uiState = next.state === "active" ? "success" : next.state;
  els.opNextTitle.textContent = next.title;
  els.opNextDetail.textContent = next.detail;
  els.opNextImpact.textContent = next.impact;
  els.opNextButton.dataset.targetView = next.target;
  window.HarvisOperator.setButtonState(els.opNextButton, "idle", "Open evidence");

  const lineage = operatorLineage();
  renderLineage(els.opOverviewLineage, lineage);
  renderLineage(els.opWorkLineage, lineage);
  const title = lineage.task && (lineage.task.title || lineage.task.subject || lineage.task.summary || lineage.task.task_id);
  els.opWorkSummary.textContent = title ? `${title} · IDs remain secondary to stage and evidence.` : "No active lineage selected.";
  const priority = [
    ...approvals.map((entry) => ({ title: entry.action_type || "Approval decision", status: entry.status || "pending", meta: `Risk ${entry.risk || "noted"} · impact ${targetLabel(entry.target) || "current item"}`, badge: "approval" })),
    ...tasks.filter((entry) => statusIsBlocked(entry.status) || statusIsActive(entry.status)).map((entry) => ({ title: entry.title || entry.subject || entry.summary || "Work item", status: entry.status || "open", meta: `Next ${entry.next_action || "inspect evidence"} · ${shortRef(entry.task_id)}`, badge: "work" })),
  ].slice(0, 6);
  els.opWorkQueueCount.textContent = `${priority.length} visible`;
  setStack(els.opWorkQueue, priority.map((entry) => item(entry.title, `${labelForStatus(entry.status)} · ${entry.meta}`, entry.badge)), "No active work.");
}

function renderLarkIntegration() {
  const lark = state.integrations && state.integrations.lark;
  const card = document.querySelector(".op-integration-card");
  if (!lark) {
    card.dataset.uiState = "error";
    els.opLarkSummary.textContent = state.integrationError || "Integration evidence is unavailable; no success state is inferred.";
    for (const node of [els.opLarkRoles, els.opLarkListeners, els.opLarkAge, els.opLarkDuplicate, els.opLarkScope, els.opLarkMembership]) node.textContent = "needs attention";
    return;
  }
  const smoke = lark.smoke || {};
  const liveVerified = lark.listener_health === "online" && smoke.live_complete && lark.membership_status === "verified";
  card.dataset.uiState = liveVerified ? "success" : lark.listener_health === "online" ? "approval" : "blocked";
  const roles = [...new Set(asArray(lark.profiles).map((profile) => profile.profile_role))];
  const online = asArray(lark.profiles).filter((profile) => profile.listener_health === "online").length;
  els.opLarkSummary.textContent = smoke.live_complete
    ? "Fixture and owner-authorized live E2E evidence are complete."
    : "Listener evidence is available; owner-authorized live group E2E remains pending.";
  els.opLarkRoles.textContent = roles.length ? roles.join(" / ") : "unregistered";
  els.opLarkListeners.textContent = `${online}/${asArray(lark.profiles).length} online`;
  const ageSeconds = lark.last_card_action_age_seconds == null ? Number.NaN : Number(lark.last_card_action_age_seconds);
  els.opLarkAge.textContent = window.HarvisOperator.ageLabel(ageSeconds);
  els.opLarkDuplicate.textContent = lark.duplicate_guard;
  els.opLarkScope.textContent = lark.scope_status;
  els.opLarkMembership.textContent = lark.membership_status;
}

function renderDashboard() {
  const personas = currentPersonaCards();
  const vaults = currentVaults();
  const twins = currentTwins();
  const activeTwin = twins.find((twin) => twin.status === "running") || twins[0] || null;
  const activePersona = activeTwin ? findPersona(activeTwin.persona_card_id) : personas[0] || null;
  const activeVault = activeTwin ? findVault(activeTwin.memory_vault_id) : vaults[0] || null;
  const permission = permissionSummary();
  const graphStats = state.graph && state.graph.stats ? state.graph.stats : {};
  const ports = state.ports || {};
  const portCounts = ports.counts || {};
  const portItems = asArray(ports.items);
  const graphLoaded = Boolean(state.graph);
  const pending = pendingItems();
  const barRuntime = state.bar && state.bar.runtime ? state.bar.runtime : {};
  const barWork = state.bar && state.bar.work ? state.bar.work : {};
  const cockpitState = normalizeRuntimeState(barRuntime.state || (state.health ? "verified" : "blocked"), state.health ? "verified" : "blocked");

  els.activeTwinName.textContent = activeTwin ? activeTwin.display_name : "No twin selected";
  els.activeTwinMeta.textContent = activeTwin
    ? `${activeTwin.instance_id} · ${labelForStatus(activeTwin.status)}`
    : "Memory and persona binding pending.";
  els.activePersonaTag.textContent = `persona: ${activePersona ? activePersona.display_name : "-"}`;
  els.activeVaultTag.textContent = `vault: ${activeVault ? activeVault.display_name : "-"}`;
  els.activePermissionTag.textContent = permission.ok ? "tools: approval gated" : "tools: blocked";
  els.cockpitHeadline.textContent = state.health
    ? `H.A.R.V.I.S. ${labelForStatus(cockpitState)}`
    : "H.A.R.V.I.S. offline";
  els.cockpitSummary.textContent = barRuntime.summary || (state.health ? "Local runtime is reachable." : "Start the HTTP service to restore Studio.");
  els.cockpitOnline.textContent = state.health ? "online" : "offline";
  els.cockpitPermission.textContent = permission.ok ? "ready" : "blocked";
  els.cockpitReview.textContent = `${pending.length} pending`;
  els.cockpitGraph.textContent = graphLoaded ? `${graphStats.note_count || 0} notes` : "not loaded";
  renderDashboardGraphDock();
  renderFirstRun();

  els.personaCount.textContent = String(personas.length);
  els.vaultCount.textContent = String(vaults.length);
  els.runCount.textContent = String((state.runs && state.runs.run_count) || asArray(state.runs && state.runs.runs).length);
  els.approvalCount.textContent = String((state.approvals && state.approvals.approval_count) || asArray(state.approvals && state.approvals.approvals).length);
  els.handoffMetric.textContent = String((state.handoffs && state.handoffs.handoff_count) || asArray(state.handoffs && state.handoffs.handoffs).length);
  const routerEvents = asArray(state.routerEvents && state.routerEvents.events).slice(-6).reverse();
  els.routerMetric.textContent = String((state.routerEvents && state.routerEvents.event_count) || routerEvents.length);
  els.healthStamp.textContent = new Date().toLocaleTimeString();
  els.dashboardPortsMetric.textContent = `${portCounts.listeners || 0} listeners`;
  setStack(
    els.dashboardPortsList,
    portItems
      .filter((port) => port.important || port.known)
      .slice(0, 5)
      .map((port) => portItem(port, true)),
    "No port data.",
  );
  renderHarnessPool();

  const healthRows = [
    ["HTTP API", state.health ? "ok" : "down", state.health ? state.health.mode : "not reachable"],
    ["Permission Probe", permission.ok ? "ok" : "blocked", permission.detail],
    ["Runtime Tick", barWork.lastTickAt ? "seen" : "waiting", barWork.lastTickAt ? formatDate(barWork.lastTickAt) : "no tick state"],
    ["MCP Tools", "ready", "MCP server exposes runtime and persona tools."],
    ["Safety", "approval gated", "Writes and personality adoption remain review-first."],
  ];
  setStack(
    els.healthList,
    healthRows.map(([name, status, detail]) => item(name, detail, status)),
    "No health data.",
  );

  els.queueCount.textContent = String(pending.length);
  setStack(
    els.pendingQueue,
    pending.map((entry) => item(entry.title, entry.meta, entry.badge)),
    "No pending reviews.",
  );

  const runItems = asArray(state.runs && state.runs.runs).slice(0, 4).map((run) => (
    item(run.run_id || run.packet_id, `${labelForStatus(run.state || run.status)} · ${formatDate(run.updated_at || run.created_at)}`, run.approval && run.approval.pending ? "approval" : "run")
  ));
  const eventItems = asArray(state.events && state.events.events).slice(-4).reverse().map((event) => (
    item(event.event || event.type || event.message || "Runtime event", `${event.source || event.phase || "runtime"} · ${formatDate(event.timestamp || event.created_at || event.at)}`, "event")
  ));
  setStack(
    els.recentRuns,
    [...eventItems, ...runItems].slice(0, 8),
    "No recent activity.",
  );

  setStack(
    els.routerEvents,
    routerEvents.map((event) => item(
      `${event.intent || "message"} · ${labelForStatus(event.route_state)}`,
      routerEventMeta(event),
      event.safeForWebView === false ? "full" : "router",
    )),
    "No router events.",
  );

  const roomEvents = asArray(state.room && state.room.events).slice(-5).reverse();
  const roomTopics = asArray(state.room && state.room.topics).slice(-5).reverse();
  const roomItems = roomEvents.length
    ? roomEvents.map((event) => item(event.content || event.event_type || event.event_id, `${event.agent_id || "harvis"} · ${formatDate(event.created_at)}`, event.role || "event"))
    : roomTopics.map((topic) => item(topic.title || topic.topic_id, topic.goal || formatDate(topic.created_at), "topic"));
  setStack(els.agentSummary, roomItems, "No Agent Room events.");
  renderWorkbenchState();

  const handoffs = asArray(state.handoffs && state.handoffs.handoffs).slice(0, 6);
  setStack(
    els.handoffList,
    handoffs.map((handoff) => item(handoff.run_id || handoff.handoff_id, `${handoff.harness || "manual"} · ${labelForStatus(handoff.state)}`, "handoff")),
    "No handoffs.",
  );
}

function liveHarnessById() {
  const byId = new Map();
  for (const entry of asArray(state.agentHarnesses && state.agentHarnesses.items)) {
    if (entry && entry.id) {
      byId.set(entry.id, entry);
    }
  }
  return byId;
}

function liveHarnessMeta(live, fallbackStatus = "") {
  if (!live) {
    return `registry: ${fallbackStatus || "unknown"} · live status not loaded`;
  }
  const cli = live.cliPresent ? live.cliCommand || "present" : "missing";
  return `${live.runtime || "runtime"} · ${live.model || "model"} · cli ${cli} · ${live.summary || ""}`;
}

function renderHarnessPool() {
  const registry = state.agentPools || {};
  const live = state.agentHarnesses || {};
  const harnesses = asArray(registry.harnesses);
  const presets = asArray(registry.presets);
  const models = asArray(registry.models);
  const liveItems = asArray(live.items);
  const liveById = liveHarnessById();
  const harnessLiveItems = liveItems.filter((entry) => entry.poolKind === "harness");
  const readyHarnesses = harnessLiveItems.filter((entry) => entry.status === "ready").length;
  const totalHarnesses = harnesses.length || harnessLiveItems.length;
  const statusText = live.summary || "status not loaded";

  els.harnessPoolMetric.textContent = `${readyHarnesses}/${totalHarnesses || 0} ready · ${statusText}`;

  const harnessRows = harnesses.length
    ? harnesses.map((entry) => {
      const current = liveById.get(entry.harness_id);
      return item(
        entry.label || entry.harness_id,
        `${entry.kind || "harness"} · default ${entry.default_model_id || "-"} · ${liveHarnessMeta(current, entry.status)}`,
        current ? current.status : entry.status,
      );
    })
    : harnessLiveItems.map((entry) => item(entry.label || entry.id, liveHarnessMeta(entry), entry.status));
  setStack(els.harnessPoolList, harnessRows, "No harness health.");

  setStack(
    els.harnessPresetList,
    presets.map((preset) => {
      const current = liveById.get(preset.preset_id);
      const smoke = current && current.testTarget ? ` · smoke ${current.test && current.test.status || "not-run"}` : "";
      return item(
        preset.label || preset.preset_id,
        `${preset.harness_id || "-"} + ${preset.model_id || "-"}${smoke} · ${current ? current.summary : preset.notes || ""}`,
        current ? current.status : preset.status,
      );
    }),
    "No runtime presets.",
  );

  setStack(
    els.harnessModelList,
    models.slice(0, 8).map((model) => item(
      model.label || model.model_id,
      `${model.provider || "provider"} · ${asArray(model.capabilities).slice(0, 4).join(", ")} · preferred ${asArray(model.preferred_harness_ids).join(", ") || "-"}`,
      model.status || "model",
    )),
    "No model bindings.",
  );

  const safety = registry.safety || {};
  const policy = registry.routing_policy || {};
  setStack(
    els.harnessPolicyList,
    [
      item("Routing", `${policy.harness_selection || "-"} · fallback ${policy.fallback_mode || "-"}`, "policy"),
      item("Review Gate", safety.reviewGateRequired ? "required" : "unknown", safety.includesSecrets ? "bad" : "safe"),
      item("Smoke Policy", live.testPolicy || "status-only", live.includesModelCalls ? "model calls were made" : "no model calls in refresh"),
    ],
    "No policy.",
  );
}

function renderPorts() {
  const ports = state.ports || {};
  const counts = ports.counts || {};
  const items = asArray(ports.items);
  const importantReady = `${counts.importantAutostartReady || 0}/${counts.important || 0} autostart`;
  els.portImportantState.textContent = importantReady;
  els.portSummary.textContent = ports.summary || "No port scan yet.";
  setStack(
    els.portList,
    items.map((port) => portItem(port)),
    "No listening ports.",
  );
}

function renderWorkbenchState() {
  const workspaceState = state.workspaceState || {};
  const activeSlots = asArray(workspaceState.active_slots);
  const openTasks = asArray(workspaceState.open_tasks);
  const unreadMailbox = asArray(workspaceState.unread_mailbox);
  const pendingApprovals = asArray(workspaceState.pending_approvals);
  const waitingApprovalQueue = asArray(workspaceState.waiting_approval_queue);
  const routerEvents = asArray(workspaceState.recent_router_events);
  const conversations = asArray(state.conversations && state.conversations.conversations).length
    ? asArray(state.conversations && state.conversations.conversations)
    : asArray(workspaceState.recent_conversations);
  const conversationBindings = asArray(state.conversationBindings && state.conversationBindings.bindings);
  const openTaskPreview = previewItems(openTasks, 6, workbenchTaskItem, "more task(s) on the board");
  const linkedContexts = linkedContextItems(conversations, openTasks);
  if (!linkedContexts.find((entry) => linkedContextKey(entry) === state.selectedLinkedContextKey)) {
    state.selectedLinkedContextKey = linkedContexts[0] ? linkedContextKey(linkedContexts[0]) : "";
  }
  const conversationPreview = previewItems(
    [
      ...conversations,
      ...conversationBindings.map((binding) => ({
        transport: binding.transport,
        chat_id: binding.chat_id,
        sender: binding.sender_id,
        conversation_id: binding.conversation_key,
        intent: binding.harness_ref || binding.agent_ref || "binding",
        route_state: binding.status || binding.model_ref || "bound",
        packet_id: binding.packet_id,
        handoff_id: binding.handoff_id,
        run_id: binding.run_id,
        updated_at: binding.updated_at || binding.created_at,
      })),
    ],
    6,
    workbenchConversationItem,
    "more conversation context item(s)",
  );
  const linkedContextPreview = previewItems(
    linkedContexts,
    6,
    workbenchLinkedContextItem,
    "more linked context item(s)",
  );
  const chainDetail = linkedContexts.find((entry) => linkedContextKey(entry) === state.selectedLinkedContextKey)
    || linkedContexts[0]
    || null;
  const approvalPreview = previewItems(
    [
      ...pendingApprovals.map((approval) => ({ type: "approval", value: approval })),
      ...waitingApprovalQueue.map((entry) => ({ type: "queue", value: entry })),
    ],
    6,
    (entry) => entry.type === "approval"
      ? workbenchPendingApprovalItem(entry.value)
      : workbenchApprovalQueueItem(entry.value),
    "more approval queue item(s)",
  );
  const memorySummary = workspaceState.memory_candidates_summary || {};
  const chair = workspaceState.chair_slot && typeof workspaceState.chair_slot === "object"
    ? workspaceState.chair_slot
    : null;
  const topic = workspaceState.active_topic && typeof workspaceState.active_topic === "object"
    ? workspaceState.active_topic
    : null;

  els.workbenchMetric.textContent = `${activeSlots.length} slot${activeSlots.length === 1 ? "" : "s"}`;
  els.workbenchChair.textContent = `chair: ${chair ? chair.display_name || chair.slot_id : "-"}`;
  const rows = [
    item(
      topic ? topic.title || topic.topic_id : "No active topic",
      topic ? topic.goal || labelForStatus(topic.status) : "Router and transports share this workspace when a topic exists.",
      "topic",
    ),
    item("Open tasks", `${openTasks.length} item(s) on the shared task board`, "tasks"),
    item("Unread mailbox", `${unreadMailbox.length} coordination message(s)`, "mail"),
    item(
      "Approval queue",
      `${pendingApprovals.length} gate(s), ${waitingApprovalQueue.length} task(s) waiting`,
      "approval",
    ),
    item(
      "Memory candidates",
      `${memorySummary.candidate_count || memorySummary.signals || 0} candidate signal(s), review required`,
      "memory",
    ),
  ];
  setStack(els.workbenchSummary, rows, "No workspace state.");
  setStack(
    els.workbenchSlots,
    activeSlots.map((slot) => item(slot.display_name || slot.slot_id, `${slot.role || "agent"} · ${labelForStatus(slot.status)} · ${slot.execution_mode || "record only"}`, slot.slot_id)),
    "No slots.",
  );
  setStack(
    els.workbenchTasks,
    openTaskPreview,
    "No tasks.",
  );
  setStack(
    els.workbenchMailbox,
    unreadMailbox.map(workbenchMailboxItem),
    "No unread mailbox.",
  );
  setStack(
    els.workbenchConversations,
    conversationPreview,
    "No conversation context.",
  );
  setStack(
    els.workbenchLinkedContext,
    linkedContextPreview,
    "No linked context.",
  );
  setStack(
    els.workbenchChainDetail,
    workbenchChainDetailItems(chainDetail),
    "No chain detail.",
  );
  setStack(
    els.workbenchCodexPins,
    previewItems(asArray(state.codexPins && state.codexPins.pins), 4, workbenchCodexPinItem, "more pinned Codex thread(s)"),
    "No pinned threads.",
  );
  setStack(
    els.workbenchCodexBindings,
    previewItems(asArray(state.codexBindings && state.codexBindings.bindings), 4, workbenchCodexBindingItem, "more Codex thread binding(s)"),
    "No Codex thread bindings.",
  );
  setStack(
    els.workbenchRunTimeline,
    previewItems(asArray(state.runTimeline && state.runTimeline.events), 6, workbenchRunTimelineItem, "more run event(s)"),
    "No run timeline.",
  );
  setStack(
    els.workbenchTeamHarness,
    workbenchTeamHarnessItems(state.teamHarness),
    "No Team Harness decisions.",
  );
  setStack(
    els.workbenchApprovals,
    approvalPreview,
    "No approvals.",
  );
  setStack(
    els.workbenchRouterEvents,
    routerEvents.map((event) => item(`${event.intent || "message"} · ${labelForStatus(event.route_state)}`, `${event.transport || "transport"} · ${formatDate(event.recorded_at)}`, "router")),
    "No router events.",
  );
}

function consoleMessageId() {
  const current = els.consoleMessageIdInput.value.trim();
  if (current) {
    return current;
  }
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
  return `studio-console-${stamp}`;
}

function renderConsole() {
  const result = state.consoleResult;
  const projects = asArray(state.projects && state.projects.projects);
  const agentPools = state.agentPools || {};
  const poolCounts = agentPools.counts || {};
  const presets = asArray(agentPools.presets);
  const adapters = asArray(agentPools.adapters);
  const projectsError = state.errors.find((entry) => entry.label === "projects");
  const agentPoolsError = state.errors.find((entry) => entry.label === "agentPools");
  els.consoleProjectCount.textContent = String(projects.length);
  if (projectsError) {
    setStack(
      els.consoleProjects,
      [item("Project registry blocked", projectsError.error || "Unable to read projects from the resident service.", "timeout")],
      "No known projects.",
    );
  } else {
    setStack(
      els.consoleProjects,
      projects.map((project) => item(
        project.name || project.project_id,
        `${project.kind || "project"} · ${project.exists ? "found" : "missing"} · ${project.path || ""}`,
        project.status || "project",
      )),
      "No known projects.",
    );
  }
  els.consoleAgentPoolCount.textContent = `${poolCounts.harnesses || 0}/${poolCounts.models || 0}/${poolCounts.presets || 0}`;
  if (agentPoolsError) {
    setStack(
      els.consoleAgentPools,
      [item("Agent pools blocked", agentPoolsError.error || "Unable to read agent pools from the resident service.", "timeout")],
      "No agent pools.",
    );
  } else {
    setStack(
      els.consoleAgentPools,
      [
        ...presets.map((preset) => item(
          preset.preset_id || preset.label,
          `${preset.harness_id || "-"} + ${preset.model_id || "-"} · ${agentPools.path || ""}`,
          preset.status || "preset",
        )),
        ...adapters.map((entry) => item(
          `${entry.harness_id || entry.label} adapter`,
          `${entry.adapter && entry.adapter.mode || "-"} · prompt ${entry.adapter && entry.adapter.prompt_input || "-"} · result ${entry.adapter && entry.adapter.result_output || "-"}`,
          entry.review_gate || "adapter",
        )),
      ],
      "No agent pools.",
    );
  }
  if (!result) {
    els.consoleStatus.textContent = "idle";
    els.consoleResultBadge.textContent = "no run";
    setStack(els.consoleSummary, [], "No console request yet.");
    els.consoleRawOutput.textContent = "{}";
    return;
  }
  const chairMove = result.chair_dry_run && result.chair_dry_run.proposed_move
    ? result.chair_dry_run.proposed_move
    : {};
  els.consoleStatus.textContent = result.status || "ok";
  els.consoleResultBadge.textContent = `${result.intent || "message"} · ${labelForStatus(result.route_state)}`;
  const rows = [
    item("Intent", `${result.intent || "-"} · ${result.channel || "console"}`, "route"),
    item("Next action", result.next_expected_action || "-", "next"),
    item("Chair dry-run", `${chairMove.action || "-"} · ${chairMove.reason || ""}`, "chair"),
    item("Reply", result.response_text || "No response text.", "reply"),
  ];
  if (result.route && result.route.workbench_task) {
    rows.push(item(
      "Task",
      `${result.route.workbench_task.task_id || "-"} · ${labelForStatus(result.route.workbench_task.status)} · ${result.route.workbench_task.packet_id || ""}`,
      "task",
    ));
  }
  setStack(els.consoleSummary, rows, "No console request yet.");
  els.consoleRawOutput.textContent = JSON.stringify(result, null, 2);
}

async function runAgentConsole(messageOverride = "") {
  saveInputs();
  const message = (messageOverride || els.consoleMessageInput.value).trim();
  if (!message) {
    throw new Error("Console message is required.");
  }
  const messageId = consoleMessageId();
  els.consoleMessageIdInput.value = messageId;
  els.consoleStatus.textContent = "sending";
  setRuntime("acting", "warn");
  const result = await api("POST", "/agent/step", {
    root: workspaceRoot(),
    channel: els.consoleChannelInput.value,
    sender: els.consoleSenderInput.value.trim() || "studio-console",
    chat_id: "studio-console",
    message_id: messageId,
    message,
    chair_dry_run: true,
  });
  state.consoleResult = result;
  renderConsole();
  await refresh();
  return result;
}

async function runHarnessSmoke() {
  saveInputs();
  els.harnessSmokeButton.disabled = true;
  els.harnessSmokeButton.textContent = "Checking";
  setRuntime("checking harness", "warn");
  try {
    state.agentHarnesses = await api("GET", "/agent-harnesses/status");
    renderDashboard();
    renderConsole();
    setRuntime("verified", state.agentHarnesses.status === "failed" ? "warn" : "ok");
  } finally {
    els.harnessSmokeButton.disabled = false;
    els.harnessSmokeButton.textContent = "Check";
  }
}

function renderConsoleError(label, error) {
  state.consoleResult = {
    status: "failed",
    intent: "console_error",
    route_state: "blocked",
    next_expected_action: "fix_service_or_permissions",
    response_text: error.message || String(error),
    error: {
      label,
      message: error.message || String(error),
    },
  };
  renderConsole();
}

function workbenchCodexPinItem(pin) {
  const threadState = pin.codex_thread_id || pin.codex_session_id ? "thread linked" : "thread missing";
  const run = pin.run_id || pin.task_id || pin.packet_id || "no run linked";
  const status = labelForStatus(pin.status || pin.last_event_type || "unknown");
  const event = pin.last_event_type ? ` · ${pin.last_event_type}` : "";
  const updated = pin.last_event_at || pin.created_at ? ` · ${formatDate(pin.last_event_at || pin.created_at)}` : "";
  return item(pin.label || "Redacted Codex pin", `${threadState} · ${run} · ${status}${event}${updated}`, "pin");
}

function workbenchCodexBindingItem(binding) {
  const thread = "Redacted conversation binding";
  const threadState = binding.codex_thread_id || binding.codex_session_id ? "thread linked" : "thread missing";
  const run = binding.run_id || binding.task_id || binding.packet_id || "run missing";
  const status = labelForStatus(binding.status || binding.last_event_type || "unknown");
  const event = binding.last_event_type ? ` · ${binding.last_event_type}` : "";
  const transport = binding.transport && typeof binding.transport === "object" ? " · transport linked" : "";
  return item(thread, `${threadState} · ${run} · ${status}${event}${transport}`, "thread");
}

function workbenchRunTimelineItem(event) {
  const eventType = event.codex_event_type || event.type || "event";
  const run = event.run_id || event.packet_id || event.handoff_id || "run";
  const summary = event.summary || event.message || event.status || event.source_path || "";
  return item(eventType, `${run} · ${formatDate(event.observed_at || event.created_at || event.at)} · ${summary}`, "event");
}

function workbenchTeamHarnessItems(teamHarness) {
  const stateValue = teamHarness || {};
  const decisions = asArray(stateValue.decisions);
  const toolCalls = asArray(stateValue.tool_calls);
  const gates = asArray(stateValue.approval_gate_checks);
  const rows = [];
  if (stateValue.leader_principle) {
    rows.push(item("Leader principle", stateValue.leader_principle, "v0"));
  }
  rows.push(...decisions.slice(0, 3).map((decision) => {
    const proposal = decision.proposal || decision.route_proposal || {};
    const route = proposal.harness || proposal.recommended_harness || decision.harness_ref || "proposal";
    const model = proposal.model || proposal.model_ref || decision.model_ref || "model";
    const move = decision.move || proposal.move || decision.action || "route proposal";
    return item(move, `${route} · ${model} · ${decision.reason || proposal.reason || decision.created_at || ""}`, "chair");
  }));
  rows.push(...toolCalls.slice(0, 2).map((call) => item(
    call.tool || call.tool_name || "team tool",
    `${labelForStatus(call.status || call.result_state || "recorded")} · ${call.task_id || call.run_id || call.created_at || ""}`,
    "tool",
  )));
  rows.push(...gates.slice(0, 3).map((gate) => item(
    gate.action || gate.action_type || "approval gate",
    `${labelForStatus(gate.status || gate.result || "checked")} · ${gate.approval_id || gate.reason || gate.created_at || ""}`,
    gate.allowed === true ? "approved" : "gate",
  )));
  return rows;
}

function workbenchTaskItem(task) {
  const row = item(task.title || task.task_id, `${task.owner_slot_id || "slot"} · ${labelForStatus(task.status)} · ${task.packet_id || task.task_id || ""}`, "task");
  const actions = document.createElement("div");
  actions.className = "inline-actions";
  for (const [status, label] of [["blocked", "Block"], ["reviewing", "Review"], ["done", "Done"]]) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "mini-action";
    button.textContent = label;
    button.disabled = task.status === status;
    button.addEventListener("click", () => updateWorkbenchTaskStatus(task.task_id, status).catch((error) => {
      state.errors.push({ label: "workbench-task-status", error: error.message || String(error) });
      renderAll();
    }));
    actions.append(button);
  }
  row.append(actions);
  return row;
}

function previewItems(values, limit, render, moreText) {
  const rendered = values.slice(0, limit).map(render);
  const remaining = values.length - rendered.length;
  if (remaining > 0) {
    rendered.push(item(`+${remaining} more`, moreText, "more"));
  }
  return rendered;
}

function workbenchMailboxItem(mail) {
  const row = item(mail.subject || mail.mail_id, `${mail.from_slot_id || "slot"} -> ${mail.to_slot_id || "slot"} · ${formatDate(mail.created_at)}`, "mail");
  const actions = document.createElement("div");
  actions.className = "inline-actions";
  const button = document.createElement("button");
  button.type = "button";
  button.className = "mini-action";
  button.textContent = "Read";
  button.addEventListener("click", () => markWorkbenchMailRead(mail.mail_id).catch((error) => {
    state.errors.push({ label: "workbench-mail-read", error: error.message || String(error) });
    renderAll();
  }));
  actions.append(button);
  row.append(actions);
  return row;
}

function workbenchConversationItem(conversation) {
  const transport = conversation.transport || "transport";
  const intent = conversation.intent || "message";
  const routeState = conversation.route_state || "context";
  const packet = conversation.packet_id ? ` · packet ${conversation.packet_id}` : "";
  const handoff = conversation.handoff_id ? ` · handoff ${conversation.handoff_id}` : "";
  const run = conversation.run_id ? ` · run ${conversation.run_id}` : "";
  const updated = conversation.updated_at ? ` · ${formatDate(conversation.updated_at)}` : "";
  return item(
    `${transport} · redacted conversation`,
    `${labelForStatus(intent)} · ${labelForStatus(routeState)}${packet}${handoff}${run}${updated}`,
    "conversation",
  );
}

function allWorkbenchTasks(fallbackOpenTasks = []) {
  const loaded = asArray(state.tasks && state.tasks.tasks);
  return loaded.length ? loaded : fallbackOpenTasks;
}

function workbenchApprovals() {
  const workspaceState = state.workspaceState || {};
  return [
    ...asArray(state.approvals && state.approvals.approvals),
    ...asArray(workspaceState.pending_approvals),
  ];
}

function workbenchHandoffs() {
  const workspaceState = state.workspaceState || {};
  return [
    ...asArray(state.handoffs && state.handoffs.handoffs),
    ...asArray(workspaceState.recent_handoffs),
  ];
}

function workbenchRuns() {
  return asArray(state.runs && state.runs.runs);
}

function candidateEvidenceText(candidate) {
  return asArray(candidate.evidence).join(" ");
}

function candidateEvidenceIds(candidate) {
  const values = new Set();
  if (candidate.source_id) {
    values.add(candidate.source_id);
  }
  for (const entry of asArray(candidate.evidence)) {
    const text = String(entry || "").trim();
    if (!text) {
      continue;
    }
    values.add(text);
    const pair = text.match(/^[A-Za-z0-9_-]+=(.+)$/);
    if (pair && pair[1]) {
      values.add(pair[1]);
    }
  }
  return values;
}

function linkedMemoryCandidates(ids) {
  const needles = ids.filter(Boolean);
  if (!needles.length) {
    return [];
  }
  return currentMemoryCandidates().filter((candidate) => {
    const source = candidate.source_id || "";
    const evidenceIds = candidateEvidenceIds(candidate);
    return needles.some((needle) => source === needle || evidenceIds.has(needle));
  });
}

function firstById(values, key, id) {
  if (!id) {
    return null;
  }
  return values.find((value) => value && value[key] === id) || null;
}

function firstTaskForConversation(conversation, fallbackOpenTasks = []) {
  const tasks = allWorkbenchTasks(fallbackOpenTasks);
  const ids = [
    ["task_id", conversation.task_id],
    ["packet_id", conversation.packet_id],
    ["handoff_id", conversation.handoff_id],
    ["run_id", conversation.run_id],
  ];
  for (const [key, id] of ids) {
    const task = firstById(tasks, key, id);
    if (task) {
      return task;
    }
  }
  return null;
}

function linkedContextItems(conversations, fallbackOpenTasks = []) {
  return conversations
    .map((conversation) => {
      const task = firstTaskForConversation(conversation, fallbackOpenTasks);
      const taskIds = task
        ? [task.task_id, task.packet_id, task.approval_id, task.handoff_id, task.run_id]
        : [];
      const packetId = conversation.packet_id || (task && task.packet_id);
      const taskId = conversation.task_id || (task && task.task_id);
      const approvalId = task && task.approval_id;
      const handoffId = conversation.handoff_id || (task && task.handoff_id);
      const runId = conversation.run_id || (task && task.run_id);
      const approval = firstById(workbenchApprovals(), "approval_id", approvalId)
        || workbenchApprovals().find((entry) => runId && entry.run_id === runId)
        || null;
      const handoff = firstById(workbenchHandoffs(), "handoff_id", handoffId)
        || workbenchHandoffs().find((entry) => runId && entry.run_id === runId)
        || null;
      const run = firstById(workbenchRuns(), "run_id", runId)
        || workbenchRuns().find((entry) => packetId && entry.packet_id === packetId)
        || null;
      const memory = linkedMemoryCandidates([
        taskId,
        packetId,
        approvalId,
        handoffId,
        runId,
        ...taskIds,
      ]);
      return {
        conversation,
        task,
        approval,
        handoff,
        run,
        memory,
        ids: {
          taskId,
          packetId,
          approvalId,
          handoffId,
          runId,
        },
      };
    })
    .filter((entry) => {
      const ids = entry.ids || {};
      return entry.task
        || entry.approval
        || entry.handoff
        || entry.run
        || entry.memory.length
        || ids.taskId
        || ids.packetId
        || ids.approvalId
        || ids.handoffId
        || ids.runId;
    });
}

function linkedStatus(label, record, statusKey, id) {
  if (record && record[statusKey]) {
    return `${label} ${labelForStatus(record[statusKey])}`;
  }
  if (record && (record[`${label}_id`] || record.id)) {
    return `${label} resolved`;
  }
  if (id) {
    return `${label} id-only:${id}`;
  }
  return `${label} none`;
}

function linkedContextKey(entry) {
  const ids = entry && entry.ids ? entry.ids : {};
  const conversation = entry && entry.conversation ? entry.conversation : {};
  return [
    conversation.transport,
    conversation.chat_id,
    ids.taskId,
    ids.packetId,
    ids.handoffId,
    ids.runId,
    conversation.conversation_id,
  ].filter(Boolean).join(":") || "linked-context";
}

function workbenchLinkedContextItem(entry) {
  const conversation = entry.conversation || {};
  const task = entry.task || {};
  const approval = entry.approval || {};
  const handoff = entry.handoff || {};
  const run = entry.run || {};
  const ids = entry.ids || {};
  const memoryCount = entry.memory ? entry.memory.length : 0;
  const title = task.title || task.task_id || conversation.packet_id || "Linked context";
  const pieces = [
    `${conversation.transport || "transport"}:redacted conversation`,
    linkedStatus("task", task, "status", ids.taskId),
    linkedStatus("approval", approval, "status", ids.approvalId),
    linkedStatus("handoff", handoff, "state", ids.handoffId),
    linkedStatus("run", run, "state", ids.runId),
    `memory ${memoryCount} candidate(s)`,
  ];
  const row = item(title, pieces.join(" · "), "linked");
  const actions = document.createElement("div");
  actions.className = "inline-actions";
  const button = document.createElement("button");
  button.type = "button";
  button.className = "mini-action";
  button.textContent = linkedContextKey(entry) === state.selectedLinkedContextKey ? "Viewing" : "View";
  button.disabled = linkedContextKey(entry) === state.selectedLinkedContextKey;
  button.addEventListener("click", () => {
    state.selectedLinkedContextKey = linkedContextKey(entry);
    renderWorkbenchState();
  });
  actions.append(button);
  row.append(actions);
  return row;
}

function latestHandoffHistory(handoff) {
  return asArray(handoff && handoff.history).slice(-1)[0] || null;
}

function handoffReviewSummary(handoff) {
  if (!handoff || !handoff.handoff_id) {
    return null;
  }
  const latest = latestHandoffHistory(handoff);
  const reviewer = handoff.updated_by || (latest && latest.updated_by) || "reviewer";
  const state = handoff.state || (latest && latest.state) || "unknown";
  const summary = handoff.summary || (latest && latest.summary) || "no reviewer summary";
  const updated = handoff.updated_at || (latest && latest.updated_at);
  return `${reviewer} · ${labelForStatus(state)} · ${summary}${updated ? ` · ${formatDate(updated)}` : ""}`;
}

function candidateReviewCenterState(candidate) {
  const adoption = candidate.adoption || {};
  const adoptionStatus = adoption.status || "not_adopted";
  const requiresReview = memoryCandidateRequiresReview(candidate);
  return requiresReview
    ? `Review Center visible · ${labelForStatus(adoptionStatus)} · manual review required`
    : `Review Center visible · ${labelForStatus(adoptionStatus)}`;
}

function workbenchChainDetailItems(entry) {
  if (!entry) {
    return [];
  }
  const conversation = entry.conversation || {};
  const task = entry.task || {};
  const approval = entry.approval || {};
  const handoff = entry.handoff || {};
  const run = entry.run || {};
  const ids = entry.ids || {};
  const reviewSummary = handoffReviewSummary(handoff);
  const memoryCandidates = asArray(entry.memory);
  const rows = [
    item(
      "Conversation",
      `${conversation.transport || "transport"} · redacted conversation · ${labelForStatus(conversation.intent)} · ${labelForStatus(conversation.route_state)}`,
      "context",
    ),
    item(
      "Task",
      `${task.task_id || ids.taskId || "id missing"} · ${linkedStatus("task", task, "status", ids.taskId)} · ${task.latest_note || task.description || "no latest note"}`,
      "task",
    ),
    item(
      "Approval Gate",
      approval.approval_id
        ? `${approval.approval_id} · ${labelForStatus(approval.status)} · ${approval.risk || "risk unknown"}`
        : ids.approvalId
          ? `${ids.approvalId} · id-only`
          : "No approval record linked.",
      "approval",
    ),
    item(
      "Handoff Review",
      handoff.handoff_id
        ? `${handoff.handoff_id} · ${labelForStatus(handoff.state)} · ${handoff.summary || handoff.review_summary || "no handoff summary"}`
        : ids.handoffId
          ? `${ids.handoffId} · id-only`
          : "No handoff record linked.",
      "handoff",
    ),
    item(
      "Reviewer Conclusion",
      reviewSummary || "No reviewer conclusion linked yet.",
      reviewSummary ? "review" : "pending",
    ),
    item(
      "Run",
      run.run_id
        ? `${run.run_id} · ${labelForStatus(run.state || run.status)} · ${run.exec_dir || run.path || "no execution path"}`
        : ids.runId
          ? `${ids.runId} · id-only`
          : "No run record linked.",
      "run",
    ),
    item(
      "Memory Review Gate",
      memoryCandidates.length
        ? `${memoryCandidates.length} candidate(s) in Review Center · explicit review before adoption`
        : "No memory candidate linked to this chain yet.",
      memoryCandidates.length ? "memory" : "pending",
    ),
  ];
  const memoryRows = memoryCandidates.slice(0, 3).map((candidate) => item(
    "Memory Candidate",
    `${candidate.candidate_id || candidate.source_id || "candidate"} · ${labelForStatus(candidate.status)} · ${candidateReviewCenterState(candidate)} · ${candidate.summary || "review required"}`,
    "memory",
  ));
  return [...rows, ...memoryRows];
}

function workbenchApprovalQueueItem(entry) {
  const taskId = entry.task_id || "task";
  const nextAction = entry.next_action || "request_approval";
  const packet = entry.packet_id ? ` · packet ${entry.packet_id}` : "";
  const approvalStatus = entry.approval_status || (entry.has_pending_approval ? "pending" : "missing");
  const approval = approvalStatus === "missing" ? "approval needed" : `approval ${labelForStatus(approvalStatus)}`;
  const row = item(
    entry.title || taskId,
    `${entry.owner_slot_id || "slot"} · ${labelForStatus(entry.status)} · ${approval} · next: ${labelForStatus(nextAction)}${packet}`,
    "queue",
  );
  const actions = document.createElement("div");
  actions.className = "inline-actions";
  if (nextAction === "request_handoff") {
    const handoffButton = document.createElement("button");
    handoffButton.type = "button";
    handoffButton.className = "mini-action";
    handoffButton.textContent = "Handoff";
    handoffButton.addEventListener("click", () => requestTaskHandoff(entry).catch((error) => {
      state.errors.push({ label: "workbench-request-handoff", error: error.message || String(error) });
      renderAll();
    }));
    actions.append(handoffButton);
  } else {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "mini-action";
    button.textContent = nextAction === "approve_or_reject" ? "Requested" : "Request";
    button.disabled = nextAction !== "request_approval";
    button.addEventListener("click", () => requestTaskApproval(entry).catch((error) => {
      state.errors.push({ label: "workbench-request-approval", error: error.message || String(error) });
      renderAll();
    }));
    actions.append(button);
  }
  row.append(actions);
  return row;
}

function workbenchPendingApprovalItem(approval) {
  const row = item(
    approval.action_type || approval.approval_id,
    `${approval.run_id || "run"} · ${labelForStatus(approval.status)} · ${approval.risk || "medium"}`,
    "approval",
  );
  const actions = document.createElement("div");
  actions.className = "inline-actions";
  for (const [action, label] of [["approve", "Approve"], ["reject", "Deny"]]) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "mini-action";
    button.textContent = label;
    button.addEventListener("click", async () => {
      const impact = `${approval.risk || "risk not recorded"} risk · ${targetLabel(approval.target) || "current approval scope"}`;
      const confirmed = await window.HarvisOperator.confirm(els.operatorConfirmDialog, {
        title: `${action === "approved" ? "Approve" : "Deny"} this request?`,
        detail: "This decision is recorded in the immutable approval lineage. It does not bypass handoff or review.",
        impact,
        accept: action === "approved" ? "Approve request" : "Deny request",
        danger: action !== "approved",
      });
      if (!confirmed) return;
      window.HarvisOperator.action(button, () => decideWorkbenchApproval(approval, action), {
        loading: "Recording…",
        success: "Recorded",
        error: "Failed — retry",
      }).catch((error) => {
        state.errors.push({ label: "workbench-decide-approval", error: error.message || String(error) });
        renderAll();
      });
    });
    actions.append(button);
  }
  row.append(actions);
  return row;
}

async function decideWorkbenchApproval(approval, action) {
  if (!approval || !approval.approval_id) {
    throw new Error("Missing approval id.");
  }
  await api("POST", "/decide-approval", {
    root: workspaceRoot(),
    approval_id: approval.approval_id,
    decision: action === "approve" ? "approved" : "denied",
    decided_by: "studio-gwt-workbench",
    notes: "Reviewed from Studio GWT Workbench.",
  });
  await refresh();
}

async function requestTaskHandoff(entry) {
  if (!entry || !entry.task_id || !entry.run_id) {
    throw new Error("Missing task or run id.");
  }
  const handoff = await api("POST", "/request-handoff", {
    root: workspaceRoot(),
    run_id: entry.run_id,
    harness: "codex",
    instruction: `Prepare approved task for controlled execution: ${entry.title || entry.task_id}`,
    topic_id: entry.topic_id || "gwt-workbench",
    requested_by: "studio-gwt-workbench",
  });
  const handoffId = handoff && handoff.handoff ? handoff.handoff.handoff_id : "";
  await api("POST", "/agent-room/task/link", {
    root: workspaceRoot(),
    task_id: entry.task_id,
    handoff_id: handoffId,
    run_id: entry.run_id,
    packet_id: entry.packet_id || undefined,
    status: "in_progress",
    note: "Handoff requested from Studio GWT Workbench after approval.",
  });
  await refresh();
}

async function updateWorkbenchTaskStatus(taskId, status) {
  if (!taskId) {
    throw new Error("Missing task id.");
  }
  await api("POST", "/agent-room/task/status", {
    root: workspaceRoot(),
    task_id: taskId,
    status,
    note: "Updated from Studio GWT Workbench.",
  });
  await refresh();
}

async function requestTaskApproval(entry) {
  if (!entry || !entry.task_id) {
    throw new Error("Missing task id.");
  }
  const packetId = entry.packet_id || "";
  const runId = entry.run_id || (packetId ? `run_${packetId}` : `run_${entry.task_id}`);
  const target = packetId ? `codex exec .harvis/outbox/${packetId}.md` : `task ${entry.task_id}`;
  const approval = await api("POST", "/request-approval", {
    root: workspaceRoot(),
    run_id: runId,
    action_type: "run_command",
    target,
    reason: `Studio request for task ${entry.task_id}: ${entry.title || "untitled task"}`,
    risk: "medium",
    scope: "one_time",
  });
  await api("POST", "/agent-room/task/link", {
    root: workspaceRoot(),
    task_id: entry.task_id,
    approval_id: approval.approval_id,
    run_id: runId,
    packet_id: packetId || undefined,
    status: "waiting_approval",
    note: "Approval requested from Studio GWT Workbench.",
  });
  await refresh();
}

async function markWorkbenchMailRead(mailId) {
  if (!mailId) {
    throw new Error("Missing mail id.");
  }
  await api("POST", "/agent-room/mailbox/mark-read", {
    root: workspaceRoot(),
    mail_id: mailId,
    read_by: "studio-workbench",
  });
  await refresh();
}

function graphVaultLabel() {
  const source = state.graph && state.graph.source ? state.graph.source : {};
  const vaults = asArray(source.vaults).map((vault) => vault.workspace_path || vault.name).filter(Boolean);
  return vaults.length ? `${source.kind || "vault"} · ${vaults.slice(0, 3).join(", ")}` : "No vault scanned.";
}

function graphTopTags(limit = 5) {
  return graphTags().slice(0, limit);
}

function graphDegree(node) {
  return Number(node && node.in_degree || 0) + Number(node && node.out_degree || 0);
}

function graphTopNodes(limit = 6) {
  return graphNodes()
    .filter((node) => node.type === "note")
    .sort((left, right) => graphDegree(right) - graphDegree(left))
    .slice(0, limit);
}

function renderDashboardGraphDock() {
  const stats = graphStats();
  const nodes = graphTopNodes(14);
  const tags = graphTopTags(5);
  const mode = els.graphModeSelect.value === "galaxy" ? "Galaxy linked" : "Workbench ready";
  els.dashboardGraphMode.textContent = state.graph ? mode : "not loaded";
  els.dashboardGraphStage.dataset.state = graphRuntimeState();
  els.dashboardGraphSource.textContent = state.graph
    ? `${graphVaultLabel()} · ${stats.node_count || 0} nodes · ${stats.edge_count || 0} edges`
    : "No vault scanned.";

  els.dashboardGraphTags.innerHTML = "";
  if (!tags.length) {
    const tag = document.createElement("span");
    tag.textContent = "no tags";
    els.dashboardGraphTags.append(tag);
  } else {
    for (const tagName of tags) {
      const tag = document.createElement("button");
      tag.type = "button";
      tag.className = "mini-tag graph-tag-button";
      tag.textContent = `#${tagName}`;
      tag.addEventListener("click", () => {
        els.graphTagFilter.value = tagName;
        els.graphModeSelect.value = "workbench";
        switchView("graph");
        renderKnowledgeGraph();
      });
      els.dashboardGraphTags.append(tag);
    }
  }

  setStack(
    els.dashboardGraphFocus,
    graphTopNodes(3).map((node) => item(node.title || node.id, `${graphDegree(node)} links · ${asArray(node.tags).slice(0, 2).join(", ") || "untagged"}`, node.type || "note")),
    "No graph focus.",
  );
  renderDashboardGraphMini(nodes);
}

function renderDashboardGraphMini(nodes) {
  const svg = els.dashboardGraphMini;
  svg.innerHTML = "";
  if (!state.graph || !nodes.length) {
    const text = makeSvg("text", { x: 160, y: 94, "text-anchor": "middle", class: "graph-empty-text" });
    text.textContent = "No graph data.";
    svg.append(text);
    return;
  }
  for (const radius of [34, 62, 90]) {
    svg.append(makeSvg("circle", { cx: 160, cy: 90, r: radius, class: "dashboard-graph-orbit" }));
  }
  const strongest = nodes[0];
  const nodeIds = new Set(nodes.map((node) => node.id));
  const positions = new Map();
  nodes.forEach((node, index) => {
    if (index === 0) {
      positions.set(node.id, { x: 160, y: 90 });
      return;
    }
    const angle = (Math.PI * 2 * (index - 1)) / Math.max(nodes.length - 1, 1) - Math.PI / 2;
    const radius = index % 2 ? 74 : 96;
    positions.set(node.id, {
      x: 160 + Math.cos(angle) * radius,
      y: 90 + Math.sin(angle) * radius * 0.64,
    });
  });
  for (const edge of graphEdges().filter((edge) => nodeIds.has(edge.source) && nodeIds.has(edge.target)).slice(0, 28)) {
    const source = positions.get(edge.source);
    const target = positions.get(edge.target);
    if (!source || !target) {
      continue;
    }
    svg.append(makeSvg("line", {
      x1: source.x,
      y1: source.y,
      x2: target.x,
      y2: target.y,
      class: `dashboard-graph-edge dashboard-graph-edge-${edge.type}`,
    }));
  }
  for (const node of nodes) {
    const position = positions.get(node.id);
    if (!position) {
      continue;
    }
    const group = makeSvg("g", { class: `dashboard-graph-node ${node.id === strongest.id ? "core" : ""}`, tabindex: 0 });
    group.append(makeSvg("circle", {
      cx: position.x,
      cy: position.y,
      r: node.id === strongest.id ? 13 : Math.min(11, 6 + graphDegree(node)),
      fill: graphColor(node),
    }));
    group.addEventListener("click", () => {
      state.selectedGraphNodeId = node.id;
      els.graphModeSelect.value = "galaxy";
      switchView("graph");
      renderKnowledgeGraph();
    });
    group.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        state.selectedGraphNodeId = node.id;
        els.graphModeSelect.value = "galaxy";
        switchView("graph");
        renderKnowledgeGraph();
      }
    });
    svg.append(group);
  }
}

function sliderValue(input) {
  const value = Number(input.value);
  return Number.isFinite(value) ? value : 0;
}

function toneOf(persona) {
  return persona && typeof persona.tone === "object" && persona.tone ? persona.tone : {};
}

function styleOf(persona) {
  return persona && typeof persona.decision_style === "object" && persona.decision_style ? persona.decision_style : {};
}

function syncSliderLabels() {
  els.warmthValue.textContent = els.warmthInput.value;
  els.directnessValue.textContent = els.directnessInput.value;
  els.humorValue.textContent = els.humorInput.value;
  els.detailValue.textContent = els.detailInput.value;
  els.encouragementValue.textContent = els.encouragementInput.value;
  els.criticismValue.textContent = els.criticismInput.value;
}

function fillEditor(persona) {
  if (!persona) {
    els.editorStatus.textContent = "no persona";
    els.personaNameInput.value = "";
    els.visualAssetInput.value = "";
    els.rulesInput.value = "";
    for (const input of toneInputs()) {
      input.value = 0;
    }
    syncSliderLabels();
    return;
  }
  const tone = toneOf(persona);
  const style = styleOf(persona);
  els.editorStatus.textContent = persona.persona_id;
  els.personaNameInput.value = persona.display_name || "";
  els.visualAssetInput.value = persona.visual_asset_id || "";
  els.warmthInput.value = tone.warmth ?? 7;
  els.directnessInput.value = tone.directness ?? 7;
  els.humorInput.value = tone.humor ?? 3;
  els.detailInput.value = tone.detail ?? 8;
  els.encouragementInput.value = tone.encouragement ?? 6;
  els.criticismInput.value = tone.criticism ?? 4;
  els.evidenceInput.checked = style.evidence_first !== false;
  els.challengeInput.checked = style.challenge_user !== false;
  els.verificationInput.checked = style.prefer_verification !== false;
  els.riskInput.value = style.risk_tolerance || "medium";
  els.rulesInput.value = asArray(persona.behavior_rules).join("\n");
  els.testPersonaName.textContent = persona.display_name || "Selected Persona";
  syncSliderLabels();
}

function renderPersonaStudio() {
  const cards = currentPersonaCards();
  if (!cards.find((persona) => persona.persona_id === state.selectedPersonaId)) {
    state.selectedPersonaId = cards[0] ? cards[0].persona_id : "";
  }
  els.personaList.innerHTML = "";
  if (!cards.length) {
    els.personaList.classList.add("empty");
    els.personaList.textContent = "No personas.";
  } else {
    els.personaList.classList.remove("empty");
    for (const persona of cards) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = persona.persona_id === state.selectedPersonaId ? "persona-card active" : "persona-card";
      button.innerHTML = `<strong></strong><small></small>`;
      button.querySelector("strong").textContent = persona.display_name || persona.persona_id;
      button.querySelector("small").textContent = `${persona.persona_id} · ${labelForStatus(persona.status)}`;
      button.addEventListener("click", () => {
        state.selectedPersonaId = persona.persona_id;
        renderPersonaStudio();
        runLocalTest();
      });
      els.personaList.append(button);
    }
  }
  fillEditor(selectedPersona());
}

const builderStepNames = [
  "Memory Vault",
  "Persona Template",
  "Appearance",
  "Behavior",
  "Permissions",
  "Create Twin",
  "Test Room",
];

function selectedBuilderVault() {
  return currentVaults().find((vault) => vault.vault_id === state.builderVaultId) || currentVaults()[0] || null;
}

function selectedBuilderPersona() {
  return currentPersonaCards().find((persona) => persona.persona_id === state.builderPersonaId) || selectedPersona();
}

function setOptions(select, rows, valueKey, labelKey, selectedValue) {
  const previous = select.value || selectedValue || "";
  select.innerHTML = "";
  for (const row of rows) {
    const option = document.createElement("option");
    option.value = row[valueKey] || "";
    option.textContent = row[labelKey] || row[valueKey] || "Untitled";
    select.append(option);
  }
  if (rows.some((row) => row[valueKey] === previous)) {
    select.value = previous;
  } else if (rows[0]) {
    select.value = rows[0][valueKey];
  }
}

function builderPermissions() {
  return {
    read_memory: els.builderPermRead.checked,
    write_candidate_memory: els.builderPermWriteCandidate.checked,
    write_accepted_memory: els.builderPermWriteAccepted.checked,
    run_tools: els.builderRunToolsSelect.value,
  };
}

function renderCopyBuilder() {
  const vaults = currentVaults();
  const personas = currentPersonaCards();
  setOptions(els.builderVaultSelect, vaults, "vault_id", "display_name", state.builderVaultId);
  setOptions(els.builderPersonaSelect, personas, "persona_id", "display_name", state.builderPersonaId || state.selectedPersonaId);
  state.builderVaultId = els.builderVaultSelect.value;
  state.builderPersonaId = els.builderPersonaSelect.value;

  const vault = selectedBuilderVault();
  const persona = selectedBuilderPersona();
  const tone = toneOf(persona);
  const style = styleOf(persona);
  if (!els.builderVisualInput.value && persona) {
    els.builderVisualInput.value = persona.visual_asset_id || "harvis-persona-system";
  }
  if (!els.builderBehaviorInput.value && persona) {
    els.builderBehaviorInput.value = asArray(persona.behavior_rules).join("\n");
  }
  if (!els.builderTwinNameInput.value && persona) {
    els.builderTwinNameInput.value = `${persona.display_name || "H.A.R.V.I.S."} Twin`;
  }

  document.querySelectorAll(".step-button").forEach((button) => {
    button.classList.toggle("active", Number(button.dataset.builderStep) === state.builderStep);
  });
  document.querySelectorAll("[data-builder-panel]").forEach((panel) => {
    panel.classList.toggle("active", Number(panel.dataset.builderPanel) === state.builderStep);
  });
  els.builderStepTitle.textContent = builderStepNames[state.builderStep];
  els.builderStepHint.textContent = `Step ${state.builderStep + 1} of 7`;
  els.builderPrevButton.disabled = state.builderStep === 0;
  els.builderNextButton.textContent = state.builderStep === 6 ? "Finish" : "Next";
  els.builderVaultMeta.textContent = vault
    ? `${vault.vault_id} · ${vault.memory_items || 0} item(s) · ${vault.visibility || "private"}`
    : "No memory vault available. Initialize the workspace first.";
  els.builderPersonaMeta.textContent = persona
    ? `${persona.persona_id} · warmth ${tone.warmth ?? "-"} · directness ${tone.directness ?? "-"} · risk ${style.risk_tolerance || "medium"}`
    : "No persona template available.";
  els.builderPreviewVault.textContent = vault ? vault.display_name : "-";
  els.builderPreviewPersona.textContent = persona ? persona.display_name : "-";
  els.builderPreviewAppearance.textContent = `${els.builderVisualInput.value || "-"} · ${els.builderAppearanceSelect.value}`;
  const permissions = builderPermissions();
  els.builderPreviewPermissions.textContent = `${permissions.run_tools}; memory=${permissions.read_memory ? "read" : "blocked"}; candidate=${permissions.write_candidate_memory ? "write" : "blocked"}`;
  els.builderPreviewState.textContent = state.builderCreatedTwin ? "created" : "not created";
  els.builderStatus.textContent = state.builderCreatedTwin ? "created" : "draft";
}

function switchBuilderStep(step) {
  state.builderStep = Math.max(0, Math.min(step, builderStepNames.length - 1));
  renderCopyBuilder();
}

function runBuilderTest() {
  const persona = selectedBuilderPersona();
  const vault = selectedBuilderVault();
  const prompt = els.builderTestPromptInput.value.trim() || "What should this twin do first?";
  if (!persona || !vault) {
    els.builderTestPreview.textContent = "Select a memory vault and persona template first.";
    return;
  }
  const permissions = builderPermissions();
  const behavior = els.builderBehaviorInput.value.split("\n").map((line) => line.trim()).filter(Boolean)[0] || "Inspect context before acting.";
  els.builderTestPreview.textContent = `${persona.display_name} would read ${vault.display_name}, keep tools ${permissions.run_tools}, and start with: ${behavior} Prompt focus: ${prompt}`;
}

async function createBuilderTwin() {
  const vault = selectedBuilderVault();
  const persona = selectedBuilderPersona();
  const name = els.builderTwinNameInput.value.trim();
  if (!vault || !persona || !name) {
    throw new Error("Twin name, memory vault, and persona template are required.");
  }
  els.builderStatus.textContent = "creating";
  const created = await api("POST", "/persona/create-twin", {
    root: workspaceRoot(),
    display_name: name,
    memory_vault_id: vault.vault_id,
    persona_card_id: persona.persona_id,
    permissions: builderPermissions(),
  });
  state.builderCreatedTwin = created;
  els.builderCreateResult.textContent = `${created.display_name} created as ${created.instance_id}.`;
  switchBuilderStep(6);
  await refresh();
}

function renderMemory() {
  setStack(
    els.vaultList,
    currentVaults().map((vault) => item(vault.display_name || vault.vault_id, `${vault.vault_id} · ${vault.memory_items || 0} items`, vault.status || "")),
    "No vaults.",
  );
  setStack(
    els.candidateList,
    asArray(state.persona && state.persona.personality_candidates).map((candidate) => item(candidate.trait || candidate.candidate_id, `${candidate.target_persona_id || "persona"} · ${labelForStatus(candidate.status)}`, candidate.trait_type || "trait")),
    "No candidates.",
  );
}

function graphNodes() {
  return asArray(state.graph && state.graph.nodes);
}

function graphEdges() {
  return asArray(state.graph && state.graph.edges);
}

function graphStats() {
  return (state.graph && state.graph.stats) || {};
}

function graphTags() {
  const stats = graphStats();
  return asArray(stats.tags).map((entry) => Array.isArray(entry) ? entry[0] : "").filter(Boolean);
}

function graphRuntimeState() {
  return normalizeRuntimeState(els.runtimeState.textContent || "idle");
}

function selectedGraphNode() {
  const nodes = graphNodes();
  return nodes.find((node) => node.id === state.selectedGraphNodeId) || nodes[0] || null;
}

function graphNodeMatches(node, search, tag) {
  if (tag && !asArray(node.tags).includes(tag)) {
    return false;
  }
  if (!search) {
    return true;
  }
  const haystack = [node.title, node.id, node.type, ...asArray(node.tags)].join(" ").toLowerCase();
  return haystack.includes(search);
}

function filteredGraph() {
  const search = els.graphSearchInput.value.trim().toLowerCase();
  const tag = els.graphTagFilter.value;
  const nodes = graphNodes().filter((node) => graphNodeMatches(node, search, tag)).slice(0, 220);
  const ids = new Set(nodes.map((node) => node.id));
  return {
    nodes,
    edges: graphEdges().filter((edge) => ids.has(edge.source) && ids.has(edge.target)).slice(0, 480),
  };
}

function graphColor(node) {
  if (!node) {
    return "#667085";
  }
  if (node.type === "tag") {
    return "#1c9b69";
  }
  if (node.type === "missing") {
    return "#d7443f";
  }
  const tags = asArray(node.tags);
  if (tags.some((tag) => tag.includes("task") || tag.includes("todo") || tag.includes("execution"))) {
    return "#b97318";
  }
  if (tags.some((tag) => tag.includes("moc") || tag.includes("index"))) {
    return "#6f5bd6";
  }
  return "#315adf";
}

function graphRadius(node) {
  const degree = Number(node.in_degree || 0) + Number(node.out_degree || 0);
  const base = node.type === "note" ? 12 : node.type === "tag" ? 9 : 8;
  return Math.min(28, base + degree * 2);
}

function shouldShowGraphLabel(node, nodeCount, mode = els.graphModeSelect.value) {
  const degree = Number(node.in_degree || 0) + Number(node.out_degree || 0);
  if (mode === "galaxy") {
    return node.id === state.selectedGraphNodeId || nodeCount <= 18 || degree >= 6;
  }
  return nodeCount <= 32 || node.id === state.selectedGraphNodeId || degree >= 3;
}

function layoutGraph(nodes) {
  const centerX = 460;
  const centerY = 270;
  const noteNodes = nodes.filter((node) => node.type === "note");
  const otherNodes = nodes.filter((node) => node.type !== "note");
  const ordered = [...noteNodes, ...otherNodes];
  const count = Math.max(ordered.length, 1);
  const positions = new Map();
  ordered.forEach((node, index) => {
    const ring = node.type === "note" ? 176 : 232;
    const angle = (Math.PI * 2 * index) / count - Math.PI / 2;
    const degree = Number(node.in_degree || 0) + Number(node.out_degree || 0);
    const pull = Math.min(66, degree * 8);
    positions.set(node.id, {
      x: centerX + Math.cos(angle) * Math.max(78, ring - pull),
      y: centerY + Math.sin(angle) * Math.max(64, ring - pull * 0.64),
    });
  });
  const strongest = [...ordered].sort((a, b) => (Number(b.in_degree || 0) + Number(b.out_degree || 0)) - (Number(a.in_degree || 0) + Number(a.out_degree || 0)))[0];
  if (strongest) {
    positions.set(strongest.id, { x: centerX, y: centerY });
  }
  return positions;
}

function makeSvg(tag, attrs = {}) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  Object.entries(attrs).forEach(([key, value]) => node.setAttribute(key, String(value)));
  return node;
}

function renderGraphSvg() {
  const graph = filteredGraph();
  const svg = els.graphSvg;
  svg.innerHTML = "";
  const mode = els.graphModeSelect.value;
  els.graphStage.classList.toggle("galaxy-mode", mode === "galaxy");
  if (!graph.nodes.length) {
    const text = makeSvg("text", { x: 460, y: 270, "text-anchor": "middle", class: "graph-empty-text" });
    text.textContent = state.graph ? "No nodes match the current filters." : "No graph data.";
    svg.append(text);
    return;
  }
  const positions = layoutGraph(graph.nodes);
  const searchActive = Boolean(els.graphSearchInput.value.trim());
  if (mode === "galaxy") {
    for (const radius of [72, 148, 224]) {
      svg.append(makeSvg("circle", { cx: 460, cy: 270, r: radius, class: "graph-orbit" }));
    }
    svg.append(makeSvg("circle", { cx: 460, cy: 270, r: 44, class: "graph-core-glow" }));
    if (searchActive) {
      svg.append(makeSvg("circle", { cx: 460, cy: 270, r: 54, class: "graph-search-pulse" }));
    }
  }
  for (const edge of graph.edges) {
    const source = positions.get(edge.source);
    const target = positions.get(edge.target);
    if (!source || !target) {
      continue;
    }
    const line = makeSvg("line", {
      x1: source.x,
      y1: source.y,
      x2: target.x,
      y2: target.y,
      class: `graph-edge graph-edge-${edge.type}`,
    });
    svg.append(line);
  }
  for (const node of graph.nodes) {
    const position = positions.get(node.id);
    if (!position) {
      continue;
    }
    const group = makeSvg("g", {
      class: `graph-node ${node.id === state.selectedGraphNodeId ? "selected" : ""}`,
      tabindex: 0,
    });
    if (mode === "galaxy" && node.id === state.selectedGraphNodeId) {
      group.append(makeSvg("circle", {
        cx: position.x,
        cy: position.y,
        r: graphRadius(node) + 12,
        class: "graph-selected-ripple",
      }));
    }
    const circle = makeSvg("circle", {
      cx: position.x,
      cy: position.y,
      r: graphRadius(node),
      fill: graphColor(node),
    });
    group.append(circle);
    if (shouldShowGraphLabel(node, graph.nodes.length, mode)) {
      const label = makeSvg("text", {
        x: position.x,
        y: position.y + graphRadius(node) + 16,
        "text-anchor": "middle",
      });
      label.textContent = String(node.title || node.id).slice(0, 24);
      group.append(label);
    }
    group.addEventListener("click", () => {
      state.selectedGraphNodeId = node.id;
      renderKnowledgeGraph();
    });
    group.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        state.selectedGraphNodeId = node.id;
        renderKnowledgeGraph();
      }
    });
    svg.append(group);
  }
}

function graphRelated(node) {
  if (!node) {
    return [];
  }
  const nodesById = new Map(graphNodes().map((entry) => [entry.id, entry]));
  return graphEdges()
    .filter((edge) => edge.source === node.id || edge.target === node.id)
    .slice(0, 16)
    .map((edge) => {
      const otherId = edge.source === node.id ? edge.target : edge.source;
      const other = nodesById.get(otherId);
      return {
        title: other ? other.title : otherId,
        meta: `${edge.type} · ${edge.source === node.id ? "out" : "in"}`,
        badge: other ? other.type : "node",
      };
    });
}

function renderGraphDetail() {
  const node = selectedGraphNode();
  els.graphDetailMeta.innerHTML = "";
  if (!node) {
    els.graphDetailTitle.textContent = "Select a node";
    els.graphDetailType.textContent = "-";
    setStack(els.graphRelatedList, [], "No related nodes.");
    return;
  }
  state.selectedGraphNodeId = node.id;
  els.graphDetailTitle.textContent = node.title || node.id;
  els.graphDetailType.textContent = node.type || "node";
  const rows = [
    ["ID", node.id],
    ["Degree", `${node.in_degree || 0} in / ${node.out_degree || 0} out`],
    ["Tags", asArray(node.tags).join(", ") || "-"],
    ["Updated", formatDate(node.modified_at)],
  ];
  if (node.workspace_path) {
    rows.push(["Path", node.workspace_path]);
  }
  for (const [label, value] of rows) {
    const row = document.createElement("div");
    const span = document.createElement("span");
    const strong = document.createElement("strong");
    span.textContent = label;
    strong.textContent = String(value || "-");
    row.append(span, strong);
    els.graphDetailMeta.append(row);
  }
  setStack(
    els.graphRelatedList,
    graphRelated(node).map((entry) => item(entry.title, entry.meta, entry.badge)),
    "No related nodes.",
  );
}

function syncGraphTagFilter() {
  const previous = els.graphTagFilter.value;
  els.graphTagFilter.innerHTML = "";
  const all = document.createElement("option");
  all.value = "";
  all.textContent = "All tags";
  els.graphTagFilter.append(all);
  for (const tag of graphTags()) {
    const option = document.createElement("option");
    option.value = tag;
    option.textContent = `#${tag}`;
    els.graphTagFilter.append(option);
  }
  if ([...els.graphTagFilter.options].some((option) => option.value === previous)) {
    els.graphTagFilter.value = previous;
  }
}

function renderKnowledgeGraph() {
  const stats = graphStats();
  const source = state.graph && state.graph.source ? state.graph.source : {};
  syncGraphTagFilter();
  els.graphStage.dataset.state = graphRuntimeState();
  const visibleGraph = filteredGraph();
  if (!visibleGraph.nodes.find((node) => node.id === state.selectedGraphNodeId)) {
    state.selectedGraphNodeId = visibleGraph.nodes[0] ? visibleGraph.nodes[0].id : graphNodes()[0] ? graphNodes()[0].id : "";
  }
  els.graphStatus.textContent = state.graph ? (state.graph.read_only ? "read-only" : "unknown") : "not loaded";
  els.graphNoteCount.textContent = String(stats.note_count || 0);
  els.graphEdgeCount.textContent = String(stats.edge_count || 0);
  els.graphTagCount.textContent = String(stats.tag_count || 0);
  els.graphMissingCount.textContent = String(stats.missing_count || 0);
  const vaults = asArray(source.vaults).map((vault) => vault.workspace_path || vault.name).filter(Boolean);
  els.graphSource.textContent = vaults.length ? `${source.kind || "vault"} · ${vaults.join(", ")}` : "No vault scanned.";
  const graphErrors = state.errors.filter((entry) => entry.label === "graph").map((entry) => entry.error);
  const warnings = [...asArray(state.graph && state.graph.warnings), ...asArray(state.graph && state.graph.errors), ...graphErrors];
  setStack(els.graphWarnings, warnings.map((warning) => item("Graph notice", warning)), "No warnings.");
  renderGraphSvg();
  renderGraphDetail();
}

function reviewItems() {
  const personality = asArray(state.persona && state.persona.personality_candidates).map((candidate) => ({
    key: `personality:${candidate.candidate_id}`,
    kind: "personality",
    title: candidate.trait || candidate.candidate_id,
    status: candidate.status || "pending_review",
    body: `Target persona: ${candidate.target_persona_id || "unknown"}. Confidence: ${candidate.confidence ?? "-"}.`,
    evidence: asArray(candidate.source_refs),
    raw: candidate,
  }));
  const memory = reviewableMemoryCandidates().map((candidate) => ({
    key: `memory:${candidate.candidate_id}`,
    kind: "memory",
    title: candidate.name || candidate.candidate_id,
    status: candidate.status || "candidate",
    body: candidate.summary || "Memory candidate requires review.",
    evidence: asArray(candidate.evidence),
    raw: candidate,
  }));
  const approvals = asArray(state.approvals && state.approvals.approvals).map((approval) => ({
    key: `approval:${approval.approval_id}`,
    kind: "approval",
    title: approval.action_type || approval.approval_id,
    status: approval.status || "pending",
    body: `Run: ${approval.run_id || "unknown"} · Risk: ${approval.risk || "medium"} · Scope: ${approval.scope || "one_time"}`,
    evidence: [targetLabel(approval.target), approval.path || ""].filter(Boolean),
    raw: approval,
  }));
  const filter = els.reviewFilter.value;
  return [...personality, ...memory, ...approvals].filter((entry) => filter === "all" || entry.kind === filter);
}

function selectedReviewItem() {
  const items = reviewItems();
  return items.find((entry) => entry.key === state.selectedReviewKey) || items[0] || null;
}

function renderReviewCenter() {
  const personalityCount = asArray(state.persona && state.persona.pending_personality_review).length;
  const memoryCount = reviewableMemoryCandidates().length;
  const approvalCount = asArray(state.approvals && state.approvals.approvals).filter((approval) => !approval.status || approval.status === "pending").length;
  els.reviewPersonalityCount.textContent = String(personalityCount);
  els.reviewMemoryCount.textContent = String(memoryCount);
  els.reviewApprovalCount.textContent = String(approvalCount);
  els.reviewCenterStatus.textContent = `${personalityCount + memoryCount + approvalCount} item(s) need attention. Memory candidates require explicit review before adoption.`;

  const items = reviewItems();
  if (!items.find((entry) => entry.key === state.selectedReviewKey)) {
    state.selectedReviewKey = items[0] ? items[0].key : "";
  }
  els.reviewList.innerHTML = "";
  if (!items.length) {
    els.reviewList.classList.add("empty");
    els.reviewList.textContent = "No review items.";
  } else {
    els.reviewList.classList.remove("empty");
    for (const entry of items) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = entry.key === state.selectedReviewKey ? "active" : "";
      const strong = document.createElement("strong");
      strong.textContent = entry.title || "Untitled review item";
      const small = document.createElement("small");
      small.textContent = `${entry.kind} · ${labelForStatus(entry.status)}`;
      button.append(strong, small);
      button.addEventListener("click", () => {
        state.selectedReviewKey = entry.key;
        renderReviewCenter();
      });
      els.reviewList.append(button);
    }
  }

  const selected = selectedReviewItem();
  if (!selected) {
    els.reviewDetailTitle.textContent = "Select an item";
    els.reviewDetailKind.textContent = "-";
    els.reviewDetailBody.textContent = "Personality changes, memory candidates, and approval items appear here with the safest available action.";
    setStack(els.reviewEvidenceList, [], "No evidence.");
    for (const button of [els.reviewApproveButton, els.reviewRejectButton, els.reviewDeferButton]) {
      button.disabled = true;
    }
    return;
  }
  els.reviewDetailTitle.textContent = selected.title || "Review item";
  els.reviewDetailKind.textContent = selected.kind;
  els.reviewDetailBody.textContent = selected.body || "";
  setStack(els.reviewEvidenceList, selected.evidence.map((evidence) => item("Evidence", evidence)), "No evidence.");
  els.reviewApproveButton.disabled = selected.kind === "memory";
  els.reviewRejectButton.disabled = selected.kind === "memory";
  els.reviewDeferButton.disabled = selected.kind === "memory";
  els.reviewApproveButton.textContent = selected.kind === "approval" ? "Approve" : selected.kind === "personality" ? "Accept" : "Manual";
  els.reviewRejectButton.textContent = selected.kind === "approval" ? "Deny" : "Reject";
  els.reviewDeferButton.textContent = selected.kind === "approval" ? "Cancel" : "Defer";
}

async function decideSelectedReview(action, button, loadingLabel) {
  const selected = selectedReviewItem();
  if (!selected) {
    throw new Error("Select a review item first.");
  }
  const target = selected.raw && (targetLabel(selected.raw.target) || selected.raw.target_persona_id || selected.raw.candidate_id || selected.raw.approval_id);
  const confirmed = await window.HarvisOperator.confirm(els.operatorConfirmDialog, {
    title: `${action === "approve" ? "Approve" : action === "reject" ? "Reject" : "Defer"} this ${selected.kind}?`,
    detail: "The decision changes the review record. Approval still cannot skip handoff, execution, or review evidence.",
    impact: `Scope: ${target || "selected item"} · risk: ${selected.raw.risk || "not recorded"}`,
    accept: action === "approve" ? "Approve" : action === "reject" ? "Reject" : "Defer",
    danger: action === "reject",
  });
  if (!confirmed) return false;
  window.HarvisOperator.setButtonState(button, "loading", loadingLabel);
  if (selected.kind === "personality") {
    const decision = action === "approve" ? "accepted" : action === "reject" ? "rejected" : "deferred";
    await api("POST", "/personality-candidate/decide", {
      root: workspaceRoot(),
      candidate_id: selected.raw.candidate_id,
      decision,
      decided_by: "persona-studio",
      notes: "Reviewed in H.A.R.V.I.S. Review Center.",
    });
  } else if (selected.kind === "approval") {
    const decision = action === "approve" ? "approved" : action === "reject" ? "denied" : "cancelled";
    await api("POST", "/decide-approval", {
      root: workspaceRoot(),
      approval_id: selected.raw.approval_id,
      decision,
      decided_by: "persona-studio",
      notes: "Reviewed in H.A.R.V.I.S. Review Center.",
    });
  } else {
    throw new Error("Memory candidates are manual-review only in this build.");
  }
  state.selectedReviewKey = "";
  await refresh();
  return true;
}

async function generateMemorySnapshot() {
  await api("POST", "/memory-snapshot", {
    root: workspaceRoot(),
    profile_root: profileRoot(),
    max_events: 50,
    max_packets: 50,
    max_reports: 10,
    max_excerpt_chars: 1200,
  });
  await refresh();
}

function renderOutput() {
  els.outputLog.textContent = JSON.stringify(
    {
      health: state.health,
      permission: state.permission,
      bar: state.bar,
      workspaceState: state.workspaceState,
      memoryCandidates: state.memoryCandidates,
      graph: state.graph
        ? {
            graph_version: state.graph.graph_version,
            stats: state.graph.stats,
            source: state.graph.source,
            warnings: state.graph.warnings,
            errors: state.graph.errors,
          }
        : null,
      errors: state.errors,
    },
    null,
    2,
  );
}

function renderAll() {
  renderRuntime();
  renderOperatorOverview();
  renderLarkIntegration();
  renderDashboard();
  renderPorts();
  renderPersonaStudio();
  renderCopyBuilder();
  renderMemory();
  renderKnowledgeGraph();
  renderReviewCenter();
  renderConsole();
  renderOutput();
}

async function refresh() {
  saveInputs();
  state.errors = [];
  setRuntime("reading", "warn");
  els.graphStatus.textContent = "scanning";
  try {
    const root = workspaceRoot();
    const query = { root };
    const requests = [
      { key: "health", run: () => api("GET", "/health") },
      { key: "bar", run: () => api("GET", `/bar/status?${qs(query)}`) },
      { key: "permission", run: () => api("GET", `/permission-probe?${qs({ root, profile_root: profileRoot(), full: "true" })}`) },
      { key: "persona", run: () => api("GET", `/persona?${qs({ root, limit: 100 })}`) },
      { key: "room", run: () => api("GET", `/agent-room?${qs({ root, limit: 80 })}`) },
      { key: "workspaceState", run: () => api("GET", `/agent-room/workspace-state?${qs({ root, limit: 40 })}`) },
      { key: "tasks", run: () => api("GET", `/agent-room/tasks?${qs({ root, limit: 80 })}`) },
      { key: "conversations", run: () => api("GET", `/agent-room/conversations?${qs({ root, limit: 12 })}`) },
      { key: "conversationBindings", run: () => api("GET", `/agent-room/conversation-bindings?${qs({ root, limit: 20 })}`) },
      { key: "handoffs", run: () => api("GET", `/handoffs?${qs({ root, limit: 40 })}`) },
      { key: "runs", run: () => api("GET", `/runs?${qs({ root, limit: 12 })}`) },
      { key: "runTimeline", run: () => api("GET", `/run-timeline?${qs({ root, limit: 24 })}`) },
      { key: "codexBindings", run: () => api("GET", `/codex-thread-bindings?${qs({ root, limit: 20 })}`) },
      { key: "codexPins", run: () => api("GET", `/codex-thread-pins?${qs({ root, limit: 20 })}`) },
      { key: "teamHarness", run: () => api("GET", `/agent-room/team-harness?${qs({ root, limit: 20 })}`) },
      { key: "events", run: () => api("GET", `/events?${qs({ root, limit: 12 })}`) },
      { key: "routerEvents", run: () => api("GET", `/router/events?${qs({ root, limit: 12 })}`) },
      { key: "projects", run: () => api("GET", `/projects?${qs({ root })}`) },
      { key: "agentPools", run: () => api("GET", `/agent-pools?${qs({ root })}`) },
      { key: "agentHarnesses", run: () => api("GET", "/agent-harnesses/status") },
      { key: "ports", run: () => api("GET", "/ports/status") },
      { key: "integrations", run: () => api("GET", `/ui/integrations?${qs(query)}`) },
      { key: "approvals", run: () => api("GET", `/approvals?${qs({ root, limit: 50 })}`) },
      { key: "memoryCandidates", run: () => api("GET", `/memory-candidates?${qs({ root, limit: 50 })}`) },
      { key: "graph", run: () => api("GET", `/knowledge-graph?${qs({ root })}`) },
    ];
    const results = await runLimitedRequests(requests, 3);
    const keys = requests.map((request) => request.key);
    results.forEach((result, index) => {
      const key = keys[index];
      if (result.ok) {
        state[key] = result.data;
        if (key === "integrations") state.integrationError = "";
      } else {
        if (key === "graph") {
          state.graph = null;
        } else if (key === "workspaceState") {
          state.workspaceState = null;
        } else if (key === "tasks") {
          state.tasks = null;
        } else if (key === "conversations") {
          state.conversations = null;
        } else if (key === "conversationBindings") {
          state.conversationBindings = null;
        } else if (key === "handoffs") {
          state.handoffs = null;
        } else if (key === "runs") {
          state.runs = null;
        } else if (key === "runTimeline") {
          state.runTimeline = null;
        } else if (key === "codexBindings") {
          state.codexBindings = null;
        } else if (key === "codexPins") {
          state.codexPins = null;
        } else if (key === "teamHarness") {
          state.teamHarness = null;
        } else if (key === "approvals") {
          state.approvals = null;
        } else if (key === "memoryCandidates") {
          state.memoryCandidates = null;
        } else if (key === "ports") {
          state.ports = null;
        } else if (key === "integrations") {
          state.integrations = null;
          state.integrationError = result.error;
          return;
        }
        state.errors.push({ label: result.label, error: result.error });
      }
    });
    renderAll();
    setRuntime(state.errors.length ? "blocked" : "verified", state.errors.length ? "warn" : "ok");
  } catch (error) {
    state.errors.push({ label: "refresh", error: error.message || String(error) });
    renderAll();
    setRuntime("blocked", "bad");
  }
}

async function initializeWorkspace() {
  saveInputs();
  const root = workspaceRoot();
  setRuntime("acting", "warn");
  await api("POST", "/persona/init", { root });
  await api("POST", "/agent-room/init", { root });
  await refresh();
}

function toneInputs() {
  return [
    els.warmthInput,
    els.directnessInput,
    els.humorInput,
    els.detailInput,
    els.encouragementInput,
    els.criticismInput,
  ];
}

function editorTone() {
  return {
    warmth: sliderValue(els.warmthInput),
    directness: sliderValue(els.directnessInput),
    humor: sliderValue(els.humorInput),
    detail: sliderValue(els.detailInput),
    encouragement: sliderValue(els.encouragementInput),
    criticism: sliderValue(els.criticismInput),
  };
}

function editorDecisionStyle() {
  return {
    evidence_first: els.evidenceInput.checked,
    challenge_user: els.challengeInput.checked,
    prefer_verification: els.verificationInput.checked,
    risk_tolerance: els.riskInput.value,
  };
}

function editorRules() {
  return els.rulesInput.value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 12);
}

async function savePersona() {
  const persona = selectedPersona();
  if (!persona) {
    throw new Error("Select a persona first.");
  }
  els.editorStatus.textContent = "saving";
  await api("POST", "/persona/update-card", {
    root: workspaceRoot(),
    persona_id: persona.persona_id,
    display_name: els.personaNameInput.value.trim(),
    visual_asset_id: els.visualAssetInput.value.trim(),
    tone: editorTone(),
    decision_style: editorDecisionStyle(),
    behavior_rules: editorRules(),
  });
  els.editorStatus.textContent = "saved";
  await refresh();
}

async function createPersona() {
  const name = window.prompt("Persona display name", "H.A.R.V.I.S. Specialist");
  if (!name || !name.trim()) {
    return;
  }
  const created = await api("POST", "/persona/create-card", {
    root: workspaceRoot(),
    display_name: name.trim(),
    visual_asset_id: "harvis-persona-system",
  });
  state.selectedPersonaId = created.persona_id || state.selectedPersonaId;
  await refresh();
}

async function createCopyMe() {
  const persona = selectedPersona();
  const vault = currentVaults()[0];
  if (!persona || !vault) {
    throw new Error("A persona and a memory vault are required.");
  }
  state.builderVaultId = vault.vault_id;
  state.builderPersonaId = persona.persona_id;
  state.builderStep = 0;
  els.builderTwinNameInput.value = `${persona.display_name || "H.A.R.V.I.S."} Twin`;
  els.builderVisualInput.value = persona.visual_asset_id || "harvis-persona-system";
  els.builderBehaviorInput.value = asArray(persona.behavior_rules).join("\n");
  switchView("copy");
  renderCopyBuilder();
}

async function createTraitCandidate() {
  const persona = selectedPersona();
  if (!persona) {
    throw new Error("Select a persona first.");
  }
  const trait = window.prompt("Trait candidate", "Prefers concise status, then concrete next action.");
  if (!trait || !trait.trim()) {
    return;
  }
  await api("POST", "/personality-candidate", {
    root: workspaceRoot(),
    target_persona_id: persona.persona_id,
    trait: trait.trim(),
    source_type: "persona-studio",
    trait_type: "behavior_rule",
    confidence_percent: 65,
  });
  await refresh();
}

async function createTopic() {
  const title = window.prompt("Agent Room topic", "UI upgrade review");
  if (!title || !title.trim()) {
    return;
  }
  await api("POST", "/agent-room/topic", {
    root: workspaceRoot(),
    title: title.trim(),
    goal: "Keep H.A.R.V.I.S. changes auditable and human-reviewed.",
    created_by: "persona-studio",
  });
  await refresh();
}

function runLocalTest() {
  const persona = selectedPersona();
  const prompt = els.testPromptInput.value.trim() || "How would you approach this task?";
  if (!persona) {
    els.personaPreview.textContent = "Select a persona before running a local style preview.";
    els.defaultPreview.textContent = "Default response preview is waiting.";
    return;
  }
  const tone = editorTone();
  const style = editorDecisionStyle();
  const rules = editorRules();
  const directness = tone.directness >= 7 ? "I would start with the smallest verifiable step" : "I would first map the context gently";
  const detail = tone.detail >= 7 ? "then capture evidence, risks, and a concrete verification path" : "then keep the first pass intentionally light";
  const warmth = tone.warmth >= 7 ? "I will keep the loop warm and steady" : "I will keep the loop compact";
  const challenge = style.challenge_user ? "If the premise looks risky, I will call that out before acting." : "I will avoid challenging the premise unless evidence forces it.";
  els.testPersonaName.textContent = persona.display_name || "Selected Persona";
  els.personaPreview.textContent = `${directness}, ${detail}. ${warmth}. ${challenge} Prompt focus: ${prompt}`;
  els.defaultPreview.textContent = `I can help with that. I will review the context, propose a plan, and summarize next steps for: ${prompt}`;
  if (rules.length) {
    els.personaPreview.textContent += ` Active rule: ${rules[0]}`;
  }
}

function switchView(name) {
  document.querySelectorAll(".nav-item").forEach((button) => {
    const active = button.dataset.view === name;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  document.querySelectorAll(".view").forEach((view) => {
    const active = view.id === `${name}View`;
    view.classList.toggle("active", active);
    if (active) {
      els.viewTitle.textContent = view.dataset.title || name;
    }
  });
}

document.querySelectorAll(".nav-item").forEach((button) => {
  button.addEventListener("click", () => switchView(button.dataset.view));
});

document.querySelectorAll("[data-view-jump]").forEach((button) => {
  button.addEventListener("click", () => {
    if (button.dataset.graphMode && els.graphModeSelect) {
      els.graphModeSelect.value = button.dataset.graphMode;
      renderKnowledgeGraph();
    }
    switchView(button.dataset.viewJump);
  });
});

for (const input of toneInputs()) {
  input.addEventListener("input", () => {
    syncSliderLabels();
    runLocalTest();
  });
}

for (const input of [els.evidenceInput, els.challengeInput, els.verificationInput, els.riskInput, els.rulesInput, els.testPromptInput]) {
  input.addEventListener("input", runLocalTest);
}

document.querySelectorAll("[data-builder-step]").forEach((button) => {
  button.addEventListener("click", () => switchBuilderStep(Number(button.dataset.builderStep)));
});

for (const input of [
  els.builderVaultSelect,
  els.builderPersonaSelect,
  els.builderVisualInput,
  els.builderAppearanceSelect,
  els.builderBehaviorInput,
  els.builderPermRead,
  els.builderPermWriteCandidate,
  els.builderPermWriteAccepted,
  els.builderRunToolsSelect,
  els.builderTwinNameInput,
]) {
  input.addEventListener("input", () => {
    state.builderVaultId = els.builderVaultSelect.value;
    state.builderPersonaId = els.builderPersonaSelect.value;
    renderCopyBuilder();
  });
}

els.tokenInput.addEventListener("change", saveInputs);
els.refreshButton.addEventListener("click", () => window.HarvisOperator.action(els.refreshButton, refresh, {
  idle: "Refresh",
  loading: "Refreshing…",
  success: "Refreshed",
  error: "Failed — retry",
}).catch(() => {}));
els.firstRunRefreshButton.addEventListener("click", () => refresh());
els.portRefreshButton.addEventListener("click", () => refresh());
els.harnessSmokeButton.addEventListener("click", () => runHarnessSmoke().catch((error) => {
  state.errors.push({ label: "harness smoke", error: error.message || String(error) });
  renderAll();
  setRuntime("blocked", "bad");
}));
els.initButton.addEventListener("click", () => initializeWorkspace().catch((error) => {
  state.errors.push({ label: "initialize", error: error.message || String(error) });
  renderAll();
  setRuntime("blocked", "bad");
}));
els.savePersonaButton.addEventListener("click", () => savePersona().catch((error) => {
  els.editorStatus.textContent = "blocked";
  state.errors.push({ label: "save persona", error: error.message || String(error) });
  renderAll();
}));
els.personaButton.addEventListener("click", () => createPersona().catch((error) => {
  state.errors.push({ label: "create persona", error: error.message || String(error) });
  renderAll();
}));
els.copyButton.addEventListener("click", () => createCopyMe().catch((error) => {
  state.errors.push({ label: "create copy", error: error.message || String(error) });
  renderAll();
}));
els.candidateButton.addEventListener("click", () => createTraitCandidate().catch((error) => {
  state.errors.push({ label: "candidate", error: error.message || String(error) });
  renderAll();
}));
els.topicButton.addEventListener("click", () => createTopic().catch((error) => {
  state.errors.push({ label: "agent room topic", error: error.message || String(error) });
  renderAll();
}));
els.runTestButton.addEventListener("click", runLocalTest);
els.builderPrevButton.addEventListener("click", () => switchBuilderStep(state.builderStep - 1));
els.builderNextButton.addEventListener("click", () => switchBuilderStep(state.builderStep + 1));
els.builderCreateButton.addEventListener("click", () => createBuilderTwin().catch((error) => {
  els.builderStatus.textContent = "blocked";
  state.errors.push({ label: "create builder twin", error: error.message || String(error) });
  renderAll();
}));
els.builderTestButton.addEventListener("click", runBuilderTest);
els.memorySnapshotButton.addEventListener("click", () => generateMemorySnapshot().catch((error) => {
  state.errors.push({ label: "memory snapshot", error: error.message || String(error) });
  renderAll();
}));
els.reviewFilter.addEventListener("input", () => {
  state.selectedReviewKey = "";
  renderReviewCenter();
});
for (const input of [els.graphSearchInput, els.graphTagFilter, els.graphModeSelect]) {
  input.addEventListener("input", () => {
    state.selectedGraphNodeId = "";
    renderKnowledgeGraph();
  });
}
for (const [button, actionName, label] of [
  [els.reviewApproveButton, "approve", "Approving…"],
  [els.reviewRejectButton, "reject", "Rejecting…"],
  [els.reviewDeferButton, "defer", "Deferring…"],
]) {
  button.addEventListener("click", async () => {
    const idle = button.textContent;
    try {
      const changed = await decideSelectedReview(actionName, button, label);
      if (changed) window.HarvisOperator.setButtonState(button, "success", "Recorded");
      else window.HarvisOperator.setButtonState(button, "idle", idle);
    } catch (error) {
      window.HarvisOperator.setButtonState(button, "error", "Failed — retry");
      state.errors.push({ label: `review ${actionName}`, error: error.message || String(error) });
      renderAll();
    }
  });
}

els.opNextButton.addEventListener("click", () => switchView(els.opNextButton.dataset.targetView || "work"));
document.querySelectorAll("[data-op-fixture-action]").forEach((button) => {
  button.addEventListener("click", async () => {
    const action = button.dataset.opFixtureAction;
    const accepted = await window.HarvisOperator.confirm(els.operatorConfirmDialog, {
      title: `${action} fixture approval?`,
      detail: "This fixture validates confirmation UX only; it cannot mutate runtime state.",
      impact: "Scope: fixture evidence · no server write",
      accept: action === "approve" ? "Approve" : action === "reject" ? "Reject" : "Defer",
      danger: action === "reject",
    });
    if (accepted) window.HarvisOperator.setButtonState(button, "idle", "Fixture only");
  });
});
els.consoleSendButton.addEventListener("click", () => runAgentConsole().catch((error) => {
  state.errors.push({ label: "agent console", error: error.message || String(error) });
  renderConsoleError("agent console", error);
}));
els.consoleStatusButton.addEventListener("click", () => runAgentConsole("现在到哪一步了？").catch((error) => {
  state.errors.push({ label: "agent console status", error: error.message || String(error) });
  renderConsoleError("agent console status", error);
}));
els.consoleClearButton.addEventListener("click", () => {
  state.consoleResult = null;
  els.consoleMessageIdInput.value = "";
  renderConsole();
});

syncSliderLabels();
if (viewParams.get("view")) {
  switchView(viewParams.get("view"));
}
window.HarvisRuntime.bootstrap()
  .then((bootstrap) => {
    runtimeRoot = bootstrap.workspaceRoot;
    window.HarvisRuntime.applyWorkspaceLabel(els.rootInput, bootstrap.workspaceLabel);
    return refresh();
  })
  .catch((error) => {
    state.errors.push({ label: "runtime bootstrap", error: error.message || String(error) });
    renderAll();
    setRuntime("blocked", "bad");
  });
