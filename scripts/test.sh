#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
PYTHONPYCACHEPREFIX=/tmp/agent-monitor-pycache python3 -m unittest "$repository_dir/Tests/configure_test.py"
xcodebuild -project "$repository_dir/AgentMonitor.xcodeproj" -scheme AgentMonitor -derivedDataPath /tmp/agent-monitor-derived test
AGENT_MONITOR_TEST_HELPER="/tmp/agent-monitor-derived/Build/Products/Debug/agent-monitor-helper" \
    PYTHONPYCACHEPREFIX=/tmp/agent-monitor-pycache python3 -m unittest "$repository_dir/Tests/helper_process_test.py"
