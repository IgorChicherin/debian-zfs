#!/bin/bash
###############################################################################
# zfs-launcher.sh — Pre-launch configuration for Calamares ZFS installer
# Uses zenity for GUI dialogs before launching Calamares
###############################################################################
set -euo pipefail

CONFIG_FILE="/tmp/zfs-install-config.json"

cleanup() {
    rm -f "$CONFIG_FILE"
}
trap cleanup EXIT

# Select disk
DISK=$(lsblk -ndo NAME,SIZE,TYPE,MODEL | grep " disk " | while read name size _ rest; do
    echo "$name|/dev/$name ($size) $rest"
done | zenity --list --title="Debian ZFS Installer" \
    --text="Select target disk for installation.\nALL DATA on this disk will be DESTROYED!" \
    --column="Device" --column="Description" \
    --width=600 --height=300 \
    --print-column=1)

if [ -z "$DISK" ]; then
    echo "No disk selected, aborting."
    exit 1
fi

DISK="/dev/$DISK"

if ! zenity --question --title="Confirm disk" \
    --text="Target: $DISK\n\nAll existing data on $DISK will be PERMANENTLY DESTROYED.\n\nContinue?" \
    --width=400; then
    exit 1
fi

# Pool name
POOL=$(zenity --entry --title="ZFS Pool Name" \
    --text="Enter ZFS pool name:" \
    --entry-text="rpool" --width=400)
POOL="${POOL:-rpool}"

# Encryption
ENCRYPTION="none"
PASSPHRASE=""
if zenity --question --title="ZFS Encryption" \
    --text="Enable ZFS native encryption (aes-256-gcm)?" \
    --width=400; then
    ENCRYPTION="passphrase"
    while true; do
        PASSPHRASE=$(zenity --password --title="Encryption Passphrase" \
            --text="Enter passphrase for ZFS encryption:" --width=400)
        PASSPHRASE2=$(zenity --password --title="Verify Passphrase" \
            --text="Confirm passphrase:" --width=400)
        if [ "$PASSPHRASE" = "$PASSPHRASE2" ] && [ -n "$PASSPHRASE" ]; then
            break
        fi
        zenity --error --text="Passphrases do not match or empty. Try again."
    done
fi

# Hostname
HOSTNAME=$(zenity --entry --title="System Hostname" \
    --text="Enter hostname for the new system:" \
    --entry-text="debian-zfs" --width=400)
HOSTNAME="${HOSTNAME:-debian-zfs}"

# Username and user password
USERNAME=""
USER_PASSWORD=""
USER_FULLNAME=""
if zenity --question --title="Create User" \
    --text="Create a regular user account?" \
    --width=400; then
    USERNAME=$(zenity --entry --title="Username" \
        --text="Enter username:" --entry-text="user" --width=400)
    USERNAME="${USERNAME:-user}"
    USER_FULLNAME=$(zenity --entry --title="Full Name" \
        --text="Enter full name for the user:" \
        --entry-text="" --width=400)
    while true; do
        USER_PASSWORD=$(zenity --password --title="User Password" \
            --text="Enter password for user $USERNAME:" --width=400)
        USER_PASSWORD2=$(zenity --password --title="Verify Password" \
            --text="Confirm password:" --width=400)
        if [ "$USER_PASSWORD" = "$USER_PASSWORD2" ] && [ -n "$USER_PASSWORD" ]; then
            break
        fi
        zenity --error --text="Passwords do not match or empty. Try again."
    done
fi

# Root password
ROOT_PASSWORD=""
while true; do
    ROOT_PASSWORD=$(zenity --password --title="Root Password" \
        --text="Enter root password:" --width=400)
    ROOT_PASSWORD2=$(zenity --password --title="Verify Root Password" \
        --text="Confirm root password:" --width=400)
    if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD2" ] && [ -n "$ROOT_PASSWORD" ]; then
        break
    fi
    zenity --error --text="Passwords do not match or empty. Try again."
done

# Write config JSON (env vars avoid shell quoting issues)
export CONFIG_FILE DISK POOL ENCRYPTION HOSTNAME USERNAME USER_FULLNAME USER_PASSWORD ROOT_PASSWORD
python3 -c "
import os, json
cfg = {
    'disk': os.environ['DISK'],
    'pool': os.environ['POOL'],
    'encryption': os.environ['ENCRYPTION'],
    'passphrase': open('/dev/stdin').read().strip(),
    'efi_size': '1G',
    'hostname': os.environ['HOSTNAME'],
    'username': os.environ['USERNAME'],
    'user_fullname': os.environ['USER_FULLNAME'],
    'user_password': os.environ['USER_PASSWORD'],
    'root_password': os.environ['ROOT_PASSWORD'],
}
with open(os.environ['CONFIG_FILE'], 'w') as f:
    json.dump(cfg, f, indent=2)
" <<< "$PASSPHRASE"

chmod 600 "$CONFIG_FILE"

# Summary
SUMMARY="Disk: $DISK\nPool: $POOL\nEncryption: $ENCRYPTION\nHostname: $HOSTNAME\nUser: ${USERNAME:-none}\n"
if ! zenity --question --title="Confirm Configuration" \
    --text="Review your settings:\n\n$SUMMARY\n\nStart installation?" \
    --width=400; then
    exit 1
fi

# Launch Calamares
zenity --info --title="Starting Installer" \
    --text="Calamares installer will now start.\nComplete the Calamares steps, then installation will begin." \
    --width=400

exec calamares -d
