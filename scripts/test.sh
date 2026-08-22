#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
PYTHONPYCACHEPREFIX=/tmp/agent-monitor-pycache python3 -m unittest "$repository_dir/Tests/configure_test.py"
xcodebuild -project "$repository_dir/AgentMonitor.xcodeproj" -scheme AgentMonitor -derivedDataPath /tmp/agent-monitor-derived test
