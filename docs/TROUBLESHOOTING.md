# Troubleshooting & setup details

[← Project overview](../README.md) · [Contributor guide](../CONTRIBUTING.md)

## macOS blocks the first launch

Current releases are ad-hoc signed rather than signed with an Apple Developer ID and notarized.

After trying to open the downloaded app, go to **System Settings → Privacy & Security**, find the blocked-app notice, and choose **Open Anyway** for **Agent Monitor**. Confirm the subsequent Open dialog. Depending on your macOS version, Control-clicking the app in Finder and choosing **Open** may also offer the confirmation.

This is a first-installation step. Later updates can be installed inside Agent Monitor. The updater verifies their Ed25519 signature before installation.

### Verify a download

Download both the `.dmg` and its matching `.dmg.sha256` asset from the same [GitHub Release](https://github.com/seschulz/agent-monitor/releases/latest). In the folder containing those files, run:

```sh
shasum -a 256 -c Agent-Monitor-*.dmg.sha256
```

The matching DMG should report `OK`.

## No sessions appear

1. Confirm that Agent Monitor is running. Open it again from Spotlight or Finder if you can't reach its menu-bar icon.
2. Check **Settings → Integrations → Agent Integrations**. Install the hooks if they aren't installed.
3. Start a **new** Codex or Claude Code session after installation or a hook update. Existing processes may still have their old hook configuration.
4. In Codex, use `/hooks` to review and trust newly added hooks when prompted.
5. Check the helper connection:

```sh
"$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper" doctor
```

If you need to reconfigure the hooks from a source checkout:

```sh
python3 scripts/configure.py install \
  --helper "$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper"
```

Append `--dry-run` to inspect changes first. The installer preserves unrelated hooks. It uses a stable helper path under Application Support so app replacement doesn't leave hooks pointing at a missing bundle executable.

Hook coverage depends on the agent version and tool path. The monitor uses explicit lifecycle signals rather than guessing from inactivity or assistant text. Ordinary Claude Code idle reminders are ignored.

## Permission alerts are quiet—or too noisy

Open **Settings → Alerts & Voice → Permission**.

- **Codex permission alerts default off.** This avoids interruptions when another agent automatically reviews approvals. Enable them for manual approval workflows if desired.
- **Claude Code permission alerts default on.** You can turn them off independently.
- Turning an agent's permission alerts off suppresses the corresponding speech, macOS notifications, and attention indicators. It also clears existing permission indicators for that agent.
- **Needs input** is separate: questions that require your answer still follow their own alert settings.

For speech, turn on **Enable spoken alerts** and **Speak this alert** for the selected trigger. For system notifications, enable **Show a macOS notification** and allow Agent Monitor notifications in macOS settings when asked.

Repeated reminders should not announce the same wait again. A pending question takes priority over an overlapping finish event; completion is announced after an answer and a subsequent finish event.

## Terminal navigation

Clicking a session brings its terminal host application forward. Some hosts can also select a specific terminal tab.

### IntelliJ IDEA and Rider

Project-window selection is separate from terminal-tab selection. When the recorded terminal shell is still running and its working directory is inside a project with an `.idea` directory, clicking a session asks the IDE's launcher to bring that project forward. This works with terminal-tab switching disabled and does not require Accessibility access. If the project cannot be identified, the monitor activates the IDE instead.

Exact tab selection works without an IDE plugin when:

1. **Settings → Integrations → Terminal Navigation → Switch to the agent’s IDE terminal tab** is enabled.
2. Agent Monitor has **Accessibility** access in macOS settings.
3. The agent session was started with integrations that record the terminal device and shell identity.

Agent Monitor briefly applies a unique terminal-title marker, finds the matching tab, restores its original title, and selects it. This can distinguish tabs with identical displayed names. It does not type commands into the terminal or read terminal output.

If a custom tab name, shell prompt, or unsupported terminal engine prevents identification, the monitor tries a remembered unique association. Otherwise, it brings the IDE forward. There is no linking dialog, and clicking a session doesn't repeatedly ask for Accessibility access.

The title probe verifies that the original shell is still alive in the recorded IDE instance. Closed shells and reused process IDs are rejected. Older sessions without shell metadata can use a remembered unique association; otherwise, the IDE is simply activated.

After a local ad-hoc rebuild, macOS may invalidate an existing Accessibility grant. Check the status in Terminal Navigation and refresh the **installed Agent Monitor app's** entry under **System Settings → Privacy & Security → Accessibility**.

### VS Code, forks, and other terminals

- **VS Code and compatible desktop forks:** clicking a session opens the editor; exact terminal-tab selection is not supported. No editor extension is needed.
- **Ghostty:** application activation, rather than exact tab selection.
- **Terminal and iTerm2:** macOS may request Automation access when the app first tries to focus them.
- **tmux and screen:** multiplexers can hide the original GUI terminal TTY, limiting terminal matching.

Accessibility is optional for monitoring and application activation. Agent Monitor does not require Screen Recording permission.

## Updates

The Sparkle updater checks GitHub Releases automatically, normally once per day. Use **Settings → General → Software Updates → Check for Updates…** to check immediately.

When offered an update, choose **Install Update**, **Remind Me Later**, or **Skip This Version**. Update archives are verified with Agent Monitor's Ed25519 public key before installation. The initial macOS trust step and the update signature check are separate mechanisms.

## Local data

The app's session data, diagnostics when enabled, stable helper, and event socket live under:

```text
~/Library/Application Support/AgentMonitor
```

Stored lifecycle data contains identifiers, project paths, provider and terminal metadata, timestamps, and state. It excludes prompts, responses, command contents, questions, tool arguments, and environment variables.

Clear saved sessions with **Settings → General → Session Data → Clear Session History**. Use **Open Data Folder** in the same section to inspect local files. Redact private paths before sharing diagnostics in an issue.

## Uninstall

1. Choose **Settings → Integrations → Agent Integrations → Remove Hooks**.
2. Quit Agent Monitor.
3. Move the installed app from Applications to Trash.

If you installed with the local development script, you can instead run this from the checkout:

```sh
./scripts/uninstall-local.sh
```

The script removes Agent Monitor's hook entries and stable helper, and moves the app from `~/Applications` to Trash. Unrelated hooks are preserved. Session history remains under Application Support unless you clear or remove it separately.

Still stuck? [Open an issue](https://github.com/seschulz/agent-monitor/issues) with your macOS version, agent version, terminal host, and reproduction steps.
