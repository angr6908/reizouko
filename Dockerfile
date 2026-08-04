FROM alpine:latest
RUN apk add --no-cache rclone gallery-dl fuse3
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
ENV INTERVAL=6h \
    DATA=/data \
    MOUNT_POINT=/mnt/onedrive \
    REMOTE=onedrive: \
    PIXIV_SUBDIR=Pixiv \
    GDL_RETRIES=20 \
    GDL_HTTP_TIMEOUT=60 \
    GDL_RETRY_SLEEP=exp=2:5:120 \
    GDL_ATTEMPTS=3 \
    GDL_ATTEMPT_SLEEP=30 \
    LIST_ATTEMPTS=5 \
    LIST_RETRY_SLEEP=30 \
    NAT64_DNS=2a01:4f9:c010:3f02::1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
