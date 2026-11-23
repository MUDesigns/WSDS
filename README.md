# Witchspire Dedicated Server + Co-op Overhaul

A headless, always-on Witchspire server you join by IP, plus a co-op progression overhaul
(per-player loot and gathering, shared quest/spire progress with late-joiner catch-up, catch-up XP, coven synergy,
co-owned sanctuaries).

Built against Witchspire **0.3.0-ea, build CL 32175 (UE 5.7.4)**. Every player *and* the server
need the same mod version, because the mod changes gameplay scripts.

## Setup programs

* **Witchspire Co-op Mod Setup.exe** - for players. Finds your Steam copy of Witchspire, installs the
  mod (original files are backed up) and can uninstall it again.
* **WSDS Setup.exe** - for the server machine. Downloads Witchspire with SteamCMD (one sign-in with an
  account that owns the game; the password is only passed to SteamCMD), installs the mod and **WSDS**,
  opens the firewall ports and registers a background service that starts with Windows.

## WSDS (Witchspire Dedicated Server control panel)

A small Windows app (Tauri + WebView2, about 6 MB) styled after the game's own UI:

* First-time setup wizard and a settings page for world, network, gameplay rates and co-op options.
* Dashboard: start / stop / restart / save, announcements, time of day, game updates through SteamCMD.
* Players: kick, ban, give any item in any amount, XP, heal, teleport a player to another player, private messages.
* Console tab with the live server log and an admin command line (`help` lists the commands).
* **Remote control:** manage a server on another machine. Enable it in Settings (or in WSDS Setup) with
  a password, then on your own PC choose **+ Add remote server** in the server selector at the top.
  Requests are signed with HMAC-SHA256 using a key derived from the password (the password itself
  never crosses the network and only a salted hash is stored), with timestamps and nonces against
  replay. The channel is authenticated but not encrypted: put it behind a VPN if the console output
  is sensitive to you.

`WSDS.exe --headless` runs the server and the remote-control API without a window (this is what the
background service does). Opening WSDS on that machine attaches to the running service.

## Install (every player, and the server machine)

1. Put the `WitchspireCoopMod` folder inside your Witchspire folder, next to `Hercules`
   (Steam: right-click Witchspire > Manage > Browse local files).
2. Run `Install.ps1` (right-click > Run with PowerShell).

After a Steam update or "Verify integrity of game files", run `Install.ps1` again. If it reports
`CHANGED BY GAME UPDATE`, the update changed scripts the mod edits. Nothing is modified in that case:
wait for an updated mod version.

`Uninstall.ps1` restores every original game file.

## Run the server

1. Edit `ServerConfig.json` (see below).
2. Double-click `StartServer.bat`. A console window shows the live, colour-coded server log:
   joins/leaves, saves, warnings, errors.
   * **S** saves now.
   * **Q** or **Ctrl+C** saves everything and shuts down cleanly.
   * Crashes restart automatically (it stops after 3 quick crashes in a row).
3. Players reach the server on **UDP port 7777** (or the port you set). For players outside your
   network, forward that UDP port on your router to the server PC and allow it in Windows Firewall.

The server runs without graphics or sound (it never compiles shaders). It does not need a Steam
login. Its world and characters live in `ServerData\Saved\SaveGames\<WorldSlot>\`; every player's
character is stored there as well.

It runs from `ServerInstall\`, a mirror of the game folder built automatically from links (no extra
disk space) that carries one server-only config file. Your own game install is not changed.

## Join a server

**From the game (recommended):** start Witchspire normally through Steam. On the main menu choose
**Join Dedicated Server**, enter the server's address and port (default 7777) and press **Join**.
The dialog remembers the last server you joined.

* Your character on that server is tied to your Steam account. The first join takes you through
  character creation.
* A direct IP connection is refused while the game is signed in to Epic Online Services, so the
  dialog signs out of EOS just before connecting. The game signs back in when you return to the
  main menu, so hosting and Join Friends keep working.

**Without Steam:** edit `ClientConfig.json` (`ServerAddress`, `Port`, `PlayerName`) and double-click
`JoinServer.bat` (or `JoinServer.bat -Server 203.0.113.5:7777 -Name Morgana`). The game starts and
connects automatically; the Steam overlay and achievements are unavailable in that session. If you
have joined from the menu on this PC before, you get the same character.

After a game or GPU-driver update, the first launch compiles shaders and can take a few minutes,
exactly as in normal play.

## ServerConfig.json

| Key | Default | Meaning |
|---|---|---|
| `WorldSlot` | `DedicatedWorld` | Save slot to host. Created on first start. |
| `WorldName` | | Display name of the world. |
| `Level` | `L_StarterIsland` | Map used when the world is first created. |
| `Difficulty` | `1` | New worlds: 0 Easy, 1 Standard, 2 Hard, 3 Impossible. |
| `AutoSaveSeconds` | `300` | Autosave interval. The world is also saved when a player leaves and on shutdown. |
| `HeartbeatSeconds` | `60` | How often the console prints a status line. |
| `Port` | `7777` | UDP port. |
| `ServerTickRate` | `30` | Simulation rate cap (Hz). |
| `AutoRestartOnCrash` | `true` | Restart the server process after a crash. |
| `ConsoleVerbosity` | `important` | `all` shows every engine log line in the console (the log file always has everything). |
| `ServerDataDir` | `ServerData` | Where saves, logs and server config live. |
| `ExtraArgs` | | Extra command-line arguments for the server process. |

### Coop

| Key | Default | Meaning |
|---|---|---|
| `InstancedLoot` | `true` | Each player can loot each chest once; every looter gets an independent roll straight into their inventory. Enemy and boss kills give every player within range their own roll. |
| `InstancedLootRange` | `6000` | Range (cm) for sharing kill drops. |
| `InstancedHarvest` | `true` | Items placed in the world (satchels, coin piles, branches, rocks, flowers, bushes) can be gathered by every player. A node a player has gathered stays up for everyone else and regrows for that player on its usual timer; one-time finds such as satchels are once per player. |
| `SharedObjectives` | `true` | When anyone completes an objective (story, spires, regions), it completes for everyone online, including its unlocks. |
| `RetroactiveMilestones` | `true` | Players who join later get every milestone already achieved in the world, so nobody is locked out of flight, regions or story steps. |
| `CatchUpXP` | `true` | Players below the highest-level player online earn more kill XP. |
| `CatchUpPerLevel` | `0.15` | +15% XP per level behind... |
| `CatchUpMaxMultiplier` | `2.5` | ...up to x2.5. |
| `CoOwnerPermissions` | `AllPlayers` | `AllPlayers`: everyone co-owns every sanctuary (vanilla behaviour). `AdminsOnly`: only `Admins` may place or destroy buildings and level hearths. |
| `Admins` | | Comma-separated player names or save ids for `AdminsOnly`. |
| `CovenSynergy` | `true` | Bonuses for playing together. |
| `CovenRange` | `5000` | Range (cm) for counting nearby coven members. |
| `CovenBonusPerMember` | `0.1` | +10% kill and skill XP per nearby member, and a 10% bonus-harvest chance per nearby member. |
| `CovenSkillShare` | `0.25` | Nearby members receive 25% of the skill XP (gathering, crafting, taming...) a member earns. |

World-wide effects of quests (key items, corruption events, global narration) happen once per
world, not once per player.

## What the mod changes

* New scripts: `Hercules\Script\Mods\WSDedicated\` (server bootstrap, Join Dedicated Server
  menu entry and dialog, direct connect, player identity) and `Hercules\Script\Mods\WSCoop\` (co-op systems, self-test).
* Edited game scripts (originals in `backup\`): see `payload\manifest.json`. Every edit is marked
  `[WSCoop]`.
* Game fixes needed for a hostless server: the time-of-day sync no longer floods joining clients
  with reliable RPCs, quest key items are granted without a local host, and map fog bookkeeping
  works without a GPU.

## Troubleshooting

* **"The connection is not encrypted"**: the game was still signed in to Epic Online Services when it connected. Use the main menu's **Join Dedicated Server** (it signs out first) or `JoinServer.bat`.
* **Connection timed out**: check the address and port, the router forward and the firewall, and
  that the server console shows `Opening world as listen server`.
* **Server console shows errors**: the full log is in `ServerData\Logs\`.


## Building from source

Requirements: Windows, Rust (stable), the WebView2 runtime, and Witchspire installed with this folder
inside it.

* `source/wsds` - WSDS (`cargo build --release`).
* `source/installer` - both setup programs (`--features client` / `--features server`).
* `payload/Script/Mods` - the mod's own Angelscript code (`WSDedicated`, `WSCoop`).
* `BuildPackage.ps1` - snapshots the installed mod into `payload/` (needs a local install where the patches
  are applied). `BuildInstallers.ps1` - packs the payloads and builds both setup programs into `dist/`.

This repository does not contain any of Witchspire's own files. The edited copies of game scripts the mod
needs (`payload/Patched`), the game's fonts and Epic's Oodle library (`tools/oo2core_9_win64.dll`) are
not redistributed here. See `tools/README.md` for the third-party tools.

Witchspire is a trademark of its respective owners. This is an unofficial fan project and is not
affiliated with or endorsed by the game's developers or publishers.
