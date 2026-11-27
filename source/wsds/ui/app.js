// WSDS front end
const T = window.__TAURI__;
const invoke = T.core.invoke;
const listen = T.event.listen;
const win = T.window.getCurrentWindow();
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];

let config = {};
// Connection: this PC (local) or a remote WSDS reached over the signed remote-control channel.
let conn = { mode: "local", name: "This PC" };
const api = (name, args = {}) => conn.mode === "local" ? invoke("op_local", { name, args }) : invoke("op_remote", { id: conn.id, name, args });
let status = "stopped";
let players = [];
let items = [];
let bans = [];
let whitelist = { enabled: false, entries: [] };
let maxPlayers = 0;

// ---------------------------------------------------------------- fonts from the game install
async function loadFonts() {
  try {
    const f = await invoke("fonts");
    const add = async (family, b64, weight) => {
      if (!b64) return;
      const face = new FontFace(family, `url(data:font/otf;base64,${b64})`, { weight });
      await face.load();
      document.fonts.add(face);
    };
    await add("Griezly", f["Griezly-Regular"], "normal");
    await add("Lato", f["Lato-Regular"], "400");
    await add("Lato", f["Lato-Bold"], "700");
  } catch (e) { console.warn("fonts", e); }
}

// ---------------------------------------------------------------- settings schema (settings page + wizard)
const DIFFICULTIES = [["0", "Easy"], ["1", "Standard"], ["2", "Hard"], ["3", "Impossible"]];
const SCHEMA = [
  { section: "World", step: "World", fields: [
    { k: "WorldName", label: "Server / world name", type: "text", help: "Shown in the server console and world save." },
    { k: "WorldSlot", label: "World save", type: "world", help: "Pick an existing world or type a new name to create one." },
    { k: "Difficulty", label: "Difficulty (new worlds)", type: "select", options: DIFFICULTIES },
    { k: "Level", label: "Starting map", type: "select", options: [["L_StarterIsland", "Starter Island (default)"]] },
  ]},
  { section: "Network", step: "Network", fields: [
    { k: "Port", label: "Port (UDP)", type: "number", min: 1, max: 65535, help: "Forward this UDP port on your router for players outside your network." },
    { k: "MaxPlayers", label: "Max players", type: "number", min: 1, max: 32, help: "Witchspire is designed for up to 4; more is possible." },
    { k: "Password", label: "Server password", type: "password", help: "Leave empty for an open server. Players enter it in the Join Dedicated Server dialog." },
  ]},
  { section: "Gameplay", step: "Gameplay", fields: [
    { k: "Gameplay.ExperienceMultiplier", label: "Combat XP multiplier", type: "number", step: 0.1, min: 0, max: 20 },
    { k: "Gameplay.SkillXPRate", label: "Skill XP rate", type: "number", step: 0.1, min: 0, max: 20, help: "Gathering, crafting and other skills." },
    { k: "Gameplay.FamiliarExperienceMultiplier", label: "Familiar XP multiplier", type: "number", step: 0.1, min: 0, max: 20 },
    { k: "Gameplay.DayNightTimescale", label: "Day/night speed", type: "number", step: 0.1, min: 0.1, max: 10, help: "1 = normal day length." },
    { k: "Gameplay.ShareExperience", label: "Share kill XP with nearby players", type: "toggle" },
  ]},
  { section: "Co-op Overhaul", step: "Co-op", fields: [
    { k: "Coop.InstancedLoot", label: "Per-player loot", type: "toggle", help: "Everyone gets their own loot from chests and kills." },
    { k: "Coop.InstancedHarvest", label: "Per-player gathering", type: "toggle", help: "Satchels, coin piles, branches, rocks, flowers and bushes placed in the world can be gathered by every player; they regrow for each player on the usual timer." },
    { k: "Coop.InstancedLootRange", label: "Kill loot range (cm)", type: "number", min: 500, max: 50000, step: 500 },
    { k: "Coop.SharedObjectives", label: "Shared quest progress", type: "toggle", help: "Objectives complete for everyone online." },
    { k: "Coop.RetroactiveMilestones", label: "Catch-up for late joiners", type: "toggle", help: "New players receive milestones the world already reached." },
    { k: "Coop.CatchUpXP", label: "Catch-up XP", type: "toggle", help: "Lower-level players earn more XP." },
    { k: "Coop.CatchUpPerLevel", label: "Catch-up bonus per level behind", type: "number", step: 0.05, min: 0, max: 2 },
    { k: "Coop.CatchUpMaxMultiplier", label: "Catch-up maximum multiplier", type: "number", step: 0.1, min: 1, max: 10 },
    { k: "Coop.CovenSynergy", label: "Coven synergy bonuses", type: "toggle", help: "XP and harvest bonuses for playing near each other." },
    { k: "Coop.CovenRange", label: "Coven range (cm)", type: "number", min: 500, max: 50000, step: 500 },
    { k: "Coop.CovenBonusPerMember", label: "Bonus per nearby member", type: "number", step: 0.05, min: 0, max: 2 },
    { k: "Coop.CovenSkillShare", label: "Skill XP shared with nearby members", type: "number", step: 0.05, min: 0, max: 1 },
    { k: "Coop.BedSpawn", label: "Bed spawn points", type: "toggle", help: "Press interact on a bed to respawn there after dying instead of at your last hearth." },
    { k: "Coop.LuminaryRespec", label: "Luminary respec", type: "toggle", help: "Right-click a luminary to take it back and get its point back; R in a luminary menu resets that menu. Works for player and familiar luminaries." },
    { k: "Coop.MapMarkers", label: "Map markers", type: "toggle", help: "Left-click the world map to mark a spot for everyone. A bar on the map picks the type - Meet here, Danger, Loot or Base - each with its own icon and colour. It shows as a beam of light and on every player's map and compass with your name." },
    { k: "Coop.MaxMarkersPerPlayer", label: "Map markers per player", type: "number", min: 1, max: 10, help: "How many map markers each player can have at once; placing another removes their oldest." },
    { k: "Coop.DeathMarkers", label: "Death markers", type: "toggle", help: "When a player goes down, everyone sees a red beam, map icon and compass marker there, so friends can revive them. After a respawn it moves to the grave with their dropped items until the grave is emptied." },
    { k: "Coop.Pings", label: "Pings", type: "toggle", help: "The game's own ping (middle mouse button) also reaches players far away: a short beam, a compass marker and a map icon for 10 seconds, labelled with who pinged what." },
    { k: "Coop.SleepThroughNight", label: "Sleep through the night", type: "toggle", help: "At night, interacting with a bed lies you down to sleep. When every player online is asleep, the night is skipped to 7:00." },
    { k: "Coop.QuickStack", label: "Quick stack", type: "toggle", help: "A Quick Stack button in the inventory moves items from the bag into chests within 15 m that already hold the same kind of item." },
    { k: "Coop.WeaponReroll", label: "Weapon stat re-roll", type: "toggle", help: "At the weapon enhancement station, Master and Grandmaster weapons can get new random stat lines of the same rarity for 5 Brilliant Spirit Dust." },
    { k: "Coop.FamiliarSalvage", label: "Familiar salvage", type: "toggle", help: "Familiars can be salvaged at the salvage station: 1 Magick Essence and 2 Spirit Dust per rarity step, the tier set by the familiar's level (up to 9, 10-19, 20+)." },
  ]},
  { section: "Administration", step: "Admin", fields: [
    { k: "Coop.CoOwnerPermissions", label: "Who may build in sanctuaries", type: "select", options: [["AllPlayers", "Everyone (co-owners)"], ["AdminsOnly", "Admins only"]] },
    { k: "Coop.Admins", label: "Admins", type: "text", help: "Comma-separated player names or ids (used by 'Admins only')." },
  ]},
  { section: "Joining", step: null, fields: [
    { k: "Motd", label: "Message of the day", type: "textarea", maxlength: 500, help: "Shown to every player when they join. Leave empty for none. Takes effect right away, no restart needed." },
    { k: "Whitelist.Enabled", label: "Whitelist", type: "toggle", help: "Only players on the whitelist can join. Manage the list on the Bans page. Takes effect right away, no restart needed." },
  ]},
  { section: "Saving & Performance", step: null, fields: [
    { k: "AutoSaveSeconds", label: "Autosave interval (seconds)", type: "number", min: 30, max: 3600, step: 30 },
    { k: "Backups.IntervalMinutes", label: "World backup every (minutes)", type: "number", min: 5, max: 1440, step: 5, help: "The game copies the world and every player's save at this interval. Restore copies on the Backups page." },
    { k: "Backups.Keep", label: "Automatic backups to keep", type: "number", min: 1, max: 1000, help: "Older automatic backups are removed. Backups you make yourself are kept until you remove them." },
    { k: "ServerTickRate", label: "Server tick rate (Hz)", type: "number", min: 10, max: 120 },
    { k: "HeartbeatSeconds", label: "Status line interval (seconds)", type: "number", min: 10, max: 3600 },
    { k: "AutoRestartOnCrash", label: "Restart automatically after a crash", type: "toggle" },
    { k: "StartServerOnLaunch", label: "Start the server when WSDS opens", type: "toggle" },
  ]},
  { section: "Updates", step: null, fields: [
    { k: "AutoUpdate.Enabled", label: "Keep WSDS and the mod up to date", type: "toggle", help: "Checks the WSDS releases on GitHub. The background service installs new versions by itself." },
    { k: "AutoUpdate.OnlyWhenEmpty", label: "Only update while nobody is online", type: "toggle", help: "Otherwise players are disconnected for a minute while the server updates." },
    { k: "AutoUpdate.CheckHours", label: "Check every (hours)", type: "number", min: 1, max: 168 },
  ], extra: () => `<div class="field"><span class="lbl">Version</span><div class="row gap"><span id="updState" class="muted">WSDS ${esc(updateState.current || "")}</span><button class="btn small dark" id="updCheck">Check now</button><button class="btn small" id="updApply" style="display:none">Update now</button></div></div>` },
  { section: "Remote Control", step: null, fields: [
    { k: "RemoteControl.Enabled", label: "Allow remote control of this server", type: "toggle", help: "Lets WSDS on another PC manage this server (needs the password below)." },
    { k: "RemoteControl.Port", label: "Remote control port (TCP)", type: "number", min: 1, max: 65535 },
  ], extra: () => `<label class="field"><span class="lbl">Set remote control password</span><input type="password" id="rcPassword" placeholder="${config.RemoteControl?.Key === "set" ? "A password is set - type a new one to change it" : "No password set yet"}"><span class="help">Only a salted hash is stored. Restart WSDS after enabling remote control.</span></label>` },
  { section: "Live map", step: null, fields: [
    { k: "LiveMap.Enabled", label: "Live map on wsdsmaps.com", type: "toggle", help: "Anyone with your server's join details (and join password, if set) can open a live map at wsdsmaps.com: where players are, and each player's chests, satchels and quests. The server only sends positions while someone is watching." },
    { k: "LiveMap.Port", label: "Live map port (TCP)", type: "number", min: 0, max: 65535, help: "0 = the same number as the game port. Allow this TCP port in your router / host firewall as well as the game's UDP port. Restart WSDS after changing." },
  ]},
  { section: "Public server list", step: null, fields: [
    { k: "PublicListing.Enabled", label: "List this server on wsdsmaps.com/servers", type: "toggle", help: "Shows this server's name, description, player count and join address on wsdsmaps.com/servers so other players can find it. Needs the live map, reachable from the internet." },
    { k: "PublicListing.Description", label: "Description", type: "text", maxlength: 200, help: "Up to 200 characters, e.g. what kind of server it is, rules, when you usually play." },
  ], extra: () => `<div class="field rsblock"><span class="lbl">Status</span><span id="listState" class="muted small">-</span></div>` },
  { section: "Advanced", step: null, fields: [
    { k: "ConsoleVerbosity", label: "Console default view", type: "select", options: [["important", "Important lines"], ["all", "Everything"]] },
    { k: "ServerDataDir", label: "Server data folder", type: "text", help: "Saves, logs and server config. Relative to the mod folder. Keep it on the game's drive." },
    { k: "GameRoot", label: "Witchspire folder", type: "text", help: "Leave empty to use the folder WSDS is installed in." },
    { k: "ExtraArgs", label: "Extra server arguments", type: "text" },
  ]},
];

const getPath = (o, p) => p.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);
function setPath(o, p, v) { const ks = p.split("."); let a = o; for (let i = 0; i < ks.length - 1; i++) { a[ks[i]] ??= {}; a = a[ks[i]]; } a[ks.at(-1)] = v; }

let worlds = [];
function fieldHtml(f) {
  const v = getPath(config, f.k);
  const id = "f_" + f.k.replace(/\./g, "_");
  const help = f.help ? `<span class="help">${f.help}</span>` : "";
  if (f.type === "toggle") {
    return `<label class="toggle"><input type="checkbox" id="${id}" ${v ? "checked" : ""}><span class="knob"></span><span><span class="lbl">${f.label}</span>${help}</span></label>`;
  }
  let input;
  if (f.type === "select") {
    input = `<select id="${id}">${f.options.map(([val, name]) => `<option value="${val}" ${String(v) === val ? "selected" : ""}>${name}</option>`).join("")}</select>`;
  } else if (f.type === "world") {
    input = `<input type="text" id="${id}" list="worldList" value="${esc(v ?? "")}"><datalist id="worldList">${worlds.map((w) => `<option value="${esc(w)}">`).join("")}</datalist>`;
  } else if (f.type === "textarea") {
    input = `<textarea id="${id}" rows="3" ${f.maxlength ? `maxlength="${f.maxlength}"` : ""}>${esc(v ?? "")}</textarea>`;
  } else {
    const attrs = ["min", "max", "step", "maxlength"].filter((a) => f[a] !== undefined).map((a) => `${a}="${f[a]}"`).join(" ");
    input = `<input type="${f.type}" id="${id}" value="${esc(v ?? "")}" ${attrs}>`;
  }
  return `<label class="field"><span class="lbl">${f.label}</span>${input}${help}</label>`;
}
function readFields(fields) {
  for (const f of fields) {
    const el = document.getElementById("f_" + f.k.replace(/\./g, "_"));
    if (!el) continue;
    let v;
    if (f.type === "toggle") v = el.checked;
    else if (f.type === "number") v = el.value === "" ? getPath(config, f.k) : Number(el.value);
    else if (f.k === "Difficulty") v = Number(el.value);
    else v = el.value;
    setPath(config, f.k, v);
  }
}
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");

function renderSettings() {
  $("#settingsForm").innerHTML = SCHEMA.map((sec) => `<h3>${sec.section}</h3><div class="cols">${sec.fields.map(fieldHtml).join("")}${sec.extra ? sec.extra() : ""}</div>`).join("") + remotesSection();
  $$("[data-rmremote]").forEach((b) => (b.onclick = async () => { await invoke("remove_remote", { id: b.dataset.rmremote }); await refreshRemotes(); renderSettings(); }));
  const add = $("#addRemoteBtn"); if (add) add.onclick = addRemoteDialog;
  $("#updCheck").onclick = () => refreshUpdate(true);
  $("#updApply").onclick = applyUpdate;
  showUpdate();
  refreshListing();
}
async function saveSettings() {
  SCHEMA.forEach((s) => readFields(s.fields));
  await api("save_config", { config });
  const pw = $("#rcPassword")?.value;
  if (pw) { await call("set_remote_password", { password: pw }); $("#rcPassword").value = ""; }
  $("#sSaved").textContent = status === "stopped" ? "Saved." : "Saved - restart the server to apply.";
  setTimeout(() => ($("#sSaved").textContent = ""), 4000);
  refreshHeader();
  loadWhitelist();
  setTimeout(refreshListing, 8000);
}

// ---------------------------------------------------------------- public server list status
async function refreshListing() {
  const el = $("#listState");
  if (!el) return;
  let r;
  try { r = await api("listing_status"); } catch { el.textContent = "Not available on this server's WSDS version."; return; }
  const when = r.last?.time ? ` (checked ${new Date(r.last.time * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })})` : "";
  el.textContent = !r.enabled ? "Not listed (turned off)."
    : !r.liveMap ? "Not listed: the live map is turned off, and the server list needs it (see Live map above)."
    : r.last ? `${r.last.message}${when}` : "Announcing this server to wsdsmaps.com shortly...";
  el.style.color = r.enabled && r.liveMap && r.last ? (r.last.code === "listed" ? "var(--green)" : "var(--gold)") : "";
}

// ---------------------------------------------------------------- first-time setup wizard
const WIZ = [
  { name: "Welcome", html: () => `
      <h2>Your own always-online Witchspire world</h2>
      <p>WSDS runs Witchspire as a headless server on this PC: no graphics, no Steam login, nobody has to stay in game.
      Your friends join from the game's main menu with <span class="gold">Join Dedicated Server</span>.</p>
      <p>Everyone needs the <span class="gold">Witchspire Co-op Overhaul</span> mod installed (same version as this server).</p>
      <p class="muted">Witchspire folder: ${esc(config._gameRoot || "?")} ${config._gameFound ? "&#10003;" : "<span style='color:var(--red)'>(not found - set it in the last step)</span>"}</p>` },
  ...SCHEMA.filter((s) => s.step).map((s) => ({ name: s.step, fields: s.fields, html: () => `<h2>${s.section}</h2><div class="cols">${s.fields.map(fieldHtml).join("")}</div>` })),
  { name: "Finish", html: () => `
      <h2>All set</h2>
      <p>World <span class="gold">${esc(config.WorldName)}</span> on UDP port <span class="gold">${config.Port}</span>, up to ${config.MaxPlayers} players${config.Password ? ", password protected" : ""}.</p>
      <label class="toggle"><input type="checkbox" id="wStartNow" checked><span class="knob"></span><span class="lbl">Start the server now</span></label>
      <p class="muted">You can change everything later under Settings.</p>` },
];
let wizStep = 0;
function renderWizard() {
  $("#wSteps").innerHTML = WIZ.map((s, i) => `<span class="${i === wizStep ? "on" : i < wizStep ? "done" : ""}">${s.name}</span>`).join("");
  $("#wBody").innerHTML = WIZ[wizStep].html();
  $("#wBack").style.visibility = wizStep === 0 ? "hidden" : "visible";
  $("#wNext").textContent = wizStep === WIZ.length - 1 ? "Finish" : "Next";
}
async function wizardNext(dir) {
  const s = WIZ[wizStep];
  if (s.fields) readFields(s.fields);
  if (dir > 0 && wizStep === WIZ.length - 1) {
    const startNow = $("#wStartNow").checked;
    config.SetupComplete = true;
    await api("save_config", { config });
    $("#wizard").classList.remove("show");
    renderSettings(); refreshHeader();
    if (startNow) startServer();
    return;
  }
  wizStep = Math.max(0, Math.min(WIZ.length - 1, wizStep + dir));
  renderWizard();
}

// ---------------------------------------------------------------- status & dashboard
const fmtUptime = (s) => !s ? "-" : `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m ${String(s % 60).padStart(2, "0")}s`;
const STATUS_TEXT = { stopped: "Stopped", preparing: "Preparing files...", starting: "Starting...", running: "Online", stopping: "Stopping..." };
function applyStatus(st) {
  status = st.status;
  const gem = status === "running" ? "on" : status === "stopped" ? "off" : "wait";
  for (const id of ["#tGem", "#dGem"]) $(id).className = "gem " + gem;
  $("#tStatus").textContent = STATUS_TEXT[status] || status;
  $("#dStatus").textContent = STATUS_TEXT[status] || status;
  $("#dUptime").textContent = status === "stopped" ? "-" : fmtUptime(st.uptime);
  $("#bStart").disabled = status !== "stopped";
  $("#bStop").disabled = status === "stopped" || status === "stopping";
  $("#bRestart").disabled = status === "preparing" || status === "stopping";
  $("#bSave").disabled = status !== "running";
}
function refreshHeader() {
  $("#folderBlock").style.display = conn.mode === "local" ? "" : "none";
  $("#bUpdate").style.display = config._steamcmd ? "" : "none";
  $("#dWorld").textContent = config.WorldName || "Witchspire Dedicated Server";
  $("#dPort").textContent = config.Port;
  $("#dSlot").textContent = config.WorldSlot;
  $("#footWorld").textContent = config.WorldName || "";
  $("#dPlayers").textContent = `${players.length} / ${config.MaxPlayers || "∞"}`;
}
function activity(text, cls = "") {
  const d = document.createElement("div");
  const t = new Date().toLocaleTimeString();
  d.innerHTML = `<span class="t">${t}</span><span class="${cls}">${esc(text)}</span>`;
  const list = $("#activity");
  list.prepend(d);
  while (list.children.length > 200) list.lastChild.remove();
}
let toastTimer;
function toast(text, bad = false) {
  const el = $("#toast");
  el.textContent = text; el.className = "toast show" + (bad ? " bad" : "");
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (el.className = "toast"), 4000);
}
async function call(name, args) {
  try { return await api(name, args); } catch (e) { toast(String(e), true); throw e; }
}
async function startServer() { await call("server_start"); activity("Server starting"); }
async function adminCmd(c) { await call("admin", { command: c }); }

// ---------------------------------------------------------------- players
function renderPlayers() {
  $("#navPlayers").textContent = players.length;
  $("#pSummary").textContent = players.length ? `${players.length} online${maxPlayers ? " / " + maxPlayers : ""}` : "No players online";
  $("#playersEmpty").style.display = players.length ? "none" : "block";
  $("#playerRows").innerHTML = players.map((p, i) => {
    const hp = p.spawned && p.maxhp ? Math.round((100 * p.hp) / p.maxhp) : 0;
    return `<tr>
      <td><span class="pname">${esc(p.name)}</span><span class="pkey">${esc(p.key || "")}</span></td>
      <td>${p.spawned ? p.level : "<span class='muted'>joining</span>"}</td>
      <td>${p.spawned ? `<div class="hpbar" title="${p.hp} / ${p.maxhp}"><i style="width:${hp}%"></i></div>` : "-"}</td>
      <td>${p.ping ?? "-"} ms</td>
      <td class="muted small">${p.spawned ? `${p.x}, ${p.y}, ${p.z}` : "-"}</td>
      <td><div class="acts">
        <button class="btn small" data-act="give" data-i="${i}">Give</button>
        <button class="btn small dark" data-act="xp" data-i="${i}">XP</button>
        <button class="btn small dark" data-act="tp" data-i="${i}">Teleport</button>
        <button class="btn small dark" data-act="heal" data-i="${i}">Heal</button>
        <button class="btn small dark" data-act="msg" data-i="${i}">Message</button>
        ${onWhitelist(p) ? `<button class="btn small dark" disabled title="Already on the whitelist">Whitelisted</button>` : `<button class="btn small dark" data-act="wl" data-i="${i}">Whitelist</button>`}
        <button class="btn small dark" data-act="kick" data-i="${i}">Kick</button>
        <button class="btn small danger" data-act="ban" data-i="${i}">Ban</button>
      </div></td></tr>`;
  }).join("");
  refreshHeader();
}
const q = (s) => `"${String(s).replace(/"/g, "'")}"`;

function modal(title, body, buttons) {
  $("#mTitle").textContent = title;
  $("#mBody").innerHTML = body;
  $("#mButtons").innerHTML = "";
  for (const [label, cls, fn] of buttons) {
    const b = document.createElement("button");
    b.className = "btn " + cls; b.textContent = label;
    b.onclick = async () => { if ((await fn?.()) !== false) closeModal(); };
    $("#mButtons").append(b);
  }
  $("#overlay").classList.add("show");
  setTimeout(() => $("#mBody input")?.focus(), 30);
}
const closeModal = () => $("#overlay").classList.remove("show");

function playerAction(act, p) {
  const who = q(p.key || p.name);
  if (act === "heal") return adminCmd(`heal ${who}`).then(() => activity(`Healed ${p.name}`, "ok"));
  if (act === "wl") return call("whitelist_add", { key: p.key || "", name: p.name || "" }).then(() => {
    activity(`Added ${p.name} to the whitelist`, "ok");
    toast(whitelist.enabled ? `${p.name} is on the whitelist.` : `${p.name} is on the whitelist. The whitelist is off, so it is not enforced yet (Settings > Joining).`);
    loadWhitelist();
  });
  if (act === "give") {
    let selected = null;
    modal(`Give items to ${p.name}`, `
      <label class="field"><span class="lbl">Item</span><input type="text" id="mSearch" placeholder="Search ${items.length} items..."></label>
      <div class="itemlist" id="mItems"></div>
      <label class="field" style="margin-top:12px"><span class="lbl">Quantity</span><input type="number" id="mQty" value="1" min="1" max="100000"></label>`,
      [["Give", "", async () => {
        if (!selected) { toast("Pick an item first.", true); return false; }
        const n = Math.max(1, Number($("#mQty").value) || 1);
        await adminCmd(`give ${who} ${selected.tag} ${n}`);
        activity(`Gave ${p.name} ${n}x ${selected.name}`, "ok");
      }], ["Cancel", "dark"]]);
    const draw = () => {
      const f = $("#mSearch").value.toLowerCase();
      const list = items.filter((it) => !f || it.name.toLowerCase().includes(f) || it.tag.toLowerCase().includes(f)).slice(0, 200);
      $("#mItems").innerHTML = list.length ? list.map((it) => `<div data-tag="${esc(it.tag)}" class="${selected?.tag === it.tag ? "sel" : ""}"><span>${esc(it.name)}</span><span class="tag">${esc(it.tag)}</span></div>`).join("")
        : `<div class="muted">${items.length ? "No match" : "Item list loads once the server is online."}</div>`;
      $$("#mItems [data-tag]").forEach((d) => (d.onclick = () => { selected = items.find((x) => x.tag === d.dataset.tag); draw(); }));
    };
    $("#mSearch").oninput = draw; draw();
    return;
  }
  if (act === "xp") return modal(`Give XP to ${p.name}`, `<label class="field"><span class="lbl">Experience</span><input type="number" id="mVal" value="1000" min="1"></label>`,
    [["Give", "", async () => { const n = Number($("#mVal").value) || 0; await adminCmd(`xp ${who} ${n}`); activity(`Gave ${p.name} ${n} XP`, "ok"); }], ["Cancel", "dark"]]);
  if (act === "tp") {
    if (!p.spawned) return toast(`${p.name} is still joining. Try again once they are in the world.`, true);
    const others = players.filter((o) => o !== p && o.spawned);
    const toPlayer = others.length ? `<option value="player">To another player</option>` : "";
    return modal(`Teleport ${p.name}`, `<label class="field"><span class="lbl">Where</span><select id="mMode">${toPlayer}<option value="pos">To a position (x y z)</option></select></label>
      <div id="mPlayerBox"><label class="field"><span class="lbl">Player</span><select id="mVal">${others.map((o) => `<option value="${esc(o.key || o.name)}">${esc(o.name)}</option>`).join("")}</select></label>
      <label class="toggle"><input type="checkbox" id="mRev"><span class="knob"></span><span class="lbl">Bring that player to ${esc(p.name)} instead</span></label></div>
      <div id="mPosBox"><label class="field"><span class="lbl">Position</span><input type="text" id="mPos" value="${esc(`${p.x} ${p.y} ${p.z}`)}"><span class="help">Positions are shown on the Players page. The player is placed there, so add a little height (z) to avoid ending up inside the ground.</span></label></div>`,
      [["Teleport", "", async () => {
        if ($("#mMode").value === "pos") {
          const xyz = $("#mPos").value.trim().split(/[\s,]+/).map(Number);
          if (xyz.length !== 3 || xyz.some((n) => !Number.isFinite(n))) { toast("Enter three numbers: x y z", true); return false; }
          await adminCmd(`tppos ${who} ${xyz.join(" ")}`);
        } else {
          const target = q($("#mVal").value);
          await adminCmd($("#mRev").checked ? `tp ${target} ${who}` : `tp ${who} ${target}`);
        }
        activity(`Teleport requested`, "ok");
      }], ["Cancel", "dark"]]);
    const sync = () => { const pos = $("#mMode").value === "pos"; $("#mPosBox").style.display = pos ? "" : "none"; $("#mPlayerBox").style.display = pos ? "none" : ""; };
    $("#mMode").onchange = sync; sync();
    return;
  }
  if (act === "msg") return modal(`Message ${p.name}`, `<label class="field"><span class="lbl">Message</span><input type="text" id="mVal"></label>`,
    [["Send", "", async () => { await adminCmd(`msg ${who} ${q($("#mVal").value)}`); }], ["Cancel", "dark"]]);
  if (act === "kick" || act === "ban") return modal(`${act === "ban" ? "Ban" : "Kick"} ${p.name}?`,
    `<label class="field"><span class="lbl">Reason (shown to the player)</span><input type="text" id="mVal"></label>${act === "ban" ? "<p class='muted'>Banned players are disconnected and cannot rejoin until unbanned.</p>" : ""}`,
    [[act === "ban" ? "Ban" : "Kick", "danger", async () => { await adminCmd(`${act} ${who} ${q($("#mVal").value)}`); activity(`${act === "ban" ? "Banned" : "Kicked"} ${p.name}`, "bad"); }], ["Cancel", "dark"]]);
}

// ---------------------------------------------------------------- bans
function renderBans() {
  $("#bansEmpty").style.display = bans.length ? "none" : "block";
  $("#banRows").innerHTML = bans.map((b) => `<tr><td class="pname">${esc(b.name || "?")}</td><td class="muted small">${esc(b.key)}</td><td>${esc(b.reason || "")}</td>
    <td class="muted small">${b.time ? new Date(b.time * 1000).toLocaleString() : ""}</td><td class="right"><button class="btn small dark" data-unban="${esc(b.key)}">Unban</button></td></tr>`).join("");
  $$("[data-unban]").forEach((x) => (x.onclick = async () => { await call("unban", { key: x.dataset.unban }); activity(`Unbanned ${x.dataset.unban}`, "ok"); }));
}

// ---------------------------------------------------------------- whitelist (Bans page)
const onWhitelist = (p) => whitelist.entries.some((e) => (e.key && e.key === p.key) || (!e.key && e.name && p.name && e.name.toLowerCase() === p.name.toLowerCase()));
async function loadWhitelist() {
  try { whitelist = await api("whitelist"); } catch { whitelist = { enabled: false, entries: [], unsupported: true }; }
  renderWhitelist(); renderPlayers();
}
function renderWhitelist() {
  const on = whitelist.enabled, list = whitelist.entries || [];
  $("#wlBadge").textContent = on ? "On" : "Off";
  $("#wlBadge").className = "wlbadge" + (on ? " on" : "");
  $("#wlInfo").className = "small" + (on ? " muted" : " off");
  $("#wlInfo").textContent = whitelist.unsupported ? "This server's WSDS version has no whitelist yet - update it first."
    : on ? "The whitelist is on: only the players below can join."
    : "The whitelist is off, so this list is not enforced: anyone can join. Turn it on in Settings > Joining.";
  $("#wlEmpty").style.display = list.length ? "none" : "block";
  $("#wlRows").innerHTML = list.map((e, i) => `<tr><td class="pname">${esc(e.name || "?")}</td>
    <td class="muted small">${e.key ? esc(e.key) : "added by name - matched when they join"}</td>
    <td class="muted small">${e.time ? new Date(e.time * 1000).toLocaleString() : ""}</td>
    <td class="right"><button class="btn small dark" data-wlrm="${i}">Remove</button></td></tr>`).join("");
  $$("[data-wlrm]").forEach((x) => (x.onclick = async () => {
    const e = list[Number(x.dataset.wlrm)];
    await call("whitelist_remove", e.key ? { key: e.key } : { name: e.name });
    activity(`Removed ${e.name || e.key} from the whitelist`, "ok");
    loadWhitelist();
  }));
}
async function addWhitelistName() {
  const name = $("#wlName").value.trim();
  if (!name) return toast("Type a player name first.", true);
  await call("whitelist_add", { name });
  $("#wlName").value = "";
  activity(`Added ${name} to the whitelist`, "ok");
  loadWhitelist();
}

// ---------------------------------------------------------------- scheduled restarts
const RS_FIELDS = [
  { k: "Restarts.Enabled", label: "Restart the server on a schedule", type: "toggle", help: "Off by default. Players are warned before every restart." },
  { k: "Restarts.EveryHours", label: "Also restart every (hours the server has been up)", type: "number", min: 0, max: 720, step: 1, help: "0 = off. Counted from when the server started, e.g. 12 restarts it twice a day however long it has been running." },
  { k: "Restarts.WarnMinutes", label: "Warn players (minutes before)", type: "text", help: "For example 15, 5, 1: a notice on every player's screen at each of these times." },
  { k: "Restarts.Message", label: "Warning message", type: "text", maxlength: 200, help: "{minutes} becomes the time left, e.g. \"15 minutes\" or \"1 minute\"." },
  { k: "Restarts.SkipWhenEmpty", label: "Wait until nobody is online", type: "toggle", help: "At the planned time the server restarts only if nobody is online; otherwise it waits and restarts as soon as the last player leaves. If players are still on 2 hours later, it restarts anyway after the usual warnings. When this is off, players are warned and the server restarts on time." },
];
let rsTimes = [];
let rsState = null, rsFetched = 0, rsTimer = null;
const rsPad = (t) => { const m = /^(\d{1,2}):(\d{2})$/.exec(t.trim()); return m ? `${m[1].padStart(2, "0")}:${m[2]}` : t.trim(); };
const rsValid = (t) => /^([01]?\d|2[0-3]):[0-5]\d$/.test(t.trim());
function fmtIn(s) {
  s = Math.max(0, Math.round(s));
  if (s >= 3600) return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
  if (s >= 600) return `${Math.round(s / 60)} min`;
  if (s >= 60) return `${Math.floor(s / 60)} min ${String(s % 60).padStart(2, "0")} s`;
  return `${s} s`;
}
function renderRestartForm() {
  const r = config.Restarts || {};
  rsTimes = (r.Times || []).slice();
  $("#rsForm").innerHTML = `<h3>Schedule</h3>${fieldHtml(RS_FIELDS[0])}
    <div class="cols"><div class="rsblock"><span class="lbl">Every day at</span><div id="rsTimes"></div>
      <button class="btn small dark" id="rsAddTime">Add time</button>
      <span class="help">The server's own clock, 24-hour (e.g. 05:00 or 17:30).<span id="rsClock"></span></span></div>
    ${fieldHtml(RS_FIELDS[1])}</div>
    <h3>Warnings</h3><div class="cols">${fieldHtml(RS_FIELDS[2])}${fieldHtml(RS_FIELDS[3])}</div>${fieldHtml(RS_FIELDS[4])}`;
  const w = $("#f_Restarts_WarnMinutes"); if (w) w.value = (r.WarnMinutes || []).join(", ");
  drawTimes();
  $("#rsAddTime").onclick = () => { readTimes(); rsTimes.push(""); drawTimes(); $$(".rsTime").at(-1)?.focus(); };
}
function readTimes() { rsTimes = $$(".rsTime").map((i) => i.value); }
function drawTimes() {
  $("#rsTimes").innerHTML = rsTimes.length ? rsTimes.map((t, i) => `<div class="timerow"><input type="text" class="rsTime" value="${esc(t)}" placeholder="05:00" maxlength="5"><button class="btn small dark" data-rmtime="${i}">Remove</button></div>`).join("")
    : `<div class="muted small timerow">No daily time.</div>`;
  $$("[data-rmtime]").forEach((b) => (b.onclick = () => { readTimes(); rsTimes.splice(Number(b.dataset.rmtime), 1); drawTimes(); }));
}
async function saveRestarts() {
  readTimes();
  const times = rsTimes.map((t) => t.trim()).filter(Boolean);
  const bad = times.find((t) => !rsValid(t));
  if (bad) return toast(`"${bad}" is not a time. Use the 24-hour clock, e.g. 05:00 or 17:30.`, true);
  const warn = $("#f_Restarts_WarnMinutes").value.split(/[\s,;]+/).filter(Boolean).map(Number);
  if (warn.some((n) => !Number.isInteger(n) || n < 1 || n > 120)) return toast("Warning times are whole minutes from 1 to 120, e.g. 15, 5, 1.", true);
  readFields(RS_FIELDS);
  config.Restarts.Times = [...new Set(times.map(rsPad))].sort();
  config.Restarts.WarnMinutes = [...new Set(warn)].sort((a, b) => b - a);
  config.Restarts.EveryHours = Math.max(0, Number(config.Restarts.EveryHours) || 0);
  await call("save_config", { config });
  renderRestartForm();
  $("#rsSaved").textContent = "Saved.";
  setTimeout(() => ($("#rsSaved").textContent = ""), 4000);
  setTimeout(loadRestarts, 2500);
}
async function loadRestarts() {
  try { rsState = await api("restarts_status"); rsFetched = Date.now(); }
  catch (e) { rsState = null; $("#rsStatus").textContent = `Scheduled restarts are not available: ${e}`; return; }
  showRestarts();
}
function showRestarts() {
  const st = rsState;
  if (!st) return;
  const gone = (Date.now() - rsFetched) / 1000;
  const left = (s) => fmtIn(s - gone);
  const n = st.next, p = st.pending;
  let text, gem = "off";
  if (p && p.manual) { text = `Restarting in ${left(p.in)} (started by an admin).`; gem = "wait"; }
  else if (p && p.waiting) { text = `Waiting for the last player to leave, then restarting (at the latest ${n.latestLabel}, in ${left(n.latestIn)}).`; gem = "wait"; }
  else if (p) { text = `Restarting in ${left(p.in)} (${p.reason}). Players have been warned.`; gem = "wait"; }
  else if (!st.enabled) text = "Scheduled restarts are off.";
  else if (n) {
    text = `Next restart: ${n.label} (in ${left(n.in)}).`;
    if (n.waitEmpty) text += " If players are online then, it waits for them to leave (at the latest 2 hours later).";
    if (!st.running) text += " The server is not running right now.";
    gem = "on";
  } else if (st.everyHours > 0 && !st.running) text = "Scheduled restarts are on. The next one is planned once the server is running.";
  else text = "Scheduled restarts are on, but no restart is planned: add a daily time or set 'every N hours', then save.";
  $("#rsStatus").textContent = text;
  $("#rsGem").className = "gem " + gem;
  $("#rsCancel").style.display = p ? "" : "none";
  $("#rsCancel").textContent = p && !p.manual ? "Skip this restart" : "Cancel restart";
  $("#rsNow").disabled = !st.running || !!(p && p.manual);
  const clock = $("#rsClock"); if (clock) clock.textContent = st.serverTime ? ` It is ${st.serverTime} there now.` : "";
}
function restartSoon() {
  modal("Restart in 5 minutes?", `<p>Every player gets a notice now and again before the restart. Then the world is saved and the server restarts; players can rejoin after about a minute.</p>${players.length ? `<p class="gold">${players.length} player(s) online.</p>` : ""}`,
    [["Restart in 5 minutes", "", async () => { await call("restart_countdown", { minutes: 5 }); activity("Restart in 5 minutes"); loadRestarts(); }], ["Cancel", "dark"]]);
}
async function cancelRestart() {
  await call("restart_cancel");
  activity("Restart cancelled", "ok");
  loadRestarts();
}

// ---------------------------------------------------------------- console
const NOISE = /No auth service is available|no usable authentication mechanism|invalid or missing authentication token|exhausted all possible methods of authenticating|SteamNetworking\(\) failed|invalid ShaderMap|Missing OutParms|Cant find angelscript binding|AddGameplayCueData_Internal|NavData RegistrationFailed|SetTimer passed a negative|Steamworks: Steam|SteamAPI failed|Steam API failed|LogStreamline|LogSentry/;
const IMPORTANT = /WSDS|WSCoop|Error|Fatal|Critical|Assert|Login request|Join succeeded|Closing connection|LoadMap:|EasyMultiSave|LogGameMode|ADMIN/;
let consoleLines = [];
function classify(l) {
  if (/Fatal|Critical|Assert|Angelscript: Error|: Error:|"ok":false/.test(l)) return "err";
  if (/Warning/.test(l)) return "warn";
  if (/PLAYER JOINED|Join succeeded|"ok":true|SAVE COMPLETE/.test(l)) return "ok";
  if (/\[WSDS|\[WSCoop/.test(l)) return "ws";
  if (/LogNet/.test(l)) return "net";
  return "dim";
}
function visible(l) {
  if (NOISE.test(l)) return false;
  if ($("#cMode").value !== "all" && !IMPORTANT.test(l)) return false;
  const f = $("#cFilter").value.toLowerCase();
  return !f || l.toLowerCase().includes(f);
}
function appendConsole(lines) {
  const box = $("#console");
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
  const frag = document.createDocumentFragment();
  for (const l of lines) {
    consoleLines.push(l);
    if (!visible(l)) continue;
    const d = document.createElement("div");
    d.className = "l " + classify(l); d.textContent = l.replace(/^\[\d{4}\.\d\d\.\d\d-([\d.:]+)\]\[\s*\d+\]/, "[$1] ");
    frag.append(d);
  }
  box.append(frag);
  while (box.children.length > 3000) box.firstChild.remove();
  if (consoleLines.length > 20000) consoleLines.splice(0, consoleLines.length - 20000);
  if (atBottom) box.scrollTop = box.scrollHeight;
}
function redrawConsole() { const all = consoleLines; consoleLines = []; $("#console").innerHTML = ""; appendConsole(all); }
const HELP = [
  "players | items | save | ping",
  "kick <player> [reason]   ban <player> [reason]   unban <id>",
  "give <player> <item tag or name> <quantity>     xp <player> <amount>",
  "tp <player> <target player>   tppos <player> <x> <y> <z>   heal <player>",
  "say <message>   msg <player> <message>   time <0-24>   maxplayers <n>",
  "Names with spaces go in \"double quotes\".",
];
async function runConsoleCommand() {
  const c = $("#cInput").value.trim();
  if (!c) return;
  $("#cInput").value = "";
  if (c === "help") return appendConsole(HELP.map((h) => "[WSDS help] " + h));
  appendConsole([`> ${c}`]);
  await adminCmd(c);
}

// ---------------------------------------------------------------- wiring
// ---------------------------------------------------------------- backups
const BK_KIND = { auto: "Automatic", manual: "Made by you", "before-restore": "Before a restore", "before-update": "Before an update" };
function fmtSize(n) { return n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`; }
async function loadBackups() {
  let r;
  try { r = await api("backups_list"); } catch (e) { $("#bkInfo").textContent = String(e); return; }
  const list = r.backups || [];
  $("#bkInfo").textContent = `World "${r.slot}": the server backs up every ${r.intervalMinutes} minutes and keeps the newest ${r.keep} automatic backups. Restoring saves and stops the server, keeps a copy of the current world, then starts the server again.`;
  $("#bkEmpty").style.display = list.length ? "none" : "block";
  $("#bkRows").innerHTML = list.map((b) => `<tr><td class="pname">${esc(b.name)}<span class="pkey">${esc(BK_KIND[b.kind] || b.kind)}</span></td>
    <td class="muted small">${b.time ? new Date(b.time * 1000).toLocaleString() : ""}</td><td class="muted small">${fmtSize(b.size)}</td>
    <td class="right"><div class="acts"><button class="btn small" data-bkrestore="${esc(b.name)}">Restore</button><button class="btn small dark" data-bkdelete="${esc(b.name)}">Delete</button></div></td></tr>`).join("");
  $$("[data-bkrestore]").forEach((x) => (x.onclick = () => restoreBackup(x.dataset.bkrestore)));
  $$("[data-bkdelete]").forEach((x) => (x.onclick = () => modal("Delete this backup?", `<p>${esc(x.dataset.bkdelete)} will be gone for good.</p>`,
    [["Delete", "", async () => { await call("backup_delete", { name: x.dataset.bkdelete }); activity(`Backup deleted: ${x.dataset.bkdelete}`, "ok"); loadBackups(); }], ["Cancel", "dark"]])));
}
function restoreBackup(name) {
  modal("Restore this backup?", `<p>The world and every player's progress go back to <span class="gold">${esc(name)}</span>.</p>
    <p class="muted small">The server saves and stops, the current world is kept as a "before restore" backup (so you can undo this), then the server starts again.${players.length ? ` ${players.length} player(s) online will be disconnected.` : ""}</p>`,
    [["Restore", "", async () => { await call("backup_restore", { name }); activity(`Restoring ${name}...`); setTimeout(loadBackups, 8000); setTimeout(loadBackups, 25000); }], ["Cancel", "dark"]]);
}
async function createBackup() {
  await call("backup_create");
  activity("Backing up the world...");
  setTimeout(loadBackups, 6000); setTimeout(loadBackups, 20000);
}

function showPage(name) {
  $$(".menu a").forEach((a) => a.classList.toggle("active", a.dataset.page === name));
  $$(".page").forEach((p) => p.classList.toggle("active", p.id === "page-" + name));
  if (name === "backups") loadBackups();
  if (name === "bans") loadWhitelist();
  clearInterval(rsTimer); rsTimer = null;
  if (name === "restarts") {
    renderRestartForm(); loadRestarts();
    let n = 0;
    rsTimer = setInterval(() => { if (++n % 5 === 0) loadRestarts(); else showRestarts(); }, 1000);
  }
  if (name === "map") mountMap(); else unmountMap();
  if (name === "console") $("#console").scrollTop = $("#console").scrollHeight;
}

function applyState(st) { players = st.players || []; maxPlayers = st.maxPlayers || 0; renderPlayers(); }
function showResult(r) { activity(`${r.cmd}: ${r.msg}`, r.ok ? "ok" : "bad"); if (!r.ok) toast(r.msg, true); }

// ---------------------------------------------------------------- Map tab (wsdsmaps.com, embedded)
// The page is only loaded while the tab is open, so the server sends positions only while someone looks.
const MAP_ORIGIN = (() => { try { return localStorage.getItem("wsdsMapOrigin") || "https://wsdsmaps.com"; } catch { return "https://wsdsmaps.com"; } })();
let mapFrame = null;
function mapTarget() {
  const port = Number(config.LiveMap?.Port) || Number(config.Port) || 7777;
  if (conn.mode === "local" || conn.id === "local-service") return { server: `@self:${port}`, label: `this PC, TCP ${port}` };
  const r = remotes.find((x) => x.id === conn.id);
  return r ? { server: `${r.host}:${port}`, label: `${r.host}, TCP ${port}` } : null;
}
function postMapTarget() {
  if (!mapFrame || !mapFrame.contentWindow) return;
  const t = mapTarget();
  if (!t) return;
  mapFrame.contentWindow.postMessage({ type: "wsds-connect", server: t.server, password: config.Password || "" }, MAP_ORIGIN);
}
function mountMap() {
  const enabled = config.LiveMap?.Enabled !== false;
  const t = mapTarget();
  $("#mapInfo").textContent = enabled && t ? `Showing ${conn.name || "this server"} (${t.label})` : "";
  $("#mapOff").style.display = enabled ? "none" : "";
  $("#mapOff").textContent = enabled ? "" : "The live map is turned off for this server (Settings > Live map).";
  if (!enabled) return unmountMap();
  if (!mapFrame) {
    mapFrame = document.createElement("iframe");
    mapFrame.src = `${MAP_ORIGIN}/?embed=1`;
    mapFrame.title = "Live map";
    mapFrame.addEventListener("load", () => setTimeout(postMapTarget, 300));
    $("#mapHost").replaceChildren(mapFrame);
  } else postMapTarget();
}
function unmountMap() {
  if (mapFrame) { mapFrame.remove(); mapFrame = null; }
}
window.addEventListener("message", (e) => {
  if (e.origin === MAP_ORIGIN && e.data?.type === "wsdsmaps-ready" && mapFrame && e.source === mapFrame.contentWindow) postMapTarget();
});

// ---------------------------------------------------------------- connections (this PC / remote servers)
let remotes = [];
let pollCursor = { since: 0, resultsSince: 0, itemsVer: -1, bansVer: -1, whitelistVer: -1, busy: false, failed: 0 };
async function refreshRemotes() {
  remotes = await invoke("list_remotes");
  const opts = [`<option value="local">This PC</option>`];
  if (conn.id === "local-service") opts.push(`<option value="local-service">This PC (service)</option>`);
  for (const r of remotes) opts.push(`<option value="${esc(r.id)}">${esc(r.name)} (${esc(r.host)})</option>`);
  opts.push(`<option value="__add">+ Add remote server...</option>`);
  $("#serverPick").innerHTML = opts.join("");
  $("#serverPick").value = conn.mode === "local" ? "local" : conn.id;
}
async function loadConnection() {
  try {
    config = await api("get_config");
    worlds = await api("list_worlds");
    const snap = await api("snapshot");
    consoleLines = []; $("#console").innerHTML = "";
    appendConsole(snap.console);
    pollCursor = { since: snap.consoleNext, resultsSince: snap.resultsNext, itemsVer: snap.itemsVer, bansVer: snap.bansVer, whitelistVer: snap.whitelistVer, busy: false, failed: 0 };
    applyState(snap.state); items = snap.items; bans = snap.bans;
    applyStatus({ status: snap.status, uptime: snap.uptime });
  } catch (e) {
    toast(`Could not connect: ${e}`, true);
    if (conn.mode !== "local") { conn = { mode: "local", name: "This PC" }; await refreshRemotes(); return loadConnection(); }
  }
  renderSettings(); renderPlayers(); renderBans(); refreshHeader();
  loadWhitelist();
  if ($("#page-restarts").classList.contains("active")) { renderRestartForm(); loadRestarts(); }
  refreshUpdate(false);
  if ($("#page-map").classList.contains("active")) mountMap();
}
async function onPickServer() {
  const v = $("#serverPick").value;
  if (v === "__add") { $("#serverPick").value = conn.mode === "local" ? "local" : conn.id; return addRemoteDialog(); }
  if (v === "local") conn = { mode: "local", name: "This PC" };
  else if (v === "local-service") conn = { mode: "remote", id: "local-service", name: "This PC (service)" };
  else { const r = remotes.find((x) => x.id === v); conn = { mode: "remote", id: v, name: r?.name || v }; }
  activity(`Connected to ${conn.name}`);
  await loadConnection();
}
async function pollRemote() {
  if (conn.mode === "local" || pollCursor.busy) return;
  pollCursor.busy = true;
  try {
    const p = await api("poll", { since: pollCursor.since, resultsSince: pollCursor.resultsSince });
    pollCursor.failed = 0;
    applyStatus(p.status);
    if (p.lines.length) appendConsole(p.lines);
    pollCursor.since = p.next;
    for (const r of p.results) showResult(r);
    pollCursor.resultsSince = p.resultsNext;
    applyState(p.state);
    if (p.itemsVer !== pollCursor.itemsVer) { items = await api("items"); pollCursor.itemsVer = p.itemsVer; }
    if (p.bansVer !== pollCursor.bansVer) { bans = await api("bans"); pollCursor.bansVer = p.bansVer; renderBans(); }
    if (p.whitelistVer !== undefined && p.whitelistVer !== pollCursor.whitelistVer) { pollCursor.whitelistVer = p.whitelistVer; loadWhitelist(); }
  } catch (e) {
    if (++pollCursor.failed === 3) toast(`Lost contact with ${conn.name}: ${e}`, true);
    $("#tStatus").textContent = "Unreachable"; $("#tGem").className = "gem off";
  } finally { pollCursor.busy = false; }
}
function addRemoteDialog() {
  modal("Add Remote Server", `
    <label class="field"><span class="lbl">Address</span><input type="text" id="raHost" placeholder="e.g. 203.0.113.5"></label>
    <div class="cols"><label class="field"><span class="lbl">Port</span><input type="number" id="raPort" value="7780"></label>
    <label class="field"><span class="lbl">Name (optional)</span><input type="text" id="raName"></label></div>
    <label class="field"><span class="lbl">Remote control password</span><input type="password" id="raPw"></label>
    <p class="muted small">Only a key derived from the password is saved on this PC. The password itself is never sent over the network.</p>`,
    [["Connect", "", async () => {
      try {
        const r = await invoke("add_remote", { name: $("#raName").value, host: $("#raHost").value.trim(), port: Number($("#raPort").value) || 7780, password: $("#raPw").value });
        conn = { mode: "remote", id: r.id, name: r.name };
        await refreshRemotes(); await loadConnection(); activity(`Connected to ${r.name}`, "ok");
      } catch (e) { toast(String(e), true); return false; }
    }], ["Cancel", "dark"]]);
}
function remotesSection() {
  return `<h3>Remote Servers</h3><p class="muted small">Servers this PC can control. Switch between them with the selector at the top of the window.</p>
    ${remotes.length ? `<table class="table"><tbody>${remotes.map((r) => `<tr><td class="pname">${esc(r.name)}</td><td class="muted">${esc(r.host)}:${r.port}</td><td class="right"><button class="btn small dark" data-rmremote="${esc(r.id)}">Remove</button></td></tr>`).join("")}</tbody></table>` : ""}
    <div class="row gap" style="margin-top:12px"><button class="btn small" id="addRemoteBtn">Add remote server</button></div>`;
}

// ---------------------------------------------------------------- WSDS updates
let updateState = { current: "", info: null, busy: false };
function showUpdate() {
  const i = updateState.info, avail = i && i.available;
  const text = updateState.busy ? "Updating..." : avail ? `WSDS ${updateState.current} - version ${i.version} is available` : i ? `WSDS ${updateState.current} - up to date` : `WSDS ${updateState.current}`;
  if ($("#updState")) $("#updState").textContent = text;
  if ($("#updApply")) $("#updApply").style.display = avail && !updateState.busy ? "" : "none";
  const b = $("#bWsdsUpdate");
  if (b) { b.style.display = avail && !updateState.busy ? "" : "none"; if (avail) b.textContent = `Update to ${i.version}`; }
}
async function refreshUpdate(force) {
  try {
    if (force) { updateState.info = await api("update_check"); if (!updateState.current) updateState.current = updateState.info.current; }
    else { const r = await api("update_status"); updateState = { current: r.current, info: r.info, busy: r.busy }; }
    showUpdate();
    if (force) toast(updateState.info.available ? `Version ${updateState.info.version} is available.` : "WSDS is up to date.");
  } catch (e) { if (force) toast(`Update check failed: ${e}`, true); }
}
function applyUpdate() {
  const v = updateState.info?.version || "";
  modal(`Update to ${esc(v)}?`, `<p>The world is saved and the server stops for about a minute while WSDS and the Co-op Overhaul mod are updated, then everything restarts by itself.</p>${players.length ? `<p class="gold">${players.length} player(s) online will be disconnected.</p>` : ""}`,
    [["Update now", "", async () => { await call("update_apply"); updateState.busy = true; showUpdate(); activity(`Updating to ${v}`); }], ["Cancel", "dark"]]);
}

async function init() {
  await loadFonts();
  await refreshRemotes();
  if (await invoke("local_service").catch(() => false)) conn = { mode: "remote", id: "local-service", name: "This PC (service)" };
  await refreshRemotes();
  await loadConnection();
  $("#cMode").value = config.ConsoleVerbosity === "all" ? "all" : "important";
  $("#serverPick").onchange = onPickServer;
  $("#bUpdate").onclick = () => modal("Update Witchspire?", "<p>The server is stopped, the game is updated with SteamCMD, the Co-op Overhaul mod is re-applied and the server starts again. This can take several minutes.</p>",
    [["Update", "", async () => { await call("update_game"); activity("Game update started"); }], ["Cancel", "dark"]]);

  $$(".menu a").forEach((a) => (a.onclick = () => showPage(a.dataset.page)));
  $("#wMin").onclick = () => win.minimize();
  $("#wMax").onclick = () => win.toggleMaximize();
  $("#wClose").onclick = () => win.close();
  $("#bStart").onclick = startServer;
  setInterval(pollRemote, 1000);
  setInterval(() => refreshUpdate(false), 5 * 60 * 1000);
  $("#bWsdsUpdate").onclick = applyUpdate;
  $("#bStop").onclick = () => call("server_stop").then(() => activity("Server stopping"));
  $("#bRestart").onclick = () => call("server_restart").then(() => activity("Server restarting"));
  $("#bSave").onclick = () => call("server_save").then(() => activity("Saving world", "ok"));
  $("#bAnnounce").onclick = async () => { const m = $("#announce").value.trim(); if (!m) return; await adminCmd(`say ${q(m)}`); $("#announce").value = ""; activity(`Announced: ${m}`, "ok"); };
  $("#announce").onkeydown = (e) => { if (e.key === "Enter") $("#bAnnounce").click(); };
  const fmtHour = (h) => `${String(Math.floor(h)).padStart(2, "0")}:${h % 1 ? "30" : "00"}`;
  $("#timeSlider").oninput = () => ($("#timeVal").textContent = fmtHour(Number($("#timeSlider").value)));
  $("#bTime").onclick = async () => { const h = Number($("#timeSlider").value); await adminCmd(`time ${h}`); activity(`Time of day set to ${fmtHour(h)}`, "ok"); };
  $$("[data-open]").forEach((b) => (b.onclick = () => invoke("open_folder", { which: b.dataset.open }).catch((e) => toast(String(e), true))));
  $("#bkRefresh").onclick = loadBackups;
  $("#bkCreate").onclick = createBackup;
  $("#wlAdd").onclick = addWhitelistName;
  $("#wlName").onkeydown = (e) => { if (e.key === "Enter") addWhitelistName(); };
  $("#rsSave").onclick = saveRestarts;
  $("#rsNow").onclick = restartSoon;
  $("#rsCancel").onclick = cancelRestart;
  $("#playerRows").onclick = (e) => { const b = e.target.closest("[data-act]"); if (b) playerAction(b.dataset.act, players[Number(b.dataset.i)]); };
  $("#cSend").onclick = runConsoleCommand;
  $("#cInput").onkeydown = (e) => { if (e.key === "Enter") runConsoleCommand(); };
  $("#cFilter").oninput = redrawConsole; $("#cMode").onchange = redrawConsole;
  $("#cClear").onclick = () => { consoleLines = []; $("#console").innerHTML = ""; };
  $("#sSave").onclick = saveSettings;
  $("#overlay").onclick = (e) => { if (e.target.id === "overlay") closeModal(); };
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeModal();
    if (e.key === "Enter" && $("#wizard").classList.contains("show") && !["INPUT", "SELECT", "TEXTAREA"].includes(document.activeElement?.tagName)) wizardNext(1);
  });
  $("#wBack").onclick = () => wizardNext(-1);
  $("#wNext").onclick = () => wizardNext(1);

  const local = (fn) => (e) => conn.mode === "local" && fn(e);
  await listen("status", local((e) => applyStatus(e.payload)));
  await listen("log", local((e) => appendConsole(e.payload)));
  await listen("state", local((e) => applyState(e.payload)));
  await listen("items", local((e) => { items = e.payload; activity(`Item catalogue loaded (${items.length} items)`); }));
  await listen("bans", local((e) => { bans = e.payload; renderBans(); }));
  await listen("whitelist", local((e) => { whitelist = e.payload; renderWhitelist(); renderPlayers(); }));
  await listen("result", local((e) => showResult(e.payload)));
  await listen("closing", () => $("#closing").classList.add("show"));

  if (conn.mode === "local" && !config.SetupComplete) { renderWizard(); $("#wizard").classList.add("show"); }
  if (config._autotest) autotest();
  // Developer switch (WSDS_START_PAGE): open a page directly, e.g. for screenshots.
  const startPage = (await invoke("op_local", { name: "get_config", args: {} }).catch(() => ({})))._startPage;
  if (startPage) { const nav = document.querySelector(`[data-page="${startPage}"]`); if (nav) nav.click(); }
}

// Developer self-test (WSDS_AUTOTEST): exercises the real UI -> backend -> server path.
async function autotest() {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  showPage("console");
  if (status === "stopped") await startServer();
  while (status !== "running") await wait(1000);
  await wait(4000);
  for (const c of ["ping autotest", "players", "say WSDS admin panel test", "time 9.5"]) { appendConsole([`> ${c}`]); await adminCmd(c); }
  await wait(12000);
  showPage("dashboard");
}
init();
