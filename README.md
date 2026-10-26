# SnipasteFeishu

SnipasteFeishu is a menu-bar application for macOS. Press F2, drag a region of the screen, and choose one of three actions: Save, Ingest, or Cancel.

Save copies a PNG to the clipboard. Ingest closes the selection and continues in the background: a vision model reads the dialogue in the screenshot, then writes one record to a Feishu base. A system notification confirms each success and numbers it within the calendar day, as in “18th, shot 1”. An image that fails to upload is kept in a local library and can be sent again from the menu.

## Contributors

The table below is the current roster of people who follow the Douyin account behind this project. Each row is a portrait and a name. Account identifiers are omitted. The roster is replaced every day at 00:00, Asia/Shanghai.

<!-- contributors:start -->
The roster is not available in this revision. A signed-in Douyin session is required before portraits and names can be written here.
<!-- contributors:end -->

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/` | Menu-bar application |
| `Helper/` | Separate capture helper |
| `build.sh` | Build and code-sign the application |
| `followers/` | Daily contributor archives and the update script |
| `.github/workflows/update-followers.yml` | Scheduled refresh at 00:00, Asia/Shanghai |

The vision and Feishu writer used by the installed application live on the author’s machine, in `scripts/read_and_ingest_screenshot.py`. This repository does not contain Feishu credentials, the vision API key, a Douyin session, or the code-signing private key.

## Build

macOS 14 and the `swiftc` compiler from the Xcode command-line tools are required.

```bash
./build.sh
```

When the login keychain contains the code-signing certificate named `Screenshot Ingest Local`, the script signs with that identity. Otherwise it uses an ad-hoc signature. Screen Recording permission is then tied to the new signature and must be granted again under System Settings → Privacy & Security → Screen & System Audio Recording.

The installed application is `~/Applications/截图入库.app`. It starts at login through `~/Library/LaunchAgents/com.chenglong.screenshot-ingest.plist`. Capture is performed by a separately signed `CaptureHelper`. Rebuilding or re-signing that helper drops the existing Screen Recording grant.

If F2 still changes display brightness, enable “Use F1, F2, etc. keys as standard function keys” in System Settings → Keyboard.

Environment variables are listed in [.env.example](.env.example). Do not commit a filled-in `.env`.

Failed uploads are stored in `~/Library/Application Support/截图入库/failed/`. The menu provides Retry Failed Library and Open Failed Library.

## Refreshing the roster

The repository is public. Anyone can see the portraits and names in the table above.

Before the first run, add these Actions secrets:

| Secret | Value |
| --- | --- |
| `DOUYIN_COOKIE` | The Cookie header from a signed-in douyin.com session. It must include `sessionid`. |
| `DOUYIN_SEC_UID` | The `MS4wLjAB…` segment of your profile URL |
| `DOUYIN_UNIQUE_ID` | Optional. Used only when `DOUYIN_SEC_UID` is absent. |
| `DOUYIN_FOLLOWER_LIMIT` | Optional. Maximum number of people written in one day. The default is 2000. |

Then run the **Daily contributors** workflow once. A successful run commits:

- this README, with the current portraits and names in the table above
- `followers/days/YYYY-MM-DD.md`, the archive for that date
- `followers/avatars/`, portrait files; an unchanged portrait is not downloaded again

Workflow permissions must allow Actions to write to the repository. That setting is already enabled on this project.

Douyin often rejects requests from GitHub-hosted runners. If the log shows an empty response, or a refusal other than a logged-out session, change `runs-on` in the workflow to a self-hosted runner on this Mac. The session cookie stays in the secret store.

## Excluded from version control

- `.env`, session cookies, and Feishu or vision API credentials
- the built application under `build/`
- code-signing material (`.pem`, `.p12`, `.cer`)
- screenshots in the failed-upload library

## License

[MIT](LICENSE)
