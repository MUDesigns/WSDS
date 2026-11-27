// WSCoopUpdater window (see src/updater.rs).
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const win = window.__TAURI__.window.getCurrentWindow();
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

let I = {};          // upd_info
let auto = null;     // WSCOOP_UPDATER_AUTOTEST: "update" | "later"
let offer = null;    // the release being offered
let busy = false;

function toast(msg) {
  const t = $("#toast"); t.textContent = msg; t.className = "toast show";
  clearTimeout(toast.t); toast.t = setTimeout(() => (t.className = "toast"), 4000);
}
function log(line) {
  const d = document.createElement("div"); d.textContent = line; $("#log").appendChild(d); $("#log").scrollTop = $("#log").scrollHeight;
}
function show(title, html, { bar = false, showLog = false, buttons = [] } = {}) {
  $("#uTitle").textContent = title;
  $("#uText").innerHTML = html;
  $("#uBar").style.display = bar ? "" : "none";
  $("#log").style.display = showLog ? "" : "none";
  const b = $("#uBtns"); b.innerHTML = "";
  for (const x of buttons) {
    const e = document.createElement("button");
    e.className = "btn" + (x.dark ? " dark" : ""); e.textContent = x.label; e.onclick = x.run; e.id = x.id || "";
    b.appendChild(e);
  }
}
const close = () => win.close();
const closeBtn = { label: "Close", dark: true, run: close };

// Test hooks: record the state; finish the run on a final state.
async function mark(label) { if (auto) await invoke("upd_mark", { label }).catch(() => {}); }
async function finish(label, code = 0) {
  if (!auto) return;
  await mark(label);
  setTimeout(() => invoke("upd_exit", { code }), 1500);
}

async function loadFonts() {
  try {
    const f = await invoke("fonts", { path: I.game });
    const add = async (family, b64, weight) => { if (!b64) return; const face = new FontFace(family, `url(data:font/otf;base64,${b64})`, { weight }); await face.load(); document.fonts.add(face); };
    await add("Griezly", f["Griezly-Regular"], "normal"); await add("Lato", f["Lato-Regular"], "400"); await add("Lato", f["Lato-Bold"], "700");
  } catch (e) { console.warn(e); }
}

// ------------------------------------------------------------------ check
async function check() {
  show("Checking for updates", `Installed version: <span class="gold">${esc(I.installed)}</span>`, { bar: true });
  let r;
  try { r = I.prefetched || (await invoke("upd_check")); I.prefetched = null; }
  catch (e) {
    show("Could not check for updates", `${esc(e)}<br><span class="small">Installed version: ${esc(I.installed)}</span>`,
      { buttons: [{ label: "Retry", run: check }, closeBtn] });
    finish("offline: " + e);
    return;
  }
  if (!r.available) {
    show("Up to date", `You have the latest version of the Co-op Mod (<span class="gold">${esc(r.installed)}</span>).`, { buttons: [{ ...closeBtn, dark: false }] });
    finish("uptodate");
    return;
  }
  offer = r;
  // "Update now" in the game (or the administrator restart) already asked for the update.
  if (I.mode === "update") { startUpdate(); return; }
  showOffer();
}

function showOffer() {
  show("Update available",
    `Version <span class="gold">${esc(offer.version)}</span> is available (you have ${esc(offer.installed)}). Witchspire has to close to update.`,
    { buttons: [{ label: "Update now", id: "bUpdate", run: startUpdate }, { label: "Later", dark: true, run: later }] });
  mark("offer");
  if (auto === "update") setTimeout(startUpdate, 600);
  if (auto === "later") setTimeout(later, 600);
}

async function later() {
  await invoke("upd_later", { version: offer.version }).catch(() => {});
  if (auto) finish("later"); else close();
}

// ------------------------------------------------------------------ update
async function startUpdate() {
  busy = true;
  $("#log").innerHTML = "";
  show("Updating to " + offer.version, "Starting...", { bar: true });
  try { await invoke("upd_update"); }
  catch (e) { busy = false; toast(String(e)); }
}

function onUpd(e) {
  const p = e.payload;
  if (p.step) { $("#uText").textContent = p.step; log(p.step); }
  if (p.line) log(p.line);
  if (p.needClose) {
    busy = false;
    show("Witchspire is still running", "Close Witchspire, then press Retry.", { buttons: [{ label: "Retry", run: startUpdate }, { label: "Later", dark: true, run: later }] });
    finish("need-close");
  }
  if (p.needAdmin) {
    busy = false;
    show("Administrator rights needed", "Windows only lets an administrator change the files in this Witchspire folder.",
      { buttons: [{ label: "Continue", run: () => invoke("upd_elevate").catch((err) => toast(String(err))) }, { label: "Later", dark: true, run: later }] });
    finish("need-admin");
  }
  if (p.error) {
    busy = false;
    log(p.error);
    show("Update failed", esc(p.error), { showLog: true, buttons: [{ label: "Retry", run: check }, closeBtn] });
    finish("error: " + p.error, 1);
  }
  if (p.done) {
    busy = false;
    show("Updated", `Updated to <span class="gold">${esc(p.version)}</span>.`,
      { buttons: [{ label: "Start Witchspire", run: async () => { await invoke("upd_start_game").catch((err) => toast(String(err))); close(); } }, closeBtn] });
    finish("done-ok " + p.version);
  }
}

// ------------------------------------------------------------------ start
async function init() {
  I = await invoke("upd_info");
  auto = I.autotest || null;
  $("#wClose").onclick = () => { if (busy) { toast("Please wait until the update has finished."); return; } close(); };
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !busy) close(); });
  await listen("upd", onUpd);
  loadFonts();
  if (I.host) {
    show("Updated by WSDS", "This PC hosts a WSDS server. WSDS keeps the Co-op Mod up to date here, so this updater does nothing.", { buttons: [{ ...closeBtn, dark: false }] });
    finish("host");
    return;
  }
  check();
}

init();
