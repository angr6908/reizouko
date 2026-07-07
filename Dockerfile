FROM alpine:latest
RUN apk add --no-cache rclone gallery-dl fuse3
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
ENV INTERVAL=6h \
    DATA=/data \
    MOUNT_POINT=/mnt/onedrive \
    REMOTE=onedrive: \
    PIXIV_SUBDIR=Pixiv \
    NAT64_DNS=2a01:4f9:c010:3f02::1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
