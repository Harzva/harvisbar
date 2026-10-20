#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const playwrightModule = process.env.HARVIS_PLAYWRIGHT_MODULE || "playwright";
let chromium;
try {
  ({ chromium } = require(playwrightModule));
} catch (error) {
  throw new Error(`Playwright is required. Install it or set HARVIS_PLAYWRIGHT_MODULE. ${error.message}`);
}

const SURFACES = [
  { name: "studio", route: "/studio/", root: "#rootInput", token: "#tokenInput" },
  { name: "mobile", route: "/studio/mobile/", root: "#rootInput", token: "#tokenInput", disclosure: ".mobile-session-detail" },
  { name: "panel", route: "/panel/", root: "#rootInput", token: "#tokenInput", disclosure: ".panel-controls-detail" },
  { name: "presence", route: "/presence/", root: "#presenceRootInput", token: "#presenceTokenInput" },
  { name: "roundtable", route: "/studio/roundtable/", root: "#rootInput", token: "#tokenInput" },
];
const WIDTHS = [390, 430, 768, 1440];
const PRIVATE_QUERY_KEYS = ["token", "bearer", "authorization", "access_token", "root", "profile_root"];
const LEGACY_STORAGE_KEYS = [
  "harvis.token",
  "harvis.root",
  "harvis.profile.root",
  "harvis.mobile.bearer",
];

function option(name, fallback = "") {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

const baseUrl = option("--base-url").replace(/\/$/, "");
const outputDir = path.resolve(option("--output-dir", path.join(process.cwd(), "artifacts", "t318-browser")));
const surfaceFilter = option("--surface");
const widthFilter = Number.parseInt(option("--width"), 10);
const surfaces = surfaceFilter ? SURFACES.filter((surface) => surface.name === surfaceFilter) : SURFACES;
const widths = Number.isFinite(widthFilter) ? WIDTHS.filter((width) => width === widthFilter) : WIDTHS;
requireCondition(/^http:\/\/(?:127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(baseUrl), "--base-url must be a loopback HTTP origin with an explicit port");
requireCondition(surfaces.length > 0, "--surface must name a known UI surface");
requireCondition(widths.length > 0, "--width must be one of the required verification widths");
fs.mkdirSync(outputDir, { recursive: true });

const launchOptions = { headless: true };
if (process.env.HARVIS_BROWSER_EXECUTABLE) launchOptions.executablePath = process.env.HARVIS_BROWSER_EXECUTABLE;
const browser = await chromium.launch(launchOptions);
const results = [];
const failures = [];

try {
  for (const surface of surfaces) {
    for (const width of widths) {
      const context = await browser.newContext({ viewport: { width, height: 960 } });
      await context.addInitScript(({ keys }) => {
        for (const key of keys) {
          window.localStorage.setItem(key, "legacy-local-sentinel");
          window.sessionStorage.setItem(key, "legacy-session-sentinel");
        }
      }, { keys: LEGACY_STORAGE_KEYS });

      const page = await context.newPage();
      const consoleErrors = [];
      page.on("console", (message) => {
        if (message.type() === "error") consoleErrors.push(message.text());
      });
      page.on("pageerror", (error) => consoleErrors.push(error.message));

      const target = `${baseUrl}${surface.route}?view=dashboard&token=url-sentinel&bearer=url-sentinel&root=%2FUsers%2Ffixture%2Fprivate#token=fragment-sentinel`;
      try {
        await page.goto(target, { waitUntil: "domcontentloaded", timeout: 20_000 });
        await page.waitForFunction(
          (selector) => {
            const input = document.querySelector(selector);
            return input instanceof HTMLInputElement && input.value.length > 0;
          },
          surface.root,
          { timeout: 20_000 },
        );
        await page.waitForFunction(
          (surfaceName) => {
            const text = (selector) => document.querySelector(selector)?.textContent?.trim().toLowerCase() || "";
            if (surfaceName === "studio") return text("#cockpitOnline") === "online";
            if (surfaceName === "mobile") return ["connected", "partial"].includes(text("#connectionState"));
            if (surfaceName === "panel") {
              const shell = document.querySelector(".shell");
              const settled = ["idle", "thinking", "acting", "verified", "blocked"].includes(text("#stateText"));
              return shell?.dataset.connected === "true" && settled && text("#runtimeStamp") !== "not synced" && text("#outputLog") !== "no output.";
            }
            if (surfaceName === "presence") {
              const shell = document.querySelector(".presence-shell");
              const settled = ["idle", "thinking", "acting", "verified", "blocked"].includes(text("#presenceStateText"));
              return shell?.dataset.connected === "true" && settled;
            }
            if (surfaceName === "roundtable") return /^(runtime connected|loaded \d+ provider routes)/.test(text("#composerStatus"));
            return false;
          },
          surface.name,
          { timeout: 20_000 },
        );
        await page.waitForTimeout(300);

        if (surface.disclosure) {
          await page.locator(surface.disclosure).evaluate((element) => { element.open = true; });
        }

        const finalUrl = new URL(page.url());
        requireCondition(finalUrl.hash === "", `${surface.name}/${width}: fragment was not removed`);
        for (const key of PRIVATE_QUERY_KEYS) {
          requireCondition(!finalUrl.searchParams.has(key), `${surface.name}/${width}: private query key remains: ${key}`);
        }
        requireCondition(finalUrl.searchParams.get("view") === "dashboard", `${surface.name}/${width}: benign view query was not preserved`);

        const tokenValue = await page.locator(surface.token).inputValue();
        const workspaceLabel = await page.locator(surface.root).inputValue();
        requireCondition(tokenValue === "", `${surface.name}/${width}: credential input absorbed a value`);
        requireCondition(workspaceLabel.length > 0 && !/[\\/]/.test(workspaceLabel), `${surface.name}/${width}: workspace label exposes a path`);

        const remainingStorage = await page.evaluate((keys) => {
          const found = [];
          for (const store of [window.localStorage, window.sessionStorage]) {
            for (const key of keys) {
              if (store.getItem(key) !== null) found.push(key);
            }
          }
          return found;
        }, LEGACY_STORAGE_KEYS);
        requireCondition(remainingStorage.length === 0, `${surface.name}/${width}: legacy private storage keys remain`);

        const layout = await page.evaluate(() => {
          const viewportWidth = document.documentElement.clientWidth;
          const offenders = [...document.querySelectorAll("body *")]
            .map((element) => {
              const rect = element.getBoundingClientRect();
              const style = getComputedStyle(element);
              const parentRect = element.parentElement?.getBoundingClientRect();
              const grandparentRect = element.parentElement?.parentElement?.getBoundingClientRect();
              return {
                element: `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}${element.classList.length ? `.${[...element.classList].slice(0, 3).join(".")}` : ""}`,
                parent: element.parentElement ? `${element.parentElement.tagName.toLowerCase()}${element.parentElement.id ? `#${element.parentElement.id}` : ""}${element.parentElement.classList.length ? `.${[...element.parentElement.classList].slice(0, 3).join(".")}` : ""}` : "",
                grandparent: element.parentElement?.parentElement ? `${element.parentElement.parentElement.tagName.toLowerCase()}${element.parentElement.parentElement.id ? `#${element.parentElement.parentElement.id}` : ""}${element.parentElement.parentElement.classList.length ? `.${[...element.parentElement.parentElement.classList].slice(0, 3).join(".")}` : ""}` : "",
                left: Math.round(rect.left),
                right: Math.round(rect.right),
                width: Math.round(rect.width),
                whiteSpace: style.whiteSpace,
                minWidth: style.minWidth,
                parentWidth: parentRect ? Math.round(parentRect.width) : 0,
                grandparentWidth: grandparentRect ? Math.round(grandparentRect.width) : 0,
              };
            })
            .filter((item) => item.width > 1 && (item.left < -1 || item.right > viewportWidth + 1))
            .slice(0, 20);
          return {
            viewportWidth,
            documentWidth: document.documentElement.scrollWidth,
            bodyWidth: document.body.scrollWidth,
            offenders,
          };
        });
        requireCondition(
          layout.documentWidth <= layout.viewportWidth && layout.bodyWidth <= layout.viewportWidth && layout.offenders.length === 0,
          `${surface.name}/${width}: horizontal overflow ${JSON.stringify(layout)}`,
        );

        const undersizedTargets = await page.evaluate(() => [...document.querySelectorAll("button, [role='button'], .button-link")]
          .filter((element) => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
          })
          .map((element) => {
            const rect = element.getBoundingClientRect();
            return {
              element: `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}${element.classList.length ? `.${[...element.classList].slice(0, 3).join(".")}` : ""}`,
              width: Math.round(rect.width),
              height: Math.round(rect.height),
            };
          })
          .filter((item) => item.width < 44 || item.height < 44));
        requireCondition(undersizedTargets.length === 0, `${surface.name}/${width}: interactive targets below 44x44: ${JSON.stringify(undersizedTargets.slice(0, 20))}`);

        await page.locator(surface.token).focus();
        const focus = await page.locator(surface.token).evaluate((element) => {
          const style = getComputedStyle(element);
          return {
            focused: document.activeElement === element,
            outlineStyle: style.outlineStyle,
            outlineWidth: Number.parseFloat(style.outlineWidth || "0"),
          };
        });
        requireCondition(focus.focused, `${surface.name}/${width}: token field is not keyboard focusable`);
        requireCondition(focus.outlineStyle !== "none" && focus.outlineWidth >= 2, `${surface.name}/${width}: focus indicator is not visibly styled`);
        requireCondition(consoleErrors.length === 0, `${surface.name}/${width}: console errors: ${consoleErrors.join(" | ")}`);

        const screenshot = path.join(outputDir, `${surface.name}-${width}.png`);
        await page.screenshot({ path: screenshot, fullPage: true });
        results.push({ surface: surface.name, width, ok: true, screenshot: path.basename(screenshot) });
      } catch (error) {
        const screenshot = path.join(outputDir, `${surface.name}-${width}-failure.png`);
        await page.screenshot({ path: screenshot, fullPage: true }).catch(() => {});
        failures.push({ surface: surface.name, width, error: error.message, screenshot: path.basename(screenshot) });
        results.push({ surface: surface.name, width, ok: false, screenshot: path.basename(screenshot) });
      } finally {
        await context.close();
      }
    }
  }
} finally {
  await browser.close();
}

const summary = {
  ok: failures.length === 0,
  smoke: "harvis_ui_t318_browser",
  surfaces: surfaces.length,
  widths,
  checks: results.length,
  screenshots: results.map((item) => item.screenshot),
  failures,
};
console.log(JSON.stringify(summary));
process.exitCode = summary.ok ? 0 : 1;
