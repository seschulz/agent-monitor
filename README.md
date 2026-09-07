# Agent Monitor

Agent Monitor is a native macOS menu-bar app for keeping track of local [Codex CLI](https://developers.openai.com/codex/cli/) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. It is especially useful when several agents are running in different projects or terminal windows.

The app shows which project and agent are active, how long each session has been running, and which terminal hosts it. When a turn finishes, Agent Monitor can show a floating overlay, post a macOS notification, or announce the result aloud. Clicking a session returns you to its terminal application.

## Highlights

- Monitors Codex CLI and Claude Code from the same menu-bar app
- Shows the project, agent, terminal, state, and elapsed runtime
- Offers movable floating widgets in Compact, Standard, and Spacious layouts
- Lets you tune the widget background style, color, opacity, and text contrast
- Keeps completed sessions visible for a configurable period
- Supports dismissing one completed session or clearing all of them
- Can launch automatically at login
- Uses Sparkle to check, verify, and install GitHub Releases automatically or on demand
- Provides optional macOS notifications and spoken attention and completion alerts
- Recognizes Terminal, iTerm2, Ghostty, IntelliJ IDEA, Rider, and other macOS terminal hosts when their application metadata is available
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
- Open **Settings** from the menu. **General** contains startup, updates, and local history; **Integrations** contains agent hooks and terminal navigation; **Alerts & Voice** contains per-trigger delivery and messages; **Appearance** contains menu-bar and widget options.
- If the menu bar is too crowded to reach the icon, reopen **Agent Monitor** from Spotlight or Finder to bring Settings to the foreground.

**Appearance** groups the menu-bar and floating-widget controls, including visibility, density, and how long completed sessions remain visible. Claude Code completion alerts are triggered by its `Stop` event.

### Needs attention

When Codex or Claude Code asks for permission or explicitly requests input, the session turns amber and moves above running sessions. Waiting sessions stay in the widget until work resumes, the session ends, or you dismiss them. The menu-bar icon also stays amber while a visible session needs attention.

Under **Settings → Alerts & Voice → Permission**, control permission alerts independently for **Codex** (off by default) and **Claude Code** (on by default). Turning an agent off suppresses permission speech, macOS notifications, and attention indicators, including existing permission indicators. Questions that need your input and completion alerts still follow their usual settings. The separate agent defaults replace the earlier global permission switch; subsequent per-agent choices are preserved.

- Permission hooks show **Waiting for permission**.
- Codex's `request_user_input` and Claude Code's `AskUserQuestion` show **Waiting for input**.
- Answering the prompt returns the session to running; completion clears the waiting state. Repeated reminders do not send duplicate alerts, and a matching tool-call ID prevents unrelated parallel tools from clearing a pending question.
- Under **Settings → Alerts & Voice**, select **Finished**, **Needs input**, or **Permission** to configure macOS notifications and speech independently for each trigger. All three have editable spoken messages with `{agent}`, `{project}`, `{terminal}`, and `{directory}` placeholders, a live text preview for either agent, voice playback, and a reset button. Blank messages use the selected trigger’s default. Existing voice, completion message, and delivery preferences are preserved. Pending questions take priority over overlapping finish events; completion is announced after the answer and a subsequent finish event.

Start new CLI sessions after updating so they load the new hooks. Codex may ask you to review the added hooks. Detection uses explicit agent signals, not inactivity or guesses from an agent's response. Claude's ordinary idle reminders are ignored. Hook support depends on the agent version and tool path; prompt text, questions, commands, and tool arguments are not included in monitor events.

### JetBrains terminal tabs

Agent Monitor can identify and select IntelliJ IDEA and Rider terminal tabs automatically without an IDE plugin:

1. In **Settings → General → Terminal Navigation**, enable **Switch to the agent’s IDE terminal tab**. Grant Accessibility access using the settings button if you want exact tab selection.
2. Start an agent after installing the updated integrations, so its hook records the real terminal device and shell identity.
3. Click the agent session in the widget or menu. Agent Monitor briefly applies a unique terminal-title marker, identifies the corresponding tab, restores its original title, and selects it. It does not type commands into the terminal.

The toggle is enabled by default to preserve existing tab-switching behavior. Turn it off to open the IDE without selecting a terminal tab. Missing Accessibility permission also falls back to opening the IDE; session clicks never show a permission prompt. Agent monitoring does not require this permission.

New agent sessions in fresh terminal tabs are identified automatically when the IDE honors terminal-title control sequences. This also distinguishes tabs with identical displayed names. If a custom tab name, an idle shell prompt, or an unsupported terminal engine prevents identification, Agent Monitor uses a previously remembered unique tab when available. Otherwise it simply brings the IDE forward, without a linking dialog. Automatic identification was verified with a foreground process running, as it is while an agent is active.

Local ad-hoc-signed rebuilds can invalidate macOS's Accessibility approval. If exact tab selection stops working after installing a rebuilt app, check its permission status under Terminal Navigation and refresh the installed app’s entry in Accessibility settings.

The IntelliJ/Rider title probe verifies that the original shell is still alive inside the recorded IDE instance before writing to its terminal device. Closed shells and reused process IDs are rejected. Older sessions without shell metadata use an existing unique association when available; otherwise only the IDE is brought forward. Agent Monitor reads window and tab labels, not terminal output.

### VS Code and compatible forks

Clicking a session opens its editor. Exact terminal-tab switching is not supported for VS Code or its forks, and opening the editor does not require Accessibility access. Desktop forks are recognized from their application bundle and shared workbench layout.

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

- Exact IntelliJ IDEA and Rider tab selection requires the Terminal Navigation toggle and Accessibility access. If automatic selection is unavailable and no remembered unique tab can be found, only the IDE is brought forward; see **JetBrains terminal tabs** above.
- VS Code, its forks, and Ghostty support application activation rather than exact tab selection.
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
