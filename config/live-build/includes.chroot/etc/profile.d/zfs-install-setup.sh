#!/bin/bash
# Auto-setup installation scripts in Live environment
if [ -f /etc/install/auto-setup.sh ]; then
    bash /etc/install/auto-setup.sh
fi
