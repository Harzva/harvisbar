#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const playwrightModule = process.env.HARVIS_PLAYWRIGHT_MODULE || "playwright";
let chromium;
try { ({ chromium } = require(playwrightModule)); }
catch (error) { throw new Error(`Playwright is required. ${error.message}`); }

function option(name, fallback = "") { const index = process.argv.indexOf(name); return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback; }
function assert(condition, message) { if (!condition) throw new Error(message); }

const baseUrl = option("--base-url").replace(/\/$/, "");
const outputDir = path.resolve(option("--output-dir", path.join(process.cwd(), "artifacts", "t319-browser")));
assert(/^http:\/\/(?:127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(baseUrl), "--base-url must be loopback with a port");
fs.mkdirSync(outputDir, { recursive: true });

const surfaces = [
  { name: "studio", route: "/studio/", viewport: { width: 1440, height: 960 }, ready: "#opHealthValue", primary: "#opNextButton", critical: [".op-command-deck", "#opNextAction", "#opOverviewLineage"] },
  { name: "panel", route: "/panel/", viewport: { width: 1280, height: 960 }, ready: "#panelHealthValue", primary: "#panelNextLink", critical: [".panel-command-deck", "#panelNextAction", "#panelLineage"] },
  { name: "mobile-390", route: "/studio/mobile/", viewport: { width: 390, height: 844 }, ready: "#mobileHealthValue", primary: "#refreshButton, #mobileNextLink", critical: ["#mobileNextAction", ".mobile-six", "#mobileLineage", ".mobile-approvals"] },
  { name: "mobile-430", route: "/studio/mobile/", viewport: { width: 430, height: 932 }, ready: "#mobileHealthValue", primary: "#refreshButton, #mobileNextLink", critical: ["#mobileNextAction", ".mobile-six", "#mobileLineage", ".mobile-approvals"] },
];
const fixtures = ["loading", "empty", "error", "blocked", "permission", "approval", "success"];
const launchOptions = { headless: true };
if (process.env.HARVIS_BROWSER_EXECUTABLE) launchOptions.executablePath = process.env.HARVIS_BROWSER_EXECUTABLE;
const browser = await chromium.launch(launchOptions);
const results = [];
const failures = [];

async function waitReady(page, surface) {
  await page.waitForSelector(surface.ready, { state: "attached", timeout: 20_000 });
  await page.waitForFunction((selector) => {
    const value = document.querySelector(selector)?.textContent?.trim().toLowerCase() || "";
    return value && !["checking", "读取中"].includes(value);
  }, surface.ready, { timeout: 20_000 });
  await page.waitForTimeout(250);
}

async function layoutAudit(page, surface) {
  const audit = await page.evaluate(({ critical }) => {
    const width = document.documentElement.clientWidth;
    const height = window.innerHeight;
    const offenders = [...document.querySelectorAll("body *")].filter((node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 1 && style.position !== "fixed" && (rect.left < -1 || rect.right > width + 1);
    }).slice(0, 12).map((node) => `${node.tagName.toLowerCase()}#${node.id}.${[...node.classList].join(".")}`);
    const folds = critical.map((selector) => {
      const node = document.querySelector(selector);
      const rect = node?.getBoundingClientRect();
      return { selector, exists: Boolean(node), top: rect?.top ?? 99999, bottom: rect?.bottom ?? 99999, visible: Boolean(rect && rect.width > 0 && rect.height > 0) };
    });
    const truncated = [...document.querySelectorAll(".op-command-deck h1, .op-command-deck h2, .op-command-deck p, .op-command-deck strong, .op-command-deck small, .mobile-shell h2, .mobile-shell h3, .mobile-shell p, .mobile-shell strong, .mobile-shell small")]
      .filter((node) => {
        const style = getComputedStyle(node); const rect = node.getBoundingClientRect();
        if (!rect.width || !rect.height || style.visibility === "hidden") return false;
        return node.scrollWidth > node.clientWidth + 1 && ["hidden", "clip"].includes(style.overflowX);
      }).slice(0, 12).map((node) => `${node.tagName.toLowerCase()}#${node.id}`);
    const visibleApprovals = [...document.querySelectorAll("#mobileApprovalList .item")].filter((node) => node.getBoundingClientRect().height > 0).length;
    const undersized = [...document.querySelectorAll("button, a.button-link, summary, input, select")].filter((node) => {
      const rect = node.getBoundingClientRect(); const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && (rect.width < 44 || rect.height < 44);
    }).slice(0, 12).map((node) => ({ node: `${node.tagName.toLowerCase()}#${node.id}`, width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height }));
    const unnamed = [...document.querySelectorAll("button, a.button-link, summary, input, select")].filter((node) => {
      const rect = node.getBoundingClientRect(); if (!rect.width || !rect.height) return false;
      const labelled = node.getAttribute("aria-label") || node.getAttribute("title") || node.textContent?.trim() || node.closest("label")?.textContent?.trim();
      return !labelled;
    }).slice(0, 12).map((node) => `${node.tagName.toLowerCase()}#${node.id}`);
    const visibleText = document.body.innerText || "";
    const placeholderLeaks = visibleText.match(/\bundefined\b|\[object Object\]/gi) || [];
    return { width, height, documentWidth: document.documentElement.scrollWidth, bodyWidth: document.body.scrollWidth, offenders, folds, truncated, visibleApprovals, undersized, unnamed, placeholderLeaks, mainCount: document.querySelectorAll("main").length };
  }, { critical: surface.critical });
  assert(audit.documentWidth <= audit.width && audit.bodyWidth <= audit.width && audit.offenders.length === 0, `${surface.name}: horizontal overflow ${JSON.stringify(audit)}`);
  assert(audit.folds.every((entry) => entry.exists && entry.visible && entry.top >= 0 && entry.bottom <= audit.height + 1), `${surface.name}: critical evidence outside first viewport ${JSON.stringify(audit.folds)}`);
  assert(audit.truncated.length === 0, `${surface.name}: clipped operator text ${audit.truncated.join(", ")}`);
  assert(audit.undersized.length === 0, `${surface.name}: interactive target below 44px ${JSON.stringify(audit.undersized)}`);
  assert(audit.unnamed.length === 0, `${surface.name}: unnamed interactive controls ${audit.unnamed.join(", ")}`);
  assert(audit.placeholderLeaks.length === 0, `${surface.name}: placeholder text leaked into visible UI ${audit.placeholderLeaks.join(", ")}`);
  assert(audit.mainCount === 1, `${surface.name}: expected exactly one main landmark`);
  if (surface.name.startsWith("mobile")) assert(audit.visibleApprovals <= 3, `${surface.name}: more than three approvals visible`);
  return audit;
}

async function keyboardAudit(page, surface) {
  await page.locator("body").click({ position: { x: 2, y: 2 } });
  const order = [];
  let primaryReached = false;
  let primaryFocusVisible = false;
  for (let index = 0; index < 32; index += 1) {
    await page.keyboard.press("Tab");
    const focused = await page.evaluate((primarySelector) => {
      const node = document.activeElement;
      const style = node ? getComputedStyle(node) : null;
      const rect = node?.getBoundingClientRect();
      return {
        selector: node ? `${node.tagName.toLowerCase()}${node.id ? `#${node.id}` : ""}${node.classList.length ? `.${[...node.classList].slice(0, 2).join(".")}` : ""}` : "none",
        text: node?.textContent?.trim().replace(/\s+/g, " ").slice(0, 50) || "",
        visible: Boolean(rect && rect.width > 0 && rect.height > 0),
        primary: Boolean(node && node.matches(primarySelector)),
        outlineStyle: style?.outlineStyle || "none",
        outlineWidth: style?.outlineWidth || "0px",
      };
    }, surface.primary);
    order.push(focused);
    if (focused.primary) {
      primaryReached = true;
      primaryFocusVisible = focused.visible && focused.outlineStyle !== "none" && focused.outlineWidth !== "0px";
      break;
    }
  }
  assert(primaryReached, `${surface.name}: Tab traversal did not reach primary action; order=${JSON.stringify(order)}`);
  assert(primaryFocusVisible, `${surface.name}: primary action lacks visible focus ring; order=${JSON.stringify(order)}`);
  return order;
}

try {
  for (const surface of surfaces) {
    const context = await browser.newContext({ viewport: surface.viewport });
    const page = await context.newPage();
    const consoleErrors = [];
    page.on("console", (message) => { if (message.type() === "error") consoleErrors.push(message.text()); });
    page.on("pageerror", (error) => consoleErrors.push(error.message));
    try {
      await page.goto(`${baseUrl}${surface.route}`, { waitUntil: "domcontentloaded", timeout: 20_000 });
      await waitReady(page, surface);
      const audit = await layoutAudit(page, surface);
      const tabOrder = await keyboardAudit(page, surface);
      assert(consoleErrors.length === 0, `${surface.name}: console errors ${consoleErrors.join(" | ")}`);
      if (surface.name === "studio") {
        const nav = await page.evaluate(() => [...document.querySelectorAll(".nav-item")].map((node) => ({ label: node.textContent.trim(), current: node.getAttribute("aria-current") })));
        assert(nav.length === 7 && nav[0].current === "page", `studio: IA/aria-current invalid ${JSON.stringify(nav)}`);
      }
      await page.screenshot({ path: path.join(outputDir, `${surface.name}.png`), fullPage: false });
      results.push({ surface: surface.name, ok: true, audit, tabOrder });
    } catch (error) { failures.push(`${surface.name}: ${error.message}`); results.push({ surface: surface.name, ok: false, error: error.message }); }
    await context.close();
  }

  for (const surface of surfaces.slice(0, 3)) {
    for (const fixture of fixtures) {
      const context = await browser.newContext({ viewport: surface.viewport });
      const page = await context.newPage();
      try {
        await page.goto(`${baseUrl}${surface.route}?fixture=${fixture}`, { waitUntil: "domcontentloaded", timeout: 20_000 });
        await page.waitForSelector(`[data-op-state-scene][data-ui-state="${fixture}"]`, { state: "visible", timeout: 20_000 });
        await page.waitForTimeout(120);
        const semantics = await page.evaluate((name) => {
          const shell = document.querySelector(".op-command-deck, .panel-command-deck, .mobile-shell");
          const scene = document.querySelector("[data-op-state-scene]");
          const text = document.body.innerText.toLowerCase();
          return { shellState: shell?.dataset.uiState, sceneState: scene?.dataset.uiState, busy: shell?.getAttribute("aria-busy"), text };
        }, fixture);
        assert(semantics.shellState === fixture && semantics.sceneState === fixture, `${surface.name}/${fixture}: unstable data-ui-state ${JSON.stringify(semantics)}`);
        if (fixture === "loading") assert(semantics.busy === "true", `${surface.name}/loading: aria-busy missing`);
        if (fixture === "loading") {
          const selectors = surface.name === "studio"
            ? ["#opNextButton", "#refreshButton", "#initButton", "#topicButton", "#savePersonaButton"]
            : surface.name === "panel"
              ? ["#refreshButton", "#scanButton", "#tickButton", "#snapshotButton", "#workbenchButton"]
              : ["#refreshButton", "#saveButton"];
          const disabled = await page.evaluate((values) => values.map((selector) => ({ selector, disabled: document.querySelector(selector)?.disabled === true })), selectors);
          assert(disabled.every((entry) => entry.disabled), `${surface.name}/loading: controls remain enabled ${JSON.stringify(disabled)}`);
        }
        if (["error", "permission"].includes(fixture)) assert(!/live e2e verified|fixture and owner-authorized live e2e evidence are complete/.test(semantics.text), `${surface.name}/${fixture}: false verified copy`);
        results.push({ surface: `${surface.name}/${fixture}`, ok: true });
      } catch (error) { failures.push(`${surface.name}/${fixture}: ${error.message}`); results.push({ surface: `${surface.name}/${fixture}`, ok: false, error: error.message }); }
      await context.close();
    }
  }

  const context = await browser.newContext({ viewport: { width: 1440, height: 960 } });
  const page = await context.newPage();
  try {
    await page.goto(`${baseUrl}/studio/?fixture=approval`, { waitUntil: "domcontentloaded", timeout: 20_000 });
    await page.waitForSelector('[data-op-state-scene][data-ui-state="approval"]', { state: "visible", timeout: 20_000 });
    await page.locator('[data-op-fixture-action="approve"]').click();
    await page.waitForSelector("#operatorConfirmDialog[open]", { timeout: 5_000 });
    assert(await page.evaluate(() => document.querySelector("#operatorConfirmDialog")?.contains(document.activeElement)), "approval dialog did not receive focus");
    await page.keyboard.press("Escape");
    assert(!(await page.locator("#operatorConfirmDialog").evaluate((node) => node.open)), "approval dialog did not close on Escape");
    await page.locator('[data-op-fixture-action="approve"]').click();
    await page.locator("#operatorConfirmDialog [data-op-confirm-cancel]").click();
    assert(!(await page.locator("#operatorConfirmDialog").evaluate((node) => node.open)), "approval dialog Go back did not close");
    results.push({ surface: "approval-dialog", ok: true });
  } catch (error) { failures.push(`approval-dialog: ${error.message}`); results.push({ surface: "approval-dialog", ok: false, error: error.message }); }
  await context.close();

  const panelContext = await browser.newContext({ viewport: { width: 1280, height: 960 } });
  const panelPage = await panelContext.newPage();
  let mutatingPostCount = 0;
  await panelPage.route("**/*", async (route) => {
    const request = route.request();
    if (request.method() === "POST" && (/\/scan-inbox$/.test(request.url()) || /\/run-tick$/.test(request.url()))) mutatingPostCount += 1;
    await route.continue();
  });
  try {
    await panelPage.goto(`${baseUrl}/panel/?fixture=success`, { waitUntil: "domcontentloaded", timeout: 20_000 });
    await panelPage.waitForSelector('[data-op-state-scene][data-ui-state="success"]', { state: "visible", timeout: 20_000 });
    await panelPage.locator(".panel-controls-detail").evaluate((node) => { node.open = true; });
    await panelPage.locator("#scanButton").click();
    await panelPage.waitForSelector("#panelConfirmDialog[open]", { timeout: 5_000 });
    await panelPage.keyboard.press("Escape");
    await panelPage.waitForTimeout(120);
    assert(mutatingPostCount === 0, `panel Scan ESC cancellation issued ${mutatingPostCount} POST request(s)`);
    await panelPage.locator("#tickButton").click();
    await panelPage.waitForSelector("#panelConfirmDialog[open]", { timeout: 5_000 });
    await panelPage.locator("#panelConfirmDialog [data-op-confirm-cancel]").click();
    await panelPage.waitForTimeout(120);
    assert(mutatingPostCount === 0, `panel Tick Go back cancellation issued ${mutatingPostCount} POST request(s)`);
    results.push({ surface: "panel-cancel-no-post", ok: true, mutatingPostCount });
  } catch (error) { failures.push(`panel-cancel-no-post: ${error.message}`); results.push({ surface: "panel-cancel-no-post", ok: false, error: error.message, mutatingPostCount }); }
  await panelContext.close();
} finally { await browser.close(); }

const report = { ok: failures.length === 0, smoke: "harvis_ui_t319_browser", checks: results.length, failures, results };
fs.writeFileSync(path.join(outputDir, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(report)}\n`);
if (failures.length) process.exitCode = 1;
