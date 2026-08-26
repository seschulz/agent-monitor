# Agent Monitor

Agent Monitor is a native macOS menu-bar app for keeping track of local [Codex CLI](https://developers.openai.com/codex/cli/) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. It is especially useful when several agents are running in different projects or terminal windows.

The app shows which project and agent are active, how long each session has been running, and which terminal hosts it. When a turn finishes, Agent Monitor can show a floating overlay, post a macOS notification, or announce the result aloud. Clicking a session returns you to its terminal application.

## Highlights

- Monitors Codex CLI and Claude Code from the same menu-bar app
- Shows the project, agent, terminal, state, and elapsed runtime
- Offers movable floating widgets in Minimal, Compact, Standard, and Spacious layouts
- Keeps completed sessions visible for a configurable period
- Supports dismissing one completed session or clearing all of them
- Can launch automatically at login
- Uses Sparkle to check, verify, and install GitHub Releases automatically or on demand
- Provides optional macOS notifications and spoken completion alerts
- Recognizes Terminal, iTerm2, Ghostty, IntelliJ terminals, and other macOS terminal hosts when their application metadata is available
- Stores session metadata locally and does not record prompts, responses, commands, or environment variables

## Requirements

- macOS 15 or later
- Codex CLI, Claude Code, or both
- Xcode 16 or later only when building from source

## Download and install

1. Download the latest `Agent-Monitor-<version>.dmg` from [GitHub Releases](https://github.com/seschulz/agent-monitor/releases/latest).
2. Open the DMG and drag **Agent Monitor** onto the **Applications** shortcut.
3. In Applications, Control-click **Agent Monitor**, choose **Open**, and confirm. This one-time step is necessary because the free release is ad-hoc signed rather than Apple-notarized.
4. On first launch, choose **Install Integrations**. Agent Monitor safely adds its Codex and Claude Code hooks while preserving existing hooks.

Optionally download the adjacent `.sha256` file and verify the archive before extracting it:

```sh
shasum -a 256 -c Agent-Monitor-<version>.dmg.sha256
```

After setup, run `codex /hooks` in Codex once to review and trust the installed hooks. Then start a new Codex or Claude Code session; it should appear in the Agent Monitor menu and overlay. Integration setup can be repeated or removed later under **Settings → Application**.

### Install from source

Clone the repository and run the local installer:

```sh
git clone https://github.com/seschulz/agent-monitor.git
cd agent-monitor
./scripts/install-local.sh
```

This builds a Release configuration, stops an older running copy, installs the new app in `~/Applications`, merges the hooks, and launches it.

## Using Agent Monitor

The menu-bar icon opens the session list. A rotating blue symbol means a session is working; a green check means its latest turn has finished. The menu-bar icon briefly changes to a check after a completion.

- Click a session to bring its terminal application to the foreground.
- Use the X beside a completed session to dismiss it.
- Use **Clear All** when several completed sessions are visible.
- Drag the floating overlay to place it elsewhere on the desktop.
- Open **Settings** from the menu for launch-at-login, menu density, overlay behavior, retention times, macOS alerts, and finished voice alerts. The spoken completion message can use `{agent}`, `{project}`, `{terminal}`, and `{directory}` placeholders.
- If the menu bar is too crowded to reach the icon, reopen **Agent Monitor** from Spotlight or Finder to bring Settings to the foreground.

Settings are grouped by surface. **Menu Bar** controls the menu opened from the status icon. **Floating Overlay** controls widget visibility, density, and how long completed sessions remain visible. Claude Code speech is triggered only by its `Stop` event.

Agent Monitor uses the open-source Sparkle framework to check GitHub Releases once per day. When a newer version is available, choose **Install Update**, **Remind Me Later**, or **Skip This Version**. You can also check immediately under **Settings → Updates**. Every update archive is verified with Agent Monitor's Ed25519 signing key before installation. The first installation still requires the Control-click step described above, but later updates are installed from inside the app.

## Privacy and local data

Hooks send small lifecycle events to a private Unix socket on your Mac. Agent Monitor records session identifiers, project paths, provider and terminal metadata, timestamps, and status. It deliberately excludes prompts, responses, command contents, and environment variables.

Session data and the socket live under:

```text
~/Library/Application Support/AgentMonitor
```

Use **Settings → Advanced → Clear Session History** to remove saved sessions.

## Troubleshooting

If no sessions appear, confirm that Agent Monitor is running and inspect the helper connection:

```sh
"$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper" doctor
```

You can safely reinstall the hooks from **Settings → General → Agent Integrations** without removing unrelated hooks. The hooks use a stable helper copy under Application Support, so replacing or automatically updating the app cannot interrupt them. From a source checkout, the equivalent command is:

```sh
python3 scripts/configure.py install \
  --helper "$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper"
```

To preview configuration changes first, append `--dry-run`. The first attempt to focus Terminal, iTerm2, or an IDE may cause macOS to request Automation permission. Agent Monitor does not require Screen Recording permission.

Current terminal-focus limitations:

- IntelliJ can be restored and brought forward, but Agent Monitor cannot select an exact embedded terminal tab.
- Ghostty currently supports application activation rather than exact tab selection.
- `tmux` and `screen` can hide the original GUI terminal TTY.

## Uninstall

First choose **Settings → Application → Remove Integrations**. Then quit Agent Monitor and move it from Applications to Trash.

Developers using a source checkout can instead run:

```sh
./scripts/uninstall-local.sh
```

This removes only Agent Monitor’s Codex and Claude Code hook entries and moves the app to Trash. Session history remains in `~/Library/Application Support/AgentMonitor` unless you delete it separately.

## Development

### Project layout

```text
Sources/AgentMonitorApp/       macOS app, menu, overlay, settings, and session store
Sources/AgentMonitorHelper/    hook input decoder and local socket client
Sources/AgentMonitorShared/    shared event and session models
Tests/                         Swift and Python tests
scripts/                       local install, hook configuration, and uninstall tools
.github/workflows/             GitHub Actions release automation
```

The helper receives Codex and Claude Code hook payloads, reduces them to privacy-conscious lifecycle events, and sends them over the local socket. The app owns persistence, process reconciliation, presentation, notifications, speech, and terminal activation.

### Build and run locally

The easiest development loop is:

```sh
./scripts/install-local.sh
```

For a build without installing:

```sh
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -derivedDataPath /tmp/agent-monitor-build \
  build
```

You can also open `AgentMonitor.xcodeproj` in Xcode and run the shared **AgentMonitor** scheme.

### Tests

Run the complete Swift and Python test suite with:

```sh
./scripts/test.sh
```

The hook configurator can be tested or inspected independently:

```sh
python3 -m unittest Tests/configure_test.py
python3 scripts/configure.py install \
  --helper "$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper" \
  --dry-run
```

### Creating a release

The `Build macOS release` workflow supports manual runs from the GitHub **Actions** tab. A manual run creates a downloadable workflow artifact but does not publish a GitHub Release.

To publish a release, push a version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow builds a universal Release app, writes the tag version into its `Info.plist`, applies an ad-hoc signature, verifies the bundle, creates a drag-to-Applications DMG, generates a Sparkle appcast, signs the update with Ed25519, and publishes everything with SHA-256 checksums. Re-running the workflow for an existing tag replaces its attached files.

Sparkle's private Ed25519 key is stored in the repository's `SPARKLE_PRIVATE_KEY` Actions secret and in the maintainer's login Keychain under the `agent-monitor` account. Never commit or regenerate this key: existing installations trust the matching public key embedded in `Info.plist`, so losing it would break automatic updates.

Public distribution without Gatekeeper warnings requires a Developer ID Application certificate and Apple notarization. Those credentials are intentionally not stored in this repository; a future notarized workflow should load them from encrypted GitHub Actions secrets.

### Hook configuration safety

`scripts/configure.py` merges Agent Monitor entries instead of replacing unrelated Codex or Claude hooks. Codex lifecycle hooks track activity, while a completion callback covers Codex desktop sessions. Existing notify commands are safely chained and restored on uninstall. Before writing, the script prints a unified diff and creates timestamped backups.
