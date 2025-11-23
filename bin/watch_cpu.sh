#!/bin/bash

# Debug: Print message
echo "Starting CPU monitor..."

# Source the main libnetwatch script
source "$HOME/netwatch/bin/netwatch.sh"

# Debug: Confirm sourcing
echo "Sourcing netwatch.sh from: $HOME/netwatch/bin/netwatch.sh"

# Load configuration
load_conf

# Call the monitor CPU usage function
echo "Calling monitor_cpu_usage..."
monitor_cpu_usage
echo "Finished calling monitor_cpu_usage"

exit 0


