#!/bin/bash

# Source the main libnetwatch script
source "$HOME/netwatch/bin/netwatch.sh"

# Load configuration
load_conf

# Call the monitor disk usage function
monitor_disk_usage

exit 0
