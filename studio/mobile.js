const $ = (id) => document.getElementById(id);

const els = {
  shell: document.querySelector(".mobile-shell"), refreshButton: $("refreshButton"), saveButton: $("saveButton"), rootInput: $("rootInput"), tokenInput: $("tokenInput"),
  nextAction: $("mobileNextAction"), nextTitle: $("mobileNextTitle"), nextDetail: $("mobileNextDetail"), nextImpact: $("mobileNextImpact"), nextLink: $("mobileNextLink"),
  healthSignal: $("mobileHealthSignal"), healthValue: $("mobileHealthValue"), activeSignal: $("mobileActiveSignal"), activeValue: $("mobileActiveValue"),
  blockedSignal: $("mobileBlockedSignal"), blockedValue: $("mobileBlockedValue"), approvalSignal: $("mobileApprovalSignal"), approvalValue: $("mobileApprovalValue"),
  larkSignal: $("mobileLarkSignal"), larkValue: $("mobileLarkValue"), nextSignal: $("mobileNextSignal"), nextValue: $("mobileNextValue"), lineage: $("mobileLineage"),
  approvalCount: $("approvalCount"), approvalList: $("mobileApprovalList"), openTaskCount: $("openTaskCount"), taskStatusMeta: $("taskStatusMeta"), taskStatusList: $("taskStatusList"),
  pinCount: $("pinCount"), pinBoardMeta: $("pinBoardMeta"), pinBoardList: $("pinBoardList"), larkActionCount: $("larkActionCount"), larkActionMeta: $("larkActionMeta"), larkActionList: $("larkActionList"),
  timelineMeta: $("timelineMeta"), runTimelineList: $("runTimelineList"), bindingMeta: $("bindingMeta"), bindingList: $("bindingList"), connectionState: $("connectionState"), diagnosticLog: $("diagnosticLog"),
};

let runtimeRoot = "";

function qs(data) { return new URLSearchParams(data).toString(); }
function root() { if (!runtimeRoot) throw new Error("需要先取得 workspace。"); return runtimeRoot; }
function asArray(value) { return Array.isArray(value) ? value : []; }
function arrayAt(value, keys) { for (const key of keys) if (Array.isArray(value && value[key])) return value[key]; return []; }
function firstText(item, keys, fallback = "未记录") { for (const key of keys) { const value = item && item[key]; if (typeof value === "string" && value.trim()) return value.trim(); if (typeof value === "number") return String(value); } return fallback; }
function classifyStatus(status) { if (/done|complete|success|reviewed|verified|approved/i.test(status)) return "good"; if (/fail|block|error|cancel|denied/i.test(status)) return "bad"; if (/wait|pending|approval|review|progress|running|planning/i.test(status)) return "warn"; return ""; }
function statusIsBlocked(value) { return /blocked|failed|error|denied|cancelled/.test(String(value || "").toLowerCase()); }
function statusIsActive(value) { return /running|acting|working|planning|in_progress|executing/.test(String(value || "").toLowerCase()); }
function statusIsComplete(value) { return /done|complete|completed|reviewed|verified|approved|accepted|success/.test(String(value || "").toLowerCase()); }
function isSensitiveKey(key) { return /token|secret|cookie|authorization|password|credential|api[_-]?key|access[_-]?file/i.test(key); }
function scrub(value, key = "") { return isSensitiveKey(key) ? "[redacted]" : window.HarvisRuntime.scrub(value, runtimeRoot, key); }

async function api(path) {
  const controller = new AbortController();
  const timeoutId = window.setTimeout(() => controller.abort(), 7000);
  try {
    const response = await fetch(path, { headers: { ...window.HarvisRuntime.bearerHeaders(els.tokenInput) }, signal: controller.signal });
    const payload = await response.json();
    if (!payload.ok) throw new Error(payload.error && payload.error.message ? payload.error.message : "request failed");
    return scrub(payload.data);
  } catch (error) {
    if (error && error.name === "AbortError") throw new Error(`请求超时：${path}`);
    throw error;
  } finally { window.clearTimeout(timeoutId); }
}

async function safe(name, promise) { try { return { name, ok: true, data: await promise }; } catch (error) { return { name, ok: false, error: error.message || String(error) }; } }

function badge(text, className = "") { const node = document.createElement("span"); node.className = `badge ${className}`.trim(); node.textContent = text; return node; }
function item(title, badges, metaLines) {
  const node = document.createElement("article"); node.className = "item";
  const heading = document.createElement("h3"); heading.textContent = title; node.appendChild(heading);
  const row = document.createElement("div"); row.className = "row"; badges.filter(Boolean).forEach((entry) => row.appendChild(entry)); node.appendChild(row);
  const meta = document.createElement("div"); meta.className = "meta"; meta.textContent = metaLines.filter(Boolean).join(" · "); node.appendChild(meta); return node;
}
function empty(label) { const node = document.createElement("div"); node.className = "empty"; node.textContent = label; return node; }
function replaceList(container, nodes, emptyLabel) { container.replaceChildren(...(nodes.length ? nodes : [empty(emptyLabel)])); }
function setSignal(node, valueNode, value, runtimeState) { node.dataset.state = runtimeState; node.dataset.runtimeState = runtimeState; valueNode.textContent = value; }

function explicitLineage(tasks, approvals, handoffs, runs) {
  const task = tasks.find((entry) => statusIsActive(entry.status) || statusIsBlocked(entry.status) || entry.approval_id || entry.handoff_id || entry.run_id) || tasks[0] || null;
  const approval = task && task.approval_id ? approvals.find((entry) => entry.approval_id === task.approval_id) || null : null;
  const handoffId = (task && task.handoff_id) || (approval && approval.handoff_id) || "";
  const handoff = handoffId ? handoffs.find((entry) => entry.handoff_id === handoffId) || null : null;
  const runId = (task && task.run_id) || (approval && approval.run_id) || (handoff && handoff.run_id) || "";
  const run = runId ? runs.find((entry) => entry.run_id === runId) || null : null;
  const linked = [["task", task, task && task.status], ["approval", approval, approval && approval.status], ["handoff", handoff, handoff && (handoff.state || handoff.status)], ["run", run, run && (run.state || run.status)]];
  return linked.map(([stage, entry, status]) => ({ stage, state: !entry ? "idle" : statusIsBlocked(status) ? "blocked" : statusIsComplete(status) ? "verified" : statusIsActive(status) ? "acting" : "thinking", detail: entry ? String(status || "linked").replaceAll("_", " ") : "未关联" }))
    .concat([{ stage: "review", state: handoff && statusIsComplete(handoff.state || handoff.status) ? "verified" : "idle", detail: handoff && statusIsComplete(handoff.state || handoff.status) ? "已留证" : "未关联" }]);
}

function renderLineage(steps) { for (const step of steps) { const node = els.lineage.querySelector(`[data-stage="${step.stage}"]`); node.dataset.state = step.state; node.querySelector("small").textContent = step.detail; } }

function renderApprovals(approvals) {
  const pending = approvals.filter((entry) => !entry.status || /pending|waiting|requested/i.test(String(entry.status)));
  els.approvalCount.textContent = `${pending.length} pending`;
  replaceList(els.approvalList, pending.slice(0, 3).map((entry) => item(
    firstText(entry, ["action_type", "title", "summary"], "待审批动作"),
    [badge(firstText(entry, ["risk"], "risk noted"), "warn"), badge(firstText(entry, ["status"], "pending"), "warn")],
    [`scope ${firstText(entry, ["scope"], "当前项目")}`, `impact ${firstText(entry, ["impact"], "需打开证据")}`],
  )), "当前没有待审批项。");
  return pending;
}

function renderTasks(tasks) {
  const open = tasks.filter((task) => !/done|cancel|complete/i.test(firstText(task, ["status"], "")));
  els.openTaskCount.textContent = String(open.length);
  els.taskStatusMeta.textContent = `${Math.min(open.length, 3)} visible`;
  replaceList(els.taskStatusList, open.slice(0, 3).map((task) => { const status = firstText(task, ["status"], "unknown"); return item(firstText(task, ["title", "subject", "summary"], "未命名任务"), [badge(status, classifyStatus(status)), badge(firstText(task, ["owner_slot_id", "owner"], "未分配"))], [`next ${firstText(task, ["next_action"], "查看证据")}`]); }), "没有打开任务。");
}

function renderPins(data) { const pins = arrayAt(data || {}, ["pins"]); els.pinCount.textContent = String(pins.length); els.pinBoardMeta.textContent = pins.length ? `${pins.length} active` : "no active pins"; replaceList(els.pinBoardList, pins.slice(0, 5).map((pin) => item(firstText(pin, ["label", "title"], "pinned work"), [badge(firstText(pin, ["status", "last_event_type"], "observed"), "warn")], [firstText(pin, ["last_event_at", "created_at"], "未记录时间")])), "没有关注项。"); }
function renderTimeline(data) { const events = arrayAt(data || {}, ["events"]); els.timelineMeta.textContent = events.length ? `${events.length} events` : "no timeline"; replaceList(els.runTimelineList, events.slice(-8).reverse().map((event) => item(firstText(event, ["codex_event_type", "event", "type"], "event"), [badge(firstText(event, ["status", "state"], "observed"), classifyStatus(firstText(event, ["status", "state"], "")))], [firstText(event, ["summary"], "已记录运行时事件"), firstText(event, ["observed_at", "created_at", "timestamp"], "")])), "暂无 timeline。"); }
function renderBindings(data) { const bindings = arrayAt(data || {}, ["bindings"]); els.bindingMeta.textContent = bindings.length ? `${bindings.length} redacted` : "no binding"; replaceList(els.bindingList, bindings.slice(0, 5).map((binding) => item("Redacted conversation", [badge(firstText(binding, ["transport"], "transport")), badge(firstText(binding, ["status"], "observed"), classifyStatus(firstText(binding, ["status"], "")))], [`role ${firstText(binding, ["harness_ref", "agent_ref"], "runtime")}`, "identifiers hidden"])), "暂无 binding。"); }
function renderLarkActions(data) { const actions = arrayAt(data || {}, ["actions"]); const real = Number(data && data.real_clicks || 0); const synthetic = Number(data && data.synthetic_clicks || 0); els.larkActionCount.textContent = String(real); els.larkActionMeta.textContent = `${real} real / ${synthetic} synthetic`; replaceList(els.larkActionList, actions.slice(0, 5).map((action) => item(firstText(action, ["action"], "card action"), [badge(action.dry_run === true ? "synthetic" : "real", action.dry_run === true ? "warn" : "good")], [firstText(action, ["observed_at"], ""), "identifiers hidden"])), "暂无 Lark 卡片回执。"); }

function renderFixture() {
  const fixture = window.HarvisOperator.renderFixture(document); if (!fixture) return false;
  els.shell.dataset.uiState = fixture.name; els.shell.setAttribute("aria-busy", fixture.name === "loading" ? "true" : "false");
  const values = { loading: ["读取中", "未知", "—", "—", "读取中", "等待"], empty: ["健康", "无", "0", "0", "在线", "创建任务"], error: ["不可用", "未知", "1", "未知", "需关注", "重试"], blocked: ["健康", "无", "1", "0", "在线", "查阻塞"], permission: ["健康", "无", "权限", "0", "在线", "查 scope"], approval: ["健康", "无", "0", "1", "在线", "审批"], success: ["健康", "无", "0", "0", "在线", "查看"] };
  const states = { loading: ["reading", "idle", "idle", "idle", "reading", "reading"], empty: ["verified", "idle", "idle", "idle", "verified", "verified"], error: ["blocked", "idle", "blocked", "idle", "blocked", "blocked"], blocked: ["verified", "idle", "blocked", "idle", "verified", "blocked"], permission: ["verified", "idle", "blocked", "idle", "verified", "blocked"], approval: ["verified", "idle", "idle", "thinking", "verified", "thinking"], success: ["verified", "idle", "idle", "idle", "verified", "verified"] };
  [[els.healthSignal, els.healthValue], [els.activeSignal, els.activeValue], [els.blockedSignal, els.blockedValue], [els.approvalSignal, els.approvalValue], [els.larkSignal, els.larkValue], [els.nextSignal, els.nextValue]].forEach(([node, value], index) => setSignal(node, value, values[fixture.name][index], states[fixture.name][index]));
  els.nextAction.dataset.state = fixture.name;
  els.nextTitle.textContent = fixture.title;
  els.nextDetail.textContent = fixture.detail;
  els.nextImpact.textContent = fixture.next;
  els.nextLink.href = ["approval", "blocked", "permission"].includes(fixture.name) ? "/studio/?view=review" : "/studio/?view=work";
  for (const button of [els.refreshButton, els.saveButton]) {
    button.disabled = fixture.name === "loading";
    button.setAttribute("aria-disabled", button.disabled ? "true" : "false");
  }
  els.nextLink.setAttribute("aria-disabled", fixture.name === "loading" ? "true" : "false");
  els.nextLink.tabIndex = fixture.name === "loading" ? -1 : 0;
  return true;
}

function renderDiagnostics(results) { const failed = results.filter((entry) => !entry.ok); els.connectionState.textContent = failed.length ? "partial" : "connected"; els.diagnosticLog.textContent = failed.length ? failed.map((entry) => `${entry.name}: ${entry.error}`).join("\n") : "只读移动视图已加载；敏感标识符保持隐藏。"; }

async function refresh() {
  els.shell.dataset.runtimeState = "reading"; els.shell.dataset.uiState = "loading"; els.shell.setAttribute("aria-busy", "true"); els.connectionState.textContent = "loading";
  try {
    const currentRoot = root(); const query = { root: currentRoot };
    const results = await Promise.all([
      safe("health", api("/health")), safe("workspace", api(`/agent-room/workspace-state?${qs({ ...query, limit: 40 })}`)), safe("tasks", api(`/agent-room/tasks?${qs({ ...query, limit: 80 })}`)),
      safe("approvals", api(`/approvals?${qs({ ...query, limit: 50 })}`)), safe("runs", api(`/runs?${qs({ ...query, limit: 20 })}`)), safe("handoffs", api(`/handoffs?${qs({ ...query, limit: 30 })}`)),
      safe("integrations", api(`/ui/integrations?${qs(query)}`)), safe("pins", api(`/codex-thread-pins?${qs({ ...query, limit: 30 })}`)), safe("lark_actions", api(`/lark/card-actions?${qs({ ...query, limit: 30 })}`)),
      safe("timeline", api(`/run-timeline?${qs({ ...query, limit: 40 })}`)), safe("bindings", api(`/agent-room/conversation-bindings?${qs({ ...query, limit: 30 })}`)),
    ]);
    const data = Object.fromEntries(results.map((entry) => [entry.name, entry.ok ? entry.data : null]));
    const workspaceTasks = arrayAt(data.workspace || {}, ["open_tasks"]); const tasks = workspaceTasks.length ? workspaceTasks : arrayAt(data.tasks || {}, ["tasks", "items"]);
    const approvals = arrayAt(data.approvals || {}, ["approvals", "items"]); const runs = arrayAt(data.runs || {}, ["runs"]); const handoffs = arrayAt(data.handoffs || {}, ["handoffs"]);
    const pending = renderApprovals(approvals); renderTasks(tasks); renderPins(data.pins); renderTimeline(data.timeline); renderBindings(data.bindings); renderLarkActions(data.lark_actions); renderLineage(explicitLineage(tasks, approvals, handoffs, runs));
    const activeRun = runs.find((entry) => statusIsActive(entry.state || entry.status)) || null; const blockedCount = tasks.filter((entry) => statusIsBlocked(entry.status)).length + runs.filter((entry) => statusIsBlocked(entry.state || entry.status)).length;
    const lark = data.integrations && data.integrations.lark; const listenerOnline = Boolean(lark && lark.listener_health === "online"); const larkVerified = Boolean(listenerOnline && lark.smoke && lark.smoke.live_complete && lark.membership_status === "verified"); const healthOk = Boolean(data.health);
    setSignal(els.healthSignal, els.healthValue, healthOk ? "健康" : "不可用", healthOk ? "verified" : "blocked"); setSignal(els.activeSignal, els.activeValue, activeRun ? "运行中" : "无", activeRun ? "acting" : "idle"); setSignal(els.blockedSignal, els.blockedValue, String(blockedCount), blockedCount ? "blocked" : "idle"); setSignal(els.approvalSignal, els.approvalValue, String(pending.length), pending.length ? "thinking" : "idle"); setSignal(els.larkSignal, els.larkValue, larkVerified ? "已验证" : listenerOnline ? "在线·待验" : "需关注", larkVerified ? "verified" : listenerOnline ? "thinking" : "blocked");
    let next = { state: "success", title: "没有紧急动作", detail: "运行时健康，当前没有待审批事项。", impact: "只读 · 不改变状态", href: "/studio/?view=work", short: "查看" };
    if (!healthOk) next = { state: "error", title: "恢复运行时证据", detail: "核心健康读取失败，不从部分数据推断成功。", impact: "只读诊断", href: "/studio/?view=settings", short: "重试" };
    else if (pending.length) next = { state: "approval", title: `审阅 ${pending.length} 个待审批事项`, detail: "先看风险、范围、影响与证据，再做决定。", impact: "状态变更需要桌面端确认", href: "/studio/?view=review", short: "审批" };
    else if (blockedCount) next = { state: "blocked", title: "检查阻塞工作", detail: "沿显式链路定位首个停止阶段。", impact: "只读，直到有人请求审批", href: "/studio/?view=work", short: "查阻塞" };
    else if (!larkVerified) next = { state: "blocked", title: "完成 Lark 现场验证", detail: listenerOnline ? "监听在线；群成员身份和 live E2E 仍需 owner 确认。" : "监听证据不可用。", impact: "此页不会发送消息", href: "/studio/?view=bridge", short: "查 Lark" };
    els.nextAction.dataset.state = next.state; els.nextTitle.textContent = next.title; els.nextDetail.textContent = next.detail; els.nextImpact.textContent = next.impact; els.nextLink.href = next.href; setSignal(els.nextSignal, els.nextValue, next.short, ["error", "blocked"].includes(next.state) ? "blocked" : next.state === "approval" ? "thinking" : "verified");
    els.shell.dataset.runtimeState = blockedCount ? "blocked" : activeRun ? "acting" : "verified"; els.shell.dataset.uiState = blockedCount ? "blocked" : pending.length ? "approval" : "success"; els.shell.setAttribute("aria-busy", "false"); renderDiagnostics(results); renderFixture();
  } catch (error) { els.shell.dataset.runtimeState = "blocked"; els.shell.dataset.uiState = "error"; els.shell.setAttribute("aria-busy", "false"); els.connectionState.textContent = "needs setup"; els.diagnosticLog.textContent = error.message || String(error); renderFixture(); }
}

els.refreshButton.addEventListener("click", () => window.HarvisOperator.action(els.refreshButton, refresh, { loading: "刷新中…", success: "已刷新", error: "重试" }).catch(() => {}));
els.saveButton.addEventListener("click", () => refresh());
window.HarvisRuntime.bootstrap().then((bootstrap) => { runtimeRoot = bootstrap.workspaceRoot; window.HarvisRuntime.applyWorkspaceLabel(els.rootInput, bootstrap.workspaceLabel); return refresh(); }).catch((error) => { els.connectionState.textContent = "needs setup"; els.diagnosticLog.textContent = error.message || "无法取得 workspace。"; });
