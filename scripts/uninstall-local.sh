#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
destination="$HOME/Applications/Agent Monitor.app"

if pgrep -x "Agent Monitor" >/dev/null 2>&1; then
    print "Stopping Agent Monitor…"
    pkill -TERM -x "Agent Monitor" || true
    for _ in {1..30}; do
        if ! pgrep -x "Agent Monitor" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
fi

python3 "$repository_dir/scripts/configure.py" uninstall
mkdir -p "$HOME/.Trash"
if [[ -d "$destination" ]]; then
    mv "$destination" "$HOME/.Trash/Agent Monitor-$(date +%s).app"
fi
print "Removed Agent Monitor. Its session history remains in ~/Library/Application Support/AgentMonitor."
