#!/bin/sh
set -u

INTERVAL="${INTERVAL:-6h}"
DATA="${DATA:-/data}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/onedrive}"
REMOTE="${REMOTE:-onedrive:}"
PIXIV_SUBDIR="${PIXIV_SUBDIR:-Pixiv}"
BASE="$MOUNT_POINT/$PIXIV_SUBDIR"
REMOTE_BASE="${REMOTE%/}/$PIXIV_SUBDIR"
NAT64_DNS="${NAT64_DNS:-}"
LOG_FILE="$DATA/logs/reizouko.log"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"
GDL_RETRIES="${GDL_RETRIES:-20}"
GDL_HTTP_TIMEOUT="${GDL_HTTP_TIMEOUT:-60}"
GDL_RETRY_SLEEP="${GDL_RETRY_SLEEP:-exp=2:5:120}"
GDL_ATTEMPTS="${GDL_ATTEMPTS:-3}"
GDL_ATTEMPT_SLEEP="${GDL_ATTEMPT_SLEEP:-30}"
LIST_ATTEMPTS="${LIST_ATTEMPTS:-5}"
LIST_RETRY_SLEEP="${LIST_RETRY_SLEEP:-30}"

export RCLONE_CONFIG="$DATA/rclone/rclone.conf"
export GOGC=10
GDL_CONF="$DATA/gallery-dl/gallery-dl.conf"
GDL_CACHE="$DATA/gallery-dl/cache"
ARTIST_LIST="$DATA/gallery-dl/pixiv-artists.txt"

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
        --low-level-retries 20 \
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

list_artists() {
    attempt=1
    while true; do
        if rclone lsf "$REMOTE_BASE" --dirs-only \
            --retries 3 --low-level-retries 20 > "$ARTIST_LIST.tmp"; then
            mv "$ARTIST_LIST.tmp" "$ARTIST_LIST"
            return 0
        fi
        rm -f "$ARTIST_LIST.tmp"
        if [ "$attempt" -ge "$LIST_ATTEMPTS" ]; then
            echo "could not list $REMOTE_BASE after $attempt attempts" >&2
            return 1
        fi
        echo "could not list $REMOTE_BASE; retry $attempt/$LIST_ATTEMPTS in ${LIST_RETRY_SLEEP}s" >&2
        sleep "$LIST_RETRY_SLEEP"
        attempt=$((attempt + 1))
    done
}

download_artist() {
    dir=$1
    id=$2
    attempt=1
    while true; do
        gallery-dl --config "$GDL_CONF" --cache-file "$GDL_CACHE/cache.sqlite3" \
            --retries "$GDL_RETRIES" --http-timeout "$GDL_HTTP_TIMEOUT" \
            --sleep-retries "$GDL_RETRY_SLEEP" \
            -D "$dir" -o directory=[] \
            "https://www.pixiv.net/en/users/$id" && return 0
        if [ "$attempt" -ge "$GDL_ATTEMPTS" ]; then
            echo "gallery-dl failed for ID=$id after $attempt attempts" >&2
            return 1
        fi
        echo "gallery-dl failed for ID=$id; retry $attempt/$GDL_ATTEMPTS in ${GDL_ATTEMPT_SLEEP}s" >&2
        sleep "$GDL_ATTEMPT_SLEEP"
        attempt=$((attempt + 1))
    done
}

download_all() {
    list_artists || return 1
    while IFS= read -r listed_name; do
        name=${listed_name%/}
        case "$name" in
            [0-9]*)
                id=${name%%[!0-9]*}
                echo "==> [$name] ID=$id"
                download_artist "$BASE/$name/" "$id" ;;
            '') ;;
            *) echo "skip [$name]" ;;
        esac
    done < "$ARTIST_LIST"
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
