FROM alpine:latest
RUN apk add --no-cache rclone gallery-dl fuse3
COPY entrypoint.sh /usr/local/bin/
RUN printf '%s\n' '0 */6 * * * /bin/busybox timeout -s TERM -k 30 21300 /usr/local/bin/entrypoint.sh cycle' > /etc/crontabs/root \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && chmod 0600 /etc/crontabs/root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
