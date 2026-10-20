#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import path from "node:path";

const pluginRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(path.join(pluginRoot, "ui/runtime.js"), "utf8");
let replaced = "";
const window = {
  location: {
    href: "http://127.0.0.1:8765/studio/?token=fake&root=%2FUsers%2Fexample%2Fprivate&view=review#bearer=also-fake",
  },
  history: {
    replaceState(_state, _title, value) {
      replaced = value;
    },
  },
};
const fetch = async () => ({
  ok: true,
  async json() {
    return {
      ok: true,
      data: {
        workspace_root: "/Users/example/private",
        workspace_label: "private",
        auth_required: true,
        token_included: false,
        network_scope: "loopback",
      },
    };
  },
});
vm.runInNewContext(source, { URL, window, fetch, console });

assert.equal(replaced, "/studio/?view=review");
const bootstrap = await window.HarvisRuntime.bootstrap();
assert.equal(bootstrap.workspaceLabel, "private");
assert.equal(bootstrap.authRequired, true);
assert.equal(Object.prototype.hasOwnProperty.call(bootstrap, "token"), false);

const fixture = {
  workspace: "/Users/example/private/.harvis/status.json",
  volume: "/Volumes/PrivateDisk/project/log.json",
  linux: "/home/example/private/report.json",
  windows: "C:\\Users\\example\\private\\report.json",
  url: "https://example.test/public/path?view=review",
  url_with_local_query: "https://example.test/report?root=/Users/example/private",
  url_with_volume_query: "https://example.test/report?root=/Volumes/PrivateDisk/project",
  access_token: "must-not-render",
};
const scrubbed = window.HarvisRuntime.scrub(fixture, "/Users/example/private");
assert.equal(scrubbed.workspace, "$WORKSPACE/.harvis/status.json");
assert.equal(scrubbed.volume, "$LOCAL_PATH");
assert.equal(scrubbed.linux, "$LOCAL_PATH");
assert.equal(scrubbed.windows, "$LOCAL_PATH");
assert.equal(scrubbed.url, fixture.url);
assert.equal(scrubbed.url_with_local_query, "https://example.test/report?root=$WORKSPACE");
assert.equal(scrubbed.url_with_volume_query, "https://example.test/report?root=$LOCAL_PATH");
assert.equal(scrubbed.access_token, "[redacted]");

process.stdout.write(JSON.stringify({ ok: true, smoke: "harvis_ui_runtime_unit", checks: 13 }) + "\n");
