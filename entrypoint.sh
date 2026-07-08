#!/bin/sh
set -u

INTERVAL="${INTERVAL:-6h}"
DATA="${DATA:-/data}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/onedrive}"
REMOTE="${REMOTE:-onedrive:}"
BASE="$MOUNT_POINT/${PIXIV_SUBDIR:-Pixiv}"
NAT64_DNS="${NAT64_DNS:-}"
LOG_FILE="$DATA/logs/reizouko.log"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"

export RCLONE_CONFIG="$DATA/rclone/rclone.conf"
export GOGC=10
GDL_CONF="$DATA/gallery-dl/gallery-dl.conf"
GDL_CACHE="$DATA/gallery-dl/cache"

[ -n "$NAT64_DNS" ] && printf 'nameserver %s\n' "$NAT64_DNS" > /etc/resolv.conf

trap 'fusermount3 -uz "$MOUNT_POINT" 2>/dev/null; exit 0' INT TERM

rotate_log() {
    [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -ge "$LOG_MAX_BYTES" ] && : > "$LOG_FILE"
}

mount_remote() {
    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
    mkdir -p "$MOUNT_POINT" "$DATA/rclone" "$GDL_CACHE"
    rclone mount "$REMOTE" "$MOUNT_POINT" \
        --cache-dir /tmp/rclone-cache \
        --allow-other --allow-non-empty \
        --vfs-cache-mode writes \
        --vfs-cache-poll-interval 3s \
        --vfs-cache-max-age 3s \
        --dir-cache-time 10m \
        --log-level ERROR --stats 0 \
        --use-mmap --buffer-size 0 &
    RCLONE_PID=$!
    i=0
    while [ "$i" -lt 30 ]; do
        mountpoint -q "$MOUNT_POINT" && return 0
        kill -0 "$RCLONE_PID" 2>/dev/null || { echo "rclone exited" >&2; return 1; }
        i=$((i + 1)); sleep 1
    done
    echo "mount timeout" >&2; return 1
}

unmount_remote() {
    while find /tmp/rclone-cache/vfs -type f 2>/dev/null | grep -q .; do sleep 5; done
    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
    wait "$RCLONE_PID" 2>/dev/null || true
}

download_all() {
    [ -d "$BASE" ] || { echo "no $BASE"; return; }
    for dir in "$BASE"/*/; do
        [ -d "$dir" ] || continue
        name=${dir%/}; name=${name##*/}
        case "$name" in
            [0-9]*)
                id=${name%%[!0-9]*}
                echo "==> [$name] ID=$id"
                gallery-dl --config "$GDL_CONF" --cache-file "$GDL_CACHE/cache.sqlite3" \
                    -D "$dir" -o directory=[] \
                    "https://www.pixiv.net/en/users/$id" ;;
            *) echo "skip [$name]" ;;
        esac
    done
}

mkdir -p "$DATA/logs"
echo "logging to $LOG_FILE"

while true; do
    rotate_log
    exec >>"$LOG_FILE" 2>&1
    echo "==> cycle start $(date '+%Y-%m-%d %H:%M:%S')"
    if mount_remote; then
        download_all
        unmount_remote
    fi
    sleep "$INTERVAL"
done
