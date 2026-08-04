#!/bin/sh
set -u

DATA=/data
MOUNT_POINT=/mnt/onedrive
REMOTE=onedrive:
PIXIV_SUBDIR=Pixiv
BASE="$MOUNT_POINT/$PIXIV_SUBDIR"
REMOTE_BASE="${REMOTE%/}/$PIXIV_SUBDIR"
LOG_FILE="$DATA/logs/reizouko.log"
CRONTAB=/etc/crontabs/root
VFS_CACHE=/tmp/rclone-cache

export RCLONE_CONFIG="$DATA/rclone/rclone.conf"
export GOGC=10
GDL_CONF="$DATA/gallery-dl/gallery-dl.conf"
GDL_CACHE="$DATA/gallery-dl/cache"
ARTIST_LIST="$DATA/gallery-dl/pixiv-artists.txt"
LOCK_DIR="$DATA/reizouko.lock"

NAT64_DNS="${NAT64_DNS:-}"
NAT64_DNS_FALLBACK="${NAT64_DNS_FALLBACK:-}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"

MOUNT_ATTEMPTS=3
MOUNT_RETRY_SLEEP=30
MOUNT_TIMEOUT=30
LIST_ATTEMPTS=5
LIST_RETRY_SLEEP=30
GDL_ATTEMPTS=3
GDL_ATTEMPT_SLEEP=30
GDL_RETRIES=20
GDL_HTTP_TIMEOUT=60
GDL_SLEEP_RETRIES=exp:2:5:120=5
DRAIN_TIMEOUT=600
DRAIN_POLL=5
CYCLE_TIMEOUT=21300
CYCLE_KILL_GRACE=30

ACTIVE_PID=
RCLONE_PID=

configure_dns() {
    [ -n "$NAT64_DNS" ] || return 0
    {
        printf 'nameserver %s\n' "$NAT64_DNS"
        [ -n "$NAT64_DNS_FALLBACK" ] &&
            printf 'nameserver %s\n' "$NAT64_DNS_FALLBACK"
    } > /etc/resolv.conf
    return 0
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -ge "$LOG_MAX_BYTES" ]; then
        : > "$LOG_FILE"
    fi
    return 0
}

spawn_wait() {
    "$@" &
    ACTIVE_PID=$!
    if wait "$ACTIVE_PID"; then
        ACTIVE_PID=
        return 0
    fi
    ACTIVE_PID=
    return 1
}

nap() {
    spawn_wait sleep "$1" || true
}

kill_children() {
    [ -n "$ACTIVE_PID" ] && kill -KILL "$ACTIVE_PID" 2>/dev/null
    [ -n "$RCLONE_PID" ] && kill -KILL "$RCLONE_PID" 2>/dev/null
    return 0
}

reap_children() {
    if [ -n "$ACTIVE_PID" ]; then
        wait "$ACTIVE_PID" 2>/dev/null
        ACTIVE_PID=
    fi
    if [ -n "$RCLONE_PID" ]; then
        wait "$RCLONE_PID" 2>/dev/null
        RCLONE_PID=
    fi
    return 0
}

release_lock() {
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

cleanup() {
    trap - EXIT INT TERM
    kill_children
    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
    reap_children
    release_lock
}

on_signal() {
    echo "==> stopping $(date '+%Y-%m-%d %H:%M:%S'): signal received"
    cleanup
    exit 143
}

lock_holder_alive() {
    holder=$1
    [ -n "$holder" ] || return 1
    [ "$holder" != "$$" ] || return 1
    kill -0 "$holder" 2>/dev/null || return 1
    cmdline=$(tr '\0' ' ' < "/proc/$holder/cmdline" 2>/dev/null) || return 0
    [ -n "$cmdline" ] || return 0
    case "$cmdline" in
        *entrypoint.sh*) return 0 ;;
    esac
    return 1
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if lock_holder_alive "$holder"; then
        echo "==> cycle skipped $(date '+%Y-%m-%d %H:%M:%S'): pid $holder still running"
        return 1
    fi
    echo "==> clearing stale lock left by pid ${holder:-unknown}"
    release_lock
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    echo "==> cycle skipped $(date '+%Y-%m-%d %H:%M:%S'): could not acquire lock" >&2
    return 1
}

start_mount() {
    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
    mkdir -p "$MOUNT_POINT" "$DATA/rclone" "$GDL_CACHE"
    rclone mount "$REMOTE" "$MOUNT_POINT" \
        --cache-dir "$VFS_CACHE" \
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
    while [ "$i" -lt "$MOUNT_TIMEOUT" ]; do
        mountpoint -q "$MOUNT_POINT" && return 0
        kill -0 "$RCLONE_PID" 2>/dev/null || { echo "rclone exited" >&2; return 1; }
        i=$((i + 1))
        nap 1
    done
    echo "mount timeout" >&2
    return 1
}

mount_remote() {
    attempt=1
    while true; do
        start_mount && return 0
        kill_children
        reap_children
        fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
        if [ "$attempt" -ge "$MOUNT_ATTEMPTS" ]; then
            echo "could not mount $REMOTE after $attempt attempts" >&2
            return 1
        fi
        echo "mount failed; retry $attempt/$MOUNT_ATTEMPTS in ${MOUNT_RETRY_SLEEP}s" >&2
        nap "$MOUNT_RETRY_SLEEP"
        attempt=$((attempt + 1))
    done
}

vfs_pending() {
    find "$VFS_CACHE/vfs" -type f 2>/dev/null | grep -q .
}

unmount_remote() {
    waited=0
    while vfs_pending; do
        if [ "$waited" -ge "$DRAIN_TIMEOUT" ]; then
            echo "vfs cache still pending after ${DRAIN_TIMEOUT}s; forcing unmount" >&2
            break
        fi
        [ "$((waited % 60))" -eq 0 ] &&
            echo "waiting for vfs cache to flush (${waited}s elapsed)"
        nap "$DRAIN_POLL"
        waited=$((waited + DRAIN_POLL))
    done
    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
    if [ -n "$RCLONE_PID" ]; then
        wait "$RCLONE_PID" 2>/dev/null || true
        RCLONE_PID=
    fi
}

list_artists() {
    attempt=1
    while true; do
        if spawn_wait rclone lsf "$REMOTE_BASE" --dirs-only \
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
        nap "$LIST_RETRY_SLEEP"
        attempt=$((attempt + 1))
    done
}

download_artist() {
    dir=$1
    id=$2
    attempt=1
    while true; do
        if spawn_wait gallery-dl --config "$GDL_CONF" \
            --cache-file "$GDL_CACHE/cache.sqlite3" \
            --retries "$GDL_RETRIES" --http-timeout "$GDL_HTTP_TIMEOUT" \
            --sleep-retries "$GDL_SLEEP_RETRIES" \
            -D "$dir" -o directory=[] \
            "https://www.pixiv.net/en/users/$id"; then
            return 0
        fi
        if [ "$attempt" -ge "$GDL_ATTEMPTS" ]; then
            echo "gallery-dl failed for ID=$id after $attempt attempts" >&2
            return 1
        fi
        echo "gallery-dl failed for ID=$id; retry $attempt/$GDL_ATTEMPTS in ${GDL_ATTEMPT_SLEEP}s" >&2
        nap "$GDL_ATTEMPT_SLEEP"
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

run_cycle() {
    mkdir -p "$DATA/logs" "$DATA/rclone" "$GDL_CACHE"
    rotate_log
    exec >>"$LOG_FILE" 2>&1
    acquire_lock || return 0
    trap cleanup EXIT
    trap on_signal INT TERM
    echo "==> cycle start $(date '+%Y-%m-%d %H:%M:%S')"
    if mount_remote; then
        download_all
        unmount_remote
    fi
    echo "==> cycle end $(date '+%Y-%m-%d %H:%M:%S')"
}

configure_dns

case "${1:-cron}" in
    cycle)
        run_cycle
        ;;
    cron)
        mkdir -p "$DATA/logs"
        fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
        release_lock
        echo "logging to $LOG_FILE"
        echo "schedule:"
        grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$CRONTAB" | sed 's/^/  /'
        echo "running initial cycle, output goes to $LOG_FILE"
        /bin/busybox timeout -s TERM -k "$CYCLE_KILL_GRACE" "$CYCLE_TIMEOUT" "$0" cycle &
        STARTUP_PID=$!
        trap 'kill -TERM "$STARTUP_PID" 2>/dev/null; wait "$STARTUP_PID" 2>/dev/null; exit 143' INT TERM
        wait "$STARTUP_PID" || true
        trap - INT TERM
        echo "initial cycle done, handing off to crond"
        exec crond -f -d 8
        ;;
    *)
        echo "usage: $0 [cron|cycle]" >&2
        exit 2
        ;;
esac
