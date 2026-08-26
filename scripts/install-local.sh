#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
build_dir="$repository_dir/build"
build_product="$build_dir/Build/Products/Release/Agent Monitor.app"
destination="$HOME/Applications/Agent Monitor.app"
stable_helper="$HOME/Library/Application Support/AgentMonitor/bin/agent-monitor-helper"

xcodebuild -project "$repository_dir/AgentMonitor.xcodeproj" -scheme AgentMonitor -configuration Release -derivedDataPath "$build_dir" build
mkdir -p "$HOME/Applications"

if pgrep -x "Agent Monitor" >/dev/null 2>&1; then
    print "Stopping the currently running Agent Monitor…"
    pkill -TERM -x "Agent Monitor" || true
    for _ in {1..30}; do
        if ! pgrep -x "Agent Monitor" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
fi
if [[ -d "$destination" ]]; then
    rm -rf "$destination"
fi

ditto "$build_product" "$destination"
mkdir -p "${stable_helper:h}"
staged_helper="$stable_helper.installing-$$"
ditto "$destination/Contents/MacOS/agent-monitor-helper" "$staged_helper"
chmod 755 "$staged_helper"
mv -f "$staged_helper" "$stable_helper"
python3 "$repository_dir/scripts/configure.py" install --helper "$stable_helper"
open -n "$destination"
print "Installed and launched Agent Monitor from $destination"
