(function () {
  "use strict";

  const FIXTURE_NAMES = ["loading", "empty", "error", "blocked", "permission", "approval", "success"];
  const FIXTURES = {
    loading: {
      state: "loading",
      title: "Reading runtime evidence",
      detail: "Health, work, approvals, and integrations are still loading. Actions remain disabled.",
      next: "Wait for evidence before acting.",
      reason: "Evidence request in progress",
      owner: "runtime reader",
      scope: "read-only",
      evidence: "pending server response",
    },
    empty: {
      state: "empty",
      title: "No active work",
      detail: "The runtime is healthy and the work queue is empty.",
      next: "Create or route a task when work is ready.",
      reason: "No open work",
      owner: "operator",
      scope: "none",
      evidence: "empty queue response",
    },
    error: {
      state: "error",
      title: "Runtime evidence unavailable",
      detail: "The last refresh failed. No success state is inferred from stale data.",
      next: "Retry the read-only health check.",
      reason: "Server request failed",
      owner: "runtime service",
      scope: "read-only retry",
      evidence: "error response recorded",
    },
    blocked: {
      state: "blocked",
      title: "Work is blocked",
      detail: "A human decision or failed verification stops this lineage.",
      next: "Open Decisions and inspect the blocking evidence.",
      reason: "Verification or human decision stopped progress",
      owner: "assigned operator",
      scope: "current lineage",
      evidence: "blocking stage and reason required",
    },
    permission: {
      state: "permission",
      title: "Permission is missing",
      detail: "The requested scope is not available. Nothing was executed.",
      next: "Review the exact missing scope before granting access.",
      reason: "Required scope is unavailable",
      owner: "workspace owner",
      scope: "missing scope only · read-only remains available",
      evidence: "permission probe",
    },
    approval: {
      state: "approval",
      title: "Approval required",
      detail: "A state-changing action is waiting for an explicit decision.",
      next: "Review impact, then approve or deny.",
      reason: "State-changing action requested",
      owner: "authorized reviewer",
      scope: "one item · medium risk",
      evidence: "task, target, and approval record",
    },
    success: {
      state: "success",
      title: "Verification complete",
      detail: "The latest operation finished and evidence is available.",
      next: "Review the result or continue to the next safe action.",
      reason: "Server acknowledged completion",
      owner: "runtime verifier",
      scope: "completed operation",
      evidence: "server response and result record",
    },
  };

  function fixtureName() {
    const value = new URL(window.location.href).searchParams.get("fixture") || "";
    return FIXTURE_NAMES.includes(value) ? value : "";
  }

  function fixture() {
    const name = fixtureName();
    return name ? { name, ...FIXTURES[name] } : null;
  }

  function text(node, value) {
    if (node) node.textContent = value == null || value === "" ? "—" : String(value);
  }

  function renderFixture(root = document) {
    const current = fixture();
    const scene = root.querySelector("[data-op-state-scene]");
    if (!scene) return current;
    scene.hidden = !current;
    if (!current) {
      scene.dataset.uiState = "idle";
      scene.setAttribute("aria-busy", "false");
      return null;
    }
    scene.dataset.state = current.state;
    scene.dataset.uiState = current.name;
    scene.dataset.fixture = current.name;
    scene.setAttribute("aria-busy", current.name === "loading" ? "true" : "false");
    text(scene.querySelector("[data-op-state-title]"), current.title);
    text(scene.querySelector("[data-op-state-detail]"), current.detail);
    text(scene.querySelector("[data-op-state-next]"), current.next);
    text(scene.querySelector("[data-op-state-reason]"), current.reason);
    text(scene.querySelector("[data-op-state-owner]"), current.owner);
    text(scene.querySelector("[data-op-state-scope]"), current.scope);
    text(scene.querySelector("[data-op-state-evidence]"), current.evidence);
    const approvalActions = scene.querySelector("[data-op-approval-actions]");
    if (approvalActions) approvalActions.hidden = current.name !== "approval";
    scene.querySelectorAll("[data-op-fixture-action]").forEach((button) => {
      button.disabled = current.name === "loading";
      button.setAttribute("aria-disabled", button.disabled ? "true" : "false");
    });
    scene.setAttribute("aria-label", `${current.name} state fixture`);
    return current;
  }

  function setButtonState(button, state, label) {
    if (!button) return;
    button.dataset.actionState = state;
    button.dataset.result = state === "success" || state === "error" ? state : "";
    button.disabled = state === "loading" || state === "disabled";
    button.setAttribute("aria-busy", state === "loading" ? "true" : "false");
    if (label) button.textContent = label;
  }

  function action(button, operation, labels = {}) {
    const idleLabel = labels.idle || button.textContent;
    setButtonState(button, "loading", labels.loading || "Working…");
    return Promise.resolve()
      .then(operation)
      .then((value) => {
        setButtonState(button, "success", labels.success || "Complete");
        window.setTimeout(() => setButtonState(button, "idle", idleLabel), 1200);
        return value;
      })
      .catch((error) => {
        setButtonState(button, "error", labels.error || "Failed — retry");
        window.setTimeout(() => setButtonState(button, "idle", idleLabel), 1800);
        throw error;
      });
  }

  function confirm(dialog, options = {}) {
    if (!(dialog instanceof HTMLDialogElement)) return Promise.resolve(false);
    const title = dialog.querySelector("[data-op-confirm-title]");
    const detail = dialog.querySelector("[data-op-confirm-detail]");
    const impact = dialog.querySelector("[data-op-confirm-impact]");
    const accept = dialog.querySelector("[data-op-confirm-accept]");
    const cancel = dialog.querySelector("[data-op-confirm-cancel]");
    text(title, options.title || "Confirm action");
    text(detail, options.detail || "Review the impact before continuing.");
    text(impact, options.impact || "Scope: current item only");
    text(accept, options.accept || "Continue");
    accept.classList.toggle("op-danger", options.danger === true);
    dialog.showModal();
    return new Promise((resolve) => {
      const finish = (value) => {
        accept.removeEventListener("click", onAccept);
        cancel.removeEventListener("click", onCancel);
        dialog.removeEventListener("cancel", onCancel);
        dialog.close();
        resolve(value);
      };
      const onAccept = () => finish(true);
      const onCancel = (event) => {
        event.preventDefault();
        finish(false);
      };
      accept.addEventListener("click", onAccept, { once: true });
      cancel.addEventListener("click", onCancel, { once: true });
      dialog.addEventListener("cancel", onCancel, { once: true });
      cancel.focus();
    });
  }

  function ageLabel(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return "not observed";
    if (seconds < 60) return `${Math.round(seconds)}s ago`;
    if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.round(seconds / 3600)}h ago`;
    return `${Math.round(seconds / 86400)}d ago`;
  }

  window.HarvisOperator = Object.freeze({
    FIXTURE_NAMES,
    FIXTURES,
    fixtureName,
    fixture,
    renderFixture,
    setButtonState,
    action,
    confirm,
    ageLabel,
    text,
  });
})();
