# MCXboxBroadcast
[![License: GPL-3.0](https://img.shields.io/github/license/MCXboxBroadcast/Broadcaster)](LICENSE)
[![Build Release](https://github.com/MCXboxBroadcast/Broadcaster/actions/workflows/release.yml/badge.svg)](https://github.com/MCXboxBroadcast/Broadcaster/actions/workflows/release.yml)
[![Discord](https://img.shields.io/discord/1139621390908133396?label=discord&color=5865F2)](https://discord.gg/Tp3tA2kdCN)

A simple tool that broadcasts an existing [Geyser](https://github.com/GeyserMC/Geyser)/Bedrock server over Xbox Live.

This shows up to the authenticated accounts friends in-game as a joinable session.

![Example screenshot](https://user-images.githubusercontent.com/5401186/159083033-b965bfba-de17-4708-8979-1f33bfd5fa28.png)

# DISCLAIMER
You use this project at your own risk, the contributors are not responsible for any damage or loss caused by the software. We suggest you use an alt account for running the tool in case the account is banned as we emulate some features of a client which may or may not be against TOS.

## Features
 - Syncing of MOTD and other server details
 - Automatic friend list management
 - Easy Geyser integration (as an extension)
 - Shows as online and playing Minecraft in the Xbox app and website
 - Multi-account support
 - Web manager for larger networks
 - Uploading of a custom image for the account (see below for more info)

## Pelican and Pterodactyl Panels

This fork provides separate Egg files because Pelican and Pterodactyl use
different export formats. In your Panel's Egg import screen, import the file
that matches your Panel:

- `egg-m-c-xbox-broadcast.json` — Pelican (`PLCN_v3`)
- `egg-m-c-xbox-broadcast-pterodactyl.json` — Pterodactyl (`PTDL_v2`)

GitHub Releases also provide the same definitions under the shorter asset names
`panel-pelican.json` and `panel-pterodactyl.json`, together with
`MCXboxBroadcastStandalone.jar`.

Both Eggs install only the official `MCXboxBroadcastStandalone.jar` from
`MCXboxBroadcast/Broadcaster`. By default (`AUTO_UPDATE=1`), every server
startup checks that repository's latest official GitHub release. Set
`AUTO_UPDATE` to `0` in the Panel startup variables to disable the network
update check.

An update downloads to a temporary file and must pass Java 21's `jar tf`
validation before it replaces the configured `SERVER_JARFILE`. If the release
check, download, validation, or replacement fails, startup falls back to the
current Jar only if it is still valid. Jar installation and updates leave
`config.yml`, authentication files, and session data unchanged. Concurrent
install or startup update attempts are serialized so the Jar and recorded
release URL cannot become mismatched.

If no valid Jar remains, startup stops rather than running an unverified
download. Restore GitHub access and restart with automatic updates enabled, or
use the Panel's reinstall action to fetch a fresh official Jar.

Runtime Jar checks do not update an Egg definition already imported into your
Panel. The Pelican file's `meta.update_url` points to this fork's Pelican
definition for Pelican's Egg update mechanism. The Pterodactyl file has no
update URL, so import a newer Pterodactyl JSON manually when its Egg definition
changes.

## Docker
There is a docker image available for the standalone version of the tool, this can be found at `ghcr.io/mcxboxbroadcast/standalone:latest`

```bash
docker run --rm -it -v /path/to/config:/opt/app/config ghcr.io/mcxboxbroadcast/standalone:latest
```

## Installation
### Extension
1. Download the latest release file `MCXboxBroadcastExtension.jar`
2. Drop the extension into the Geyser `extensions` folder
3. Restart the server
4. Wait for the extension to start and present you with an authentication code
   - `To sign in, use a web browser to open the page https://www.microsoft.com/link and enter the code XXXXXXXX to authenticate.`
5. Follow the link and enter the code
6. Login to the account you want to use
7. Follow the account on Xbox LIVE
8. Check the friends tab ingame and you should see the server listed

### Standalone
1. Download the latest release file `MCXboxBroadcastStandalone.jar`
2. Start the jar file using `java -jar MCXboxBroadcastStandalone.jar`
3. Wait for the extension to start and present you with an authentication code
    - `To sign in, use a web browser to open the page https://www.microsoft.com/link and enter the code XXXXXXXX to authenticate.`
4. Follow the link and enter the code
5. Login to the account you want to use
6. Follow the account on Xbox LIVE
7. Edit the `config.yml` to have the correct ip and port for the target server
8. Restart the tool
9. Check the friends tab ingame and you should see the server listed

## Manager
There is a web manager available for donators. After joining the relevent [GitHub sponsors](https://github.com/sponsors/rtm516) tier you will be able to access its builds at https://github.com/MCXboxBroadcast/Manager/releases

Note: This also requires a MongoDB instance to be running

<details>
   <summary>Screenshots</summary>

   ![Bots view](https://github.com/user-attachments/assets/e4760c93-a146-45b9-b029-fd3c5c6e7bea)
   ![Bot info](https://github.com/user-attachments/assets/462f1d8b-c8ab-42e0-ab0e-cb335fc00ab4)
   ![Bot options](https://github.com/user-attachments/assets/f603d51f-f59e-4a49-b2a5-ffeb074109e8)
   ![Server options](https://github.com/user-attachments/assets/e203eac3-7190-4510-9f5b-ef87de507cab)
   ![Manager settings](https://github.com/user-attachments/assets/11f85c70-9b50-4039-bddb-961833b7d11e)
</details>

## Custom Image
![Custom image](https://github.com/user-attachments/assets/b00832fd-8fa6-4c7a-b764-342bcf6fc037)

You can add a custom image to the profile page for the account by placing a `screenshot.jpg` in the same directory as the `config.yml`.

The best settings for this image are `1200x675`, quality `90` and chroma subsampling `4:2:0`.

This can take a few minutes to update on the Xbox Live servers and show ingame.

## Commands
For the extension version prefix with `/mcxboxbroadcast`

| Command | Description |
| --- | --- |
| `exit` (Standalone Only) | Exits the program |
| `restart` | Restarts the tool |
| `dumpsession` | Dumps the current session data to files for debugging |
| `accounts list` | Lists the accounts that are currently in use and their followers count |
| `accounts add <sub-session-id>` | Adds an account to the list of accounts to use |
| `accounts remove <sub-session-id>` | Removes an account from the list of accounts to use |
