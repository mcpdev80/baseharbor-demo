async function json(url, options = {}) {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => ({error: "invalid response"}));
  if (!response.ok) {
    throw new Error(body.error || response.statusText);
  }
  return body;
}

const historyEntries = [];
let capabilityState = {};

function formatTime(date = new Date()) {
  return date.toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", second: "2-digit"});
}

function addHistory(action, state, detail) {
  historyEntries.push({
    time: formatTime(),
    action,
    state,
    detail: typeof detail === "string" ? detail : JSON.stringify(detail, null, 2),
  });
  renderHistory();
}

function renderHistory() {
  const root = document.getElementById("history");
  if (!root) return;
  if (historyEntries.length === 0) {
    root.innerHTML = '<div class="history-empty">Run a capability action to see persistent results here.</div>';
    return;
  }
  root.innerHTML = historyEntries.slice().reverse().map((entry) => {
    const state = entry.state.toLowerCase();
    return `
      <div class="history-entry">
        <div class="history-head">
          <span class="history-time">${entry.time}</span>
          <strong>${escapeHTML(entry.action)}</strong>
          <span class="history-state ${state}">${escapeHTML(entry.state)}</span>
        </div>
        <pre>${escapeHTML(entry.detail)}</pre>
      </div>`;
  }).join("");
}

function clearHistory() {
  historyEntries.length = 0;
  renderHistory();
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function setCard(name, capability) {
  const card = document.querySelector('[data-cap="' + name + '"]');
  if (!card) return;

  const status = card.querySelector(".status");
  const statusText = status.querySelector("span:last-child");
  const detail = card.querySelector(".cap-detail");
  const action = card.querySelector("[data-action]");

  status.className = "status " + (capability.ready ? "ready" : (capability.optional ? "optional" : "degraded"));
  statusText.textContent = capability.ready ? "ready" : (capability.optional ? "not configured" : "degraded");
  if (detail) detail.textContent = capability.detail || "";

  if (action) {
    action.disabled = !capability.ready;
    action.title = capability.ready ? "" : (capability.detail || "Capability unavailable");
  }
}

function setDeveloperLinks(links = {}) {
  const definitions = {
    swagger: links.swagger,
    metrics: links.metrics,
    health: links.health,
  };
  Object.entries(definitions).forEach(([name, href]) => {
    const links = document.querySelectorAll('[data-link="' + name + '"]');
    links.forEach((link) => {
      if (href) {
        link.href = href;
        link.classList.remove("disabled");
        link.removeAttribute("aria-disabled");
      } else {
        link.removeAttribute("href");
        link.classList.add("disabled");
        link.setAttribute("aria-disabled", "true");
      }
    });
  });
}

async function refresh() {
  try {
    const status = await json("/api/status");
    capabilityState = status.capabilities || {};
    Object.entries(capabilityState).forEach(([name, capability]) => setCard(name, capability));

    const required = Object.values(capabilityState).filter((capability) => !capability.optional);
    const allReady = required.length > 0 && required.every((capability) => capability.ready);
    document.getElementById("overall").textContent = allReady ? "READY" : "DEGRADED";
    setDeveloperLinks(status.links || {});
  } catch (error) {
    document.getElementById("overall").textContent = "UNAVAILABLE";
  }
}

async function runAction(action, endpoint, label) {
  const button = document.querySelector('[data-action="' + action + '"]');
  if (button) button.disabled = true;

  addHistory(label, "INFO", "running...");
  try {
    const result = await json(endpoint, {method: "POST"});
    addHistory(label, "PASS", result);
  } catch (error) {
    addHistory(label, "FAIL", error.message);
  } finally {
    await refresh();
    if (button && capabilityState[action]?.ready) button.disabled = false;
  }
}

async function scenario() {
  const steps = [
    ["sql", "/api/sql", "SQL"],
    ["cache", "/api/cache", "Cache"],
    ["object_storage", "/api/object", "Object Storage"],
    ["secrets", "/api/secret", "Secrets"],
    ["metrics", "/api/metrics/verify", "Metrics"],
    ["telemetry", "/api/trace", "Telemetry / Traces"],
    ["runtime_resource", "/api/runtime-resource", "Runtime Resource"],
    ["companion", "/api/companion", "Cross-App Connectivity"],
  ];

  addHistory("Demo Scenario", "INFO", "running...");
  let failed = 0;
  let skipped = 0;
  for (const [capability, endpoint, label] of steps) {
    if (!capabilityState[capability]?.ready) {
      addHistory(label, "SKIP", capabilityState[capability]?.detail || "not configured");
      skipped++;
      continue;
    }
    try {
      const result = await json(endpoint, {method: "POST"});
      addHistory(label, "PASS", result);
    } catch (error) {
      addHistory(label, "FAIL", error.message);
      failed++;
    }
  }
  addHistory("Demo Scenario", failed === 0 ? "PASS" : "FAIL", {
    failed,
    skipped,
    completed: steps.length - skipped,
  });
  await refresh();
}

renderHistory();
refresh();
setInterval(refresh, 10000);
