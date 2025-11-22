#!/bin/bash

# Source the main libnetwatch script
source "$HOME/netwatch/bin/netwatch.sh"

# Load configuration
load_conf

# Call the monitor memory usage function
monitor_memory_usage

exit 0

