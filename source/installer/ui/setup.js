const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const win = window.__TAURI__.window.getCurrentWindow();
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

let flavor = "client";
let auto = null; // automated test run (WSCOOP_SETUP_AUTOTEST)
const st = {
  gamePath: "", found: false, installed: false, running: false,
  steamUser: "", steamcmd: "",
  worldName: "Witchspire Dedicated Server", gamePort: 7777, maxPlayers: 8, joinPassword: "",
  remotePassword: "", remotePassword2: "", remotePort: 7780, firewall: true, service: true,
  result: null, uninstalled: false,
};
let steps = [];
let cur = 0;
let busy = false;

function toast(msg, bad) {
  const t = $("#toast"); t.textContent = msg; t.className = "toast show" + (bad ? " bad" : "");
  clearTimeout(toast.t); toast.t = setTimeout(() => (t.className = "toast"), 4500);
}
function log(line, cls = "") {
  const l = $("#log"); if (!l) return;
  const d = document.createElement("div"); if (cls) d.className = cls; d.textContent = line; l.appendChild(d); l.scrollTop = l.scrollHeight;
  if (auto) console.log(line);
}

async function loadFonts(path) {
  try {
    const f = await invoke("fonts", { path });
    const add = async (family, b64, weight) => { if (!b64) return; const face = new FontFace(family, `url(data:font/otf;base64,${b64})`, { weight }); await face.load(); document.fonts.add(face); };
    await add("Griezly", f["Griezly-Regular"], "normal"); await add("Lato", f["Lato-Regular"], "400"); await add("Lato", f["Lato-Bold"], "700");
  } catch (e) { console.warn(e); }
}

// ------------------------------------------------------------------ pages
const PAGES = {
  welcome: {
    title: "Welcome",
    render: () => flavor === "server" ? `
      <div class="hero"><img src="logo-server.png" alt=""><div><h1>WSDS Setup</h1><div class="muted">Witchspire Dedicated Server with the Co-op Overhaul</div></div></div>
      <p>This sets up a Witchspire server that runs in the background, starts with Windows and saves the world automatically. Friends join from the game's main menu with <span class="gold">Join Dedicated Server</span>.</p>
      <div class="feat"><div>Downloads Witchspire with SteamCMD</div><div>Background service, auto-restart</div><div>Co-op Overhaul mod included</div><div>Control it from any PC with WSDS</div><div>Opens the firewall ports</div><div>Autosaves and saves on shutdown</div></div>
      <p class="muted small">You need a Steam account that owns Witchspire (once, to download the game). Your Steam password is only passed to SteamCMD and is never stored by this setup.</p>`
    : `
      <div class="hero"><img src="logo-client.png" alt=""><div><h1>Witchspire Co-op Overhaul</h1><div class="muted">Setup for players</div></div></div>
      <p>Installs the Co-op Overhaul into your copy of Witchspire so you can join dedicated servers and play co-op with:</p>
      <div class="feat"><div>Join Dedicated Server in the main menu</div><div>Your own loot from chests and kills</div><div>Shared quests and milestones</div><div>Catch-up XP for newer witches</div><div>Shared sanctuary building</div><div>Coven bonuses for playing together</div></div>
      <p class="muted small">Original game files are backed up and can be restored by running this setup again and choosing Uninstall.</p>`,
  },
  folder: {
    title: () => flavor === "server" ? "Location" : "Game Folder",
    render: () => `
      <h2>${flavor === "server" ? "Where should the server live?" : "Where is Witchspire installed?"}</h2>
      <p class="muted">${flavor === "server" ? "Pick an existing Witchspire folder, or an empty folder - Witchspire will be downloaded there with SteamCMD." : "Setup found your Steam copy automatically. Change it if you keep Witchspire somewhere else."}</p>
      <label class="field"><span class="lbl">Folder</span><div class="path"><input type="text" id="fPath" value="${esc(st.gamePath)}" spellcheck="false"></div></label>
      <div class="status" id="fStatus"></div>
      <div id="fExtra"></div>`,
    mount: () => { $("#fPath").oninput = () => { st.gamePath = $("#fPath").value.trim(); checkFolder(); }; checkFolder(); },
    validate: () => {
      if (!st.gamePath) return "Enter a folder.";
      if (st.running) return "Witchspire is running - close it first.";
      if (flavor === "client" && !st.found) return "Witchspire was not found in that folder.";
      return null;
    },
  },
  steam: {
    title: "Download",
    skip: () => st.found,
    render: () => `
      <h2>Download Witchspire</h2>
      <p class="muted">Sign in with a Steam account that owns Witchspire. The password is handed straight to SteamCMD (Valve's command-line Steam) and is not saved by this setup. SteamCMD remembers the sign-in on this machine so WSDS can update the game later.</p>
      <div class="cols"><label class="field"><span class="lbl">Steam account name</span><input type="text" id="sUser" value="${esc(st.steamUser)}" autocomplete="off" spellcheck="false"></label>
      <label class="field"><span class="lbl">Steam password</span><input type="password" id="sPass"></label></div>
      <div class="row gap" id="sCodeRow" style="display:none"><label class="field" style="flex:1"><span class="lbl">Steam Guard code</span><input type="text" id="sCode" autocomplete="off" spellcheck="false"><span class="help">From the email Steam just sent, or the code in your Steam mobile app.</span></label><button class="btn small" id="sCodeBtn">Continue</button></div>
      <div class="notice" id="sMobile" style="display:none">If you use the Steam mobile app, approve the sign-in there now. Setup continues by itself.</div>
      <div class="row gap"><button class="btn" id="sGo">Sign in and download</button><span class="muted" id="sPct"></span></div>
      <div class="bar" id="sBar"><div></div></div>
      <div class="log" id="log"></div>`,
    mount: () => {
      $("#sGo").onclick = () => startSteam("");
      $("#sCodeBtn").onclick = () => { const c = $("#sCode").value.trim(); if (c) startSteam(c); };
      $("#sCode").onkeydown = (e) => { if (e.key === "Enter") $("#sCodeBtn").click(); };
    },
    validate: () => st.found ? null : "Download Witchspire first (or go back and pick a folder that already has it).",
  },
  server: {
    title: "Server",
    render: () => `
      <h2>Server settings</h2>
      <div class="cols">
        <label class="field"><span class="lbl">Server name</span><input type="text" id="vName" value="${esc(st.worldName)}"></label>
        <label class="field"><span class="lbl">Max players</span><input type="number" id="vMax" min="1" max="32" value="${st.maxPlayers}"></label>
        <label class="field"><span class="lbl">Game port (UDP)</span><input type="number" id="vPort" value="${st.gamePort}"></label>
        <label class="field"><span class="lbl">Join password</span><input type="text" id="vJoin" value="${esc(st.joinPassword)}" placeholder="Empty = anyone with the address"></label>
      </div>
      <h3>Remote control</h3>
      <p class="muted small">Lets WSDS on your own PC manage this server. Leave empty to only manage it on this machine.</p>
      <div class="cols">
        <label class="field"><span class="lbl">Remote control password</span><input type="password" id="vRp" value="${esc(st.remotePassword)}"></label>
        <label class="field"><span class="lbl">Confirm password</span><input type="password" id="vRp2" value="${esc(st.remotePassword2)}"></label>
        <label class="field"><span class="lbl">Remote control port (TCP)</span><input type="number" id="vRport" value="${st.remotePort}"></label>
      </div>
      <label class="toggle"><input type="checkbox" id="vFw" ${st.firewall ? "checked" : ""}><span class="knob"></span><span><span class="lbl">Open Windows Firewall ports</span><span class="help">Also open the same ports in your hosting provider's firewall, if it has one.</span></span></label>
      <label class="toggle"><input type="checkbox" id="vSvc" ${st.service ? "checked" : ""}><span class="knob"></span><span><span class="lbl">Run in the background and start with Windows</span><span class="help">Recommended for servers. The WSDS window attaches to it.</span></span></label>`,
    collect: () => {
      st.worldName = $("#vName").value.trim() || "Witchspire Dedicated Server";
      st.maxPlayers = Number($("#vMax").value) || 8; st.gamePort = Number($("#vPort").value) || 7777;
      st.joinPassword = $("#vJoin").value; st.remotePassword = $("#vRp").value; st.remotePassword2 = $("#vRp2").value;
      st.remotePort = Number($("#vRport").value) || 7780; st.firewall = $("#vFw").checked; st.service = $("#vSvc").checked;
    },
    validate: () => {
      if (st.remotePassword !== st.remotePassword2) return "The remote control passwords do not match.";
      if (st.remotePassword && st.remotePassword.length < 4) return "Use a remote control password of at least 4 characters.";
      if (st.gamePort === st.remotePort) return "The game port and remote control port must differ.";
      return null;
    },
  },
  install: {
    title: () => st.uninstalling ? "Uninstall" : "Install",
    render: () => `<h2 id="iTitle">${st.uninstalling ? "Uninstalling..." : "Installing..."}</h2><div class="muted" id="iStep">Starting</div><div class="bar busy" id="iBar"><div></div></div><div class="log" id="log" style="height:300px"></div>`,
    mount: () => runInstall(),
  },
  finish: {
    title: "Finish",
    render: () => {
      if (st.uninstalled) return `<h1>Uninstalled</h1><p>The original game files were restored${flavor === "server" ? " and the background service, firewall rules and shortcuts were removed. Server worlds were kept in WitchspireCoopMod\\ServerData" : ""}.</p>`;
      const r = st.result || {};
      if (flavor === "client") return `<h1>Ready to play</h1><p>The Co-op Overhaul is installed. Start Witchspire and choose <span class="gold">Join Dedicated Server</span> in the main menu.</p>
        <p class="muted small">Steam may revert the mod when the game updates. If that happens, run this setup again.</p>
        <div class="row gap"><button class="btn" id="fPlay">Launch Witchspire</button></div>`;
      const addr = r.publicIp || "this server's public address";
      return `<h1>Your server is ready</h1>
        <div class="summary">
          <span class="k">Players join</span><span class="v">${esc(addr)} &nbsp;port ${r.gamePort}</span>
          ${st.remotePassword ? `<span class="k">Remote control</span><span class="v">${esc(addr)} &nbsp;port ${r.remotePort} (WSDS &rarr; Add remote server)</span>` : ""}
          <span class="k">Background service</span><span class="v">${st.service ? "running, starts with Windows" : "not installed"}</span>
          <span class="k">Files</span><span class="v">${esc(r.modRoot)}</span>
        </div>
        <div class="notice">If your host has its own firewall (in its control panel), allow <b>UDP ${r.gamePort}</b>${st.remotePassword ? ` and <b>TCP ${r.remotePort}</b>` : ""} there as well.</div>
        <div class="row gap"><button class="btn" id="fWsds">Open WSDS</button><button class="btn dark" id="fFolder">Open folder</button></div>`;
    },
    mount: () => {
      if ($("#fPlay")) $("#fPlay").onclick = () => invoke("launch", { path: "explorer.exe", args: ["steam://rungameid/2679100"] });
      if ($("#fWsds")) $("#fWsds").onclick = () => invoke("launch", { path: st.result.wsds, args: [] });
      if ($("#fFolder")) $("#fFolder").onclick = () => invoke("open_path", { path: st.result.modRoot });
    },
  },
};

// ------------------------------------------------------------------ navigation
function title(p) { return typeof p.title === "function" ? p.title() : p.title; }
function visibleSteps() { return steps.filter((k) => !(PAGES[k].skip && PAGES[k].skip())); }
function render() {
  const vis = visibleSteps();
  const key = steps[cur];
  $("#steps").innerHTML = vis.map((k) => `<div class="st ${k === key ? "cur" : vis.indexOf(k) < vis.indexOf(key) ? "done" : ""}">${esc(title(PAGES[k]))}</div>`).join("");
  $("#page").innerHTML = PAGES[key].render();
  const last = key === "finish";
  $("#bBack").style.visibility = cur === 0 || key === "install" || last ? "hidden" : "visible";
  $("#bNext").textContent = last ? "Close" : steps[cur + 1] === "install" ? "Install" : "Next";
  $("#bNext").disabled = key === "install";
  $("#hint").textContent = "";
  PAGES[key].mount?.();
}
function go(delta) {
  let i = cur + delta;
  while (i > 0 && i < steps.length - 1 && PAGES[steps[i]].skip?.()) i += delta;
  cur = Math.max(0, Math.min(steps.length - 1, i));
  render();
}
async function next() {
  const key = steps[cur];
  if (key === "finish") return win.close();
  PAGES[key].collect?.();
  const err = PAGES[key].validate?.();
  if (err) { toast(err, true); return; }
  go(1);
}

// ------------------------------------------------------------------ folder checks
let checkSeq = 0;
async function checkFolder() {
  const seq = ++checkSeq;
  const r = await invoke("check_game", { path: st.gamePath || "" });
  if (seq !== checkSeq) return;
  Object.assign(st, { found: r.found, installed: r.installed, running: r.running });
  let html, extra = "";
  if (r.running) html = `<span class="gem off"></span><span>Witchspire is running. Close the game (and any server) first.</span>`;
  else if (r.found) html = `<span class="gem on"></span><span>Witchspire found${r.installed ? " - the Co-op Overhaul is already installed (Next repairs or updates it)" : ""}.</span>`;
  else if (flavor === "server") html = `<span class="gem wait"></span><span>No Witchspire here yet - it will be downloaded with SteamCMD in the next step.</span>`;
  else html = `<span class="gem off"></span><span>Witchspire was not found in this folder.</span>`;
  if (r.installed && !r.running) extra = `<div class="divider"><span></span></div><p class="muted small">Want to remove it instead?</p><button class="btn small danger" id="fUninstall">Uninstall</button>`;
  $("#fStatus").innerHTML = html;
  $("#fExtra").innerHTML = extra;
  if ($("#fUninstall")) $("#fUninstall").onclick = () => { st.uninstalling = true; cur = steps.indexOf("install"); render(); };
  if (r.found) loadFonts(st.gamePath);
}

// ------------------------------------------------------------------ SteamCMD
let steamPass = "";
async function startSteam(code) {
  st.steamUser = $("#sUser").value.trim();
  if ($("#sPass").value) steamPass = $("#sPass").value;
  if (!st.steamUser || !steamPass) { toast("Enter your Steam account name and password.", true); return; }
  $("#sGo").disabled = true; $("#bBack").disabled = true; $("#sCodeRow").style.display = "none";
  $("#sBar").classList.add("busy");
  if (code) log("Retrying with the Steam Guard code...", "hd");
  await invoke("steamcmd_start", { dir: st.gamePath, user: st.steamUser, password: steamPass, guard: code || null });
}
function onSteam(e) {
  const p = e.payload;
  const idle = () => { $("#sGo").disabled = false; $("#bBack").disabled = false; $("#sBar").classList.remove("busy"); };
  if (p.event === "line") log(p.line);
  if (p.event === "confirm_mobile") $("#sMobile").style.display = "";
  if (p.event === "logged_in") { $("#sMobile").style.display = "none"; log("Signed in. Downloading Witchspire (about 7 GB)...", "ok"); }
  if (p.event === "need_code") {
    idle(); $("#sGo").disabled = true; $("#sCodeRow").style.display = ""; $("#sCode").value = ""; $("#sCode").focus();
    log(p.retry ? "Steam did not accept that code. Enter the newest code." : "Steam needs a Steam Guard code (check your email or the Steam mobile app).", "hd");
  }
  if (p.event === "percent") { const v = parseFloat(p.value); $("#sBar").classList.remove("busy"); $("#sBar").firstElementChild.style.width = `${v}%`; $("#sPct").textContent = `${v.toFixed(1)}%`; }
  if (p.event === "error") { log(p.message, "bad"); toast(p.message, true); idle(); }
  if (p.event === "done") {
    st.found = true; st.steamcmd = p.steamcmd; steamPass = ""; $("#sPass").value = "";
    $("#sBar").classList.remove("busy"); $("#sBar").firstElementChild.style.width = "100%"; $("#sPct").textContent = "100%";
    log("Witchspire downloaded.", "ok"); $("#bBack").disabled = false; loadFonts(st.gamePath);
    setTimeout(() => steps[cur] === "steam" && go(1), 800);
  }
}

// ------------------------------------------------------------------ install / uninstall
async function runInstall() {
  busy = true;
  if (st.uninstalling) { await invoke("uninstall", { path: st.gamePath }); return; }
  await invoke("install", { opts: {
    gamePath: st.gamePath, worldName: st.worldName, gamePort: st.gamePort, maxPlayers: st.maxPlayers, joinPassword: st.joinPassword,
    remotePassword: st.remotePassword, remotePort: st.remotePort, firewall: st.firewall, service: st.service,
    steamcmd: st.steamcmd, steamUser: st.steamcmd ? st.steamUser : "",
  } });
}
function onProgress(e) {
  const p = e.payload;
  if (p.step) { $("#iStep").textContent = p.step; log(p.step, "hd"); }
  if (p.line) log(p.line);
  if (p.error) {
    busy = false; log(p.error, "bad"); toast(p.error, true);
    $("#iTitle").textContent = "Setup could not finish"; $("#iBar").classList.remove("busy");
    $("#bBack").style.visibility = "visible"; $("#bBack").onclick = () => { st.uninstalling = false; cur = steps.indexOf("folder"); render(); $("#bBack").onclick = () => go(-1); };
  }
  if (p.done) {
    busy = false; st.result = p.summary; st.uninstalled = !!p.summary?.uninstalled;
    // Forget secrets as soon as they are no longer needed.
    st.remotePassword = st.remotePassword2 = "";
    $("#iBar").classList.remove("busy"); $("#iBar").firstElementChild.style.width = "100%";
    log(st.uninstalled ? "Uninstalled." : "Done.", "ok");
    setTimeout(() => go(1), 700);
  }
}

// ------------------------------------------------------------------ start
async function init() {
  const i = await invoke("info");
  flavor = i.flavor; auto = i.autotest || null;
  steps = flavor === "server" ? ["welcome", "folder", "steam", "server", "install", "finish"] : ["welcome", "folder", "install", "finish"];
  document.title = flavor === "server" ? "WSDS Setup" : "Witchspire Co-op Overhaul Setup";
  $("#appName").textContent = flavor === "server" ? "WSDS Setup" : "Co-op Overhaul";
  $("#appSub").textContent = flavor === "server" ? "Witchspire Dedicated Server" : "Witchspire mod setup";
  $("#logo").src = flavor === "server" ? "logo-server.png" : "logo-client.png";
  $("#wMin").onclick = () => win.minimize();
  $("#wClose").onclick = () => { if (busy) { toast("Please wait until setup has finished.", true); return; } win.close(); };
  $("#bBack").onclick = () => go(-1);
  $("#bNext").onclick = next;
  document.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName !== "BUTTON" && !["sUser", "sPass", "sCode"].includes(e.target.id)) next(); });
  await listen("progress", onProgress);
  await listen("steam", onSteam);
  st.gamePath = (await invoke("detect_game")) || (flavor === "server" ? "C:\\WitchspireServer" : "");
  if (st.gamePath) loadFonts(st.gamePath);
  render();
  if (auto) runAuto();
}

// Automated end-to-end run used for testing (fills the pages exactly like a person would).
async function runAuto() {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const shot = async (label) => { await invoke("auto_mark", { label }).catch(() => {}); await wait(1200); };
  await shot("welcome"); await next(); await wait(300);
  $("#fPath").value = auto.gamePath; $("#fPath").dispatchEvent(new Event("input")); await wait(1500);
  await shot("folder");
  if (auto.steamUser) {
    await next(); await wait(300);
    $("#sUser").value = auto.steamUser; $("#sPass").value = auto.steamPass; $("#sGo").click();
    for (let i = 0; i < 400 && $("#sGo").disabled; i++) await wait(500);
    await shot("steam");
    await invoke("auto_done", { ok: !!$("#log").textContent.match(/rejected|Steam Guard/) });
    return;
  }
  if (auto.uninstall) { $("#fUninstall").click(); }
  else {
    await next();
    if (flavor === "server") {
      for (const [id, v] of Object.entries({ vName: auto.worldName, vRp: auto.remotePassword, vRp2: auto.remotePassword, vRport: auto.remotePort, vPort: auto.gamePort })) if (v !== undefined) $("#" + id).value = v;
      $("#vFw").checked = !!auto.firewall; $("#vSvc").checked = !!auto.service;
      await shot("server"); await next();
    }
  }
  while (steps[cur] !== "finish") await wait(500);
  await shot("finish");
  await invoke("auto_done", { ok: !!st.result });
}

init();
