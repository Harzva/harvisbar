(() => {
  "use strict";

  const PRIVATE_LOCATION_KEYS = [
    "token",
    "bearer",
    "authorization",
    "access_token",
    "root",
    "profile_root",
  ];
  const LEGACY_PRIVATE_STORAGE_KEYS = [
    "harvis.token",
    "harvis.root",
    "harvis.profile",
    "harvis.profile.root",
    "harvis.studio.root",
    "harvis.mobile.root",
    "harvis.mobile.bearer",
    "harvis.presence.root",
  ];

  function clearLegacyPrivateStorage() {
    for (const store of [window.localStorage, window.sessionStorage]) {
      if (!store) continue;
      for (const key of LEGACY_PRIVATE_STORAGE_KEYS) store.removeItem(key);
    }
  }

  function sanitizeLocation() {
    const url = new URL(window.location.href);
    let changed = Boolean(url.hash);
    for (const key of PRIVATE_LOCATION_KEYS) {
      if (url.searchParams.has(key)) {
        url.searchParams.delete(key);
        changed = true;
      }
    }
    // Hashes are never application input. Clearing the entire fragment avoids
    // accidentally interpreting credentials embedded under an unknown key.
    url.hash = "";
    if (changed) {
      window.history.replaceState(null, "", `${url.pathname}${url.search}`);
    }
  }

  async function bootstrap() {
    const response = await fetch("/ui/bootstrap", {
      method: "GET",
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    const payload = await response.json();
    if (!response.ok || !payload.ok || !payload.data) {
      throw new Error(payload.error?.message || "Runtime bootstrap unavailable.");
    }
    const data = payload.data;
    if (data.network_scope !== "loopback" || data.token_included !== false) {
      throw new Error("Runtime bootstrap safety contract rejected.");
    }
    if (typeof data.workspace_root !== "string" || !data.workspace_root.trim()) {
      throw new Error("Runtime bootstrap did not provide a workspace.");
    }
    return Object.freeze({
      workspaceRoot: data.workspace_root,
      workspaceLabel: String(data.workspace_label || "workspace"),
      authRequired: data.auth_required === true,
    });
  }

  function applyWorkspaceLabel(input, label) {
    if (!input) return;
    input.value = label || "workspace";
    input.readOnly = true;
    input.setAttribute("aria-readonly", "true");
    input.title = "Workspace selected by the local H.A.R.V.I.S. runtime";
  }

  function bearerHeaders(input) {
    const value = input && typeof input.value === "string" ? input.value.trim() : "";
    return value ? { Authorization: `Bearer ${value}` } : {};
  }

  function scrub(value, workspaceRoot = "", key = "") {
    if (/token|secret|cookie|authorization|password|credential|api[_-]?key/i.test(key)) {
      return "[redacted]";
    }
    if (Array.isArray(value)) return value.map((item) => scrub(item, workspaceRoot));
    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map(([childKey, childValue]) => [childKey, scrub(childValue, workspaceRoot, childKey)]),
      );
    }
    if (typeof value === "string") {
      let safe = workspaceRoot ? value.replaceAll(workspaceRoot, "$WORKSPACE") : value;
      // Redact local filesystem paths even when they are embedded in a web
      // URL's path or query. Ordinary scheme/host/path text is unchanged.
      safe = safe
        .replace(/\/(?:Users|Volumes)\/[^\s"'<>\])}]+/g, "$LOCAL_PATH")
        .replace(/\/home\/[^/\s]+\/[^\s"'<>\])}]+/g, "$LOCAL_PATH")
        .replace(/[A-Za-z]:\\Users\\[^\s"'<>\])}]+/g, "$LOCAL_PATH");
      return safe;
    }
    return value;
  }

  sanitizeLocation();
  clearLegacyPrivateStorage();
  window.HarvisRuntime = Object.freeze({
    applyWorkspaceLabel,
    bearerHeaders,
    bootstrap,
    sanitizeLocation,
    scrub,
  });
})();
