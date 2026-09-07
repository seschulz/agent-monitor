# Contributing to Agent Monitor

Thanks for helping improve the app. This guide gets you from a fresh clone to a tested change without requiring a release build or modifying your agent configuration first.

[← Project overview](README.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Release guide](docs/RELEASING.md)

## Set up your Mac

- **macOS 15 or later**
- **Xcode 16 or later**, including its command-line tools, with Swift 6 support
- **Python 3** for hook configuration and its tests
- **Codex CLI or Claude Code** for live integration checks; neither is needed for the unit tests

Make sure `xcode-select -p` points to the Xcode installation you intend to use. Swift Package Manager resolves the Sparkle dependency on the first build.

```sh
git clone https://github.com/seschulz/agent-monitor.git
cd agent-monitor
swift build
swift test
python3 -m unittest Tests/configure_test.py
```

These commands build the package and run its tests without installing hooks or replacing the installed app.

## Choose your development loop

### Work in Xcode

Open `AgentMonitor.xcodeproj` and select the shared **AgentMonitor** scheme. Quit an already-running Agent Monitor before running a development copy: both use the same local socket and session-data directory.

For a Debug build without installation:

```sh
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -derivedDataPath /tmp/agent-monitor-build \
  build
```

### Test the installed app

```sh
./scripts/install-local.sh
```

The installer builds a Release app, stops a running copy, installs it in `~/Applications/Agent Monitor.app`, updates the stable helper, merges the agent hooks, and launches the app. It uses the latest local release tag for the app version; set `AGENT_MONITOR_VERSION` if you need an explicit local version.

Start new agent sessions after changing hooks so they load the updated configuration. For Codex, review added hooks through `/hooks` when prompted.

> Local builds are ad-hoc signed. Rebuilding can invalidate an existing Accessibility grant. If IntelliJ/Rider tab selection stops working, refresh the installed app's entry in **System Settings → Privacy & Security → Accessibility**. Monitoring and application activation continue without that access.

## Follow an event through the project

```text
Codex / Claude Code lifecycle hook
                │
                ▼
      agent-monitor-helper
       Decode → validate → send
                │
         private Unix socket
                │
                ▼
         Agent Monitor app
    Session state → widget / menu
                 → notifications / speech
```

Codex desktop lifecycle events also enter through the app's desktop-session watcher. Event ordering matters: an unrelated tool finishing must not clear a pending question, and completion must not override an unanswered input request.

| Area | Start here |
| --- | --- |
| Lifecycle decoding and host detection | [`Sources/AgentMonitorHelper/`](Sources/AgentMonitorHelper/) |
| Shared wire format and session records | [`MonitorModels.swift`](Sources/AgentMonitorShared/MonitorModels.swift) |
| State transitions, alert preferences, speech | [`SessionStore.swift`](Sources/AgentMonitorApp/SessionStore.swift) |
| Settings, session rows, and presentation | [`SessionViews.swift`](Sources/AgentMonitorApp/SessionViews.swift) |
| Runtime, reconciliation, desktop monitoring | [`MonitorRuntime.swift`](Sources/AgentMonitorApp/MonitorRuntime.swift) |
| Terminal activation and JetBrains navigation | [`TerminalFocusService.swift`](Sources/AgentMonitorApp/TerminalFocusService.swift), [`JetBrainsTerminalFocus.swift`](Sources/AgentMonitorApp/JetBrainsTerminalFocus.swift) |
| Native hook installer | [`HookConfigurationService.swift`](Sources/AgentMonitorApp/HookConfigurationService.swift) |
| Command-line hook installer | [`scripts/configure.py`](scripts/configure.py) |
| Swift and Python tests | [`Tests/`](Tests/) |
| Release packaging and publishing | [`.github/workflows/release.yml`](.github/workflows/release.yml) |

## Test your change

For Swift package tests and hook-configuration tests:

```sh
swift test
python3 -m unittest Tests/configure_test.py
```

For the Xcode test suite plus the Python tests:

```sh
./scripts/test.sh
```

The Xcode suite includes an app-hosted test target and needs an environment that can launch the app. If a headless runner fails at app launch, use the SwiftPM commands to check the code separately and report the Xcode launch limitation.

For lifecycle, alert, or integration changes, also exercise the relevant flow with **both agents** in a scratch project. Check running → waiting → resumed → finished, duplicate events, overlapping input/completion events, and muted behavior. Permission alerts default to Codex off and Claude Code on; account for that when testing manual approval flows. Restore any preferences you change and close test sessions afterward.

## Change hooks carefully

The native and Python installers should agree on events and matchers. Keep their tests in sync when adding a hook.

Preview the command-line installer's changes without writing them:

```sh
python3 scripts/configure.py install \
  --helper "$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper" \
  --dry-run
```

The configurator merges Agent Monitor entries, preserves unrelated hooks, prints a diff, and creates timestamped backups before writes. Existing Codex notification commands are chained and restored when integrations are removed.

Preserve the metadata-only event boundary: monitor events must not contain prompts, responses, command contents, questions, tool arguments, or environment variables. Use synthetic paths and content in fixtures, screenshots, and bug reports.

## Send a useful contribution

- For a bug, include the macOS version, agent version, terminal host, and steps to reproduce. Redact private paths and content.
- For a feature or substantial behavior change, an issue explaining the use case helps align the scope.
- Keep pull requests focused. Explain the resulting behavior, include relevant test results, and add screenshots for UI changes.
- When adding a Swift source file, check both `Package.swift` and the Xcode project's target membership; the two build paths should stay usable.

Publishing an app update is separate from contributing code. See [Releasing](docs/RELEASING.md) for the maintainer workflow.
