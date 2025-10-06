#!/usr/bin/env bash

set -e

log() {
    echo "[nfs-server] $1"
}

# Mount device if specified
if [ -n "$DEVICE_PATH" ]; then
    log "DEVICE_PATH specified: $DEVICE_PATH"
    if [ -n "$DEVICE_PASSWORD" ]; then
        log "Decrypting device $DEVICE_PATH with cryptsetup."

        # Handle mapper
        if cryptsetup status drive >/dev/null 2>&1; then
            cryptsetup luksClose drive
        fi

        # Decrypt drive
        echo -n "$DEVICE_PASSWORD" | cryptsetup luksOpen "$DEVICE_PATH" drive --key-file=/dev/stdin
        MOUNT_DEVICE="/dev/mapper/drive"
        log "Device decrypted and available at $MOUNT_DEVICE."
    else
        MOUNT_DEVICE="$DEVICE_PATH"
        log "Mounting device $MOUNT_DEVICE directly."
    fi
    # Mount to $SHARED_DIRECTORY
    mkdir -p "$SHARED_DIRECTORY"
    log "Mounting $MOUNT_DEVICE to $SHARED_DIRECTORY."
    mount "$MOUNT_DEVICE" "$SHARED_DIRECTORY"
    log "Mount successful."
else
    log "No DEVICE_PATH specified. Skipping device mount."
fi

log "Starting NFS service."
# Start the mountd service in foreground
exec /usr/bin/nfsd.sh
