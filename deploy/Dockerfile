# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:13-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
ARG CADDY_IMAGE=caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d

FROM ${DEBIAN_IMAGE} AS builder
RUN --mount=type=secret,id=proxy_ca \
    set -eu; \
    if [ -s /run/secrets/proxy_ca ]; then \
      printf 'Acquire::https::CaInfo "/run/secrets/proxy_ca";\n' > /tmp/apt-build-ca.conf; \
      export APT_CONFIG=/tmp/apt-build-ca.conf; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3 libstdc++6 libfontconfig1 ca-certificates; \
    rm -rf /var/lib/apt/lists/* /tmp/apt-build-ca.conf
COPY tools/build_server_bundle.py /src/tools/build_server_bundle.py
COPY src/ /src/
RUN python3 /src/tools/build_server_bundle.py --source /src --output /bundle --app-only
COPY runtime/godot /usr/local/bin/godot
RUN printf '8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e  /usr/local/bin/godot\n' | sha256sum -c - \
    && chmod 0755 /usr/local/bin/godot \
    && HOME=/tmp/godot-build godot --headless --path /bundle/app --editor --import > /tmp/godot-import.log 2>&1 \
    && cat /tmp/godot-import.log \
    && python3 -c 'from pathlib import Path; import sys; t=Path("/tmp/godot-import.log").read_text(); sys.exit(1 if "SCRIPT ERROR:" in t or "ERROR:" in t else 0)' \
    && rm -rf /tmp/godot-build

FROM ${DEBIAN_IMAGE} AS game
RUN --mount=type=secret,id=proxy_ca \
    set -eu; \
    if [ -s /run/secrets/proxy_ca ]; then \
      printf 'Acquire::https::CaInfo "/run/secrets/proxy_ca";\n' > /tmp/apt-build-ca.conf; \
      export APT_CONFIG=/tmp/apt-build-ca.conf; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3 libstdc++6 libfontconfig1 ca-certificates; \
    rm -rf /var/lib/apt/lists/* /tmp/apt-build-ca.conf; \
    groupadd --gid 10001 ace; \
    useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp/ace-user ace; \
    install -d -m 0700 -o 10001 -g 10001 /data /backups
COPY --from=builder /usr/local/bin/godot /usr/local/bin/godot
COPY --from=builder /bundle/app /opt/ace/app
COPY scripts/ /opt/ace/ops/
RUN chmod -R a=rX /opt/ace/ops /opt/ace/app && chmod 0755 /opt/ace/ops/*.sh
ENV HOME=/tmp/ace-user \
    ACE_DATA_DIR=/data \
    ACE_BIND_ADDRESS=0.0.0.0 \
    ACE_PORT=9080 \
    ACE_HEALTH_PORT=9081 \
    ACE_MAX_PLAYERS=2 \
    ACE_SNAPSHOT_HZ=15 \
    ACE_MAP_ID=3002 \
    ACE_LOG_LEVEL=info \
    ACE_SHUTDOWN_FILE=/tmp/ace-shutdown.request \
    PYTHONDONTWRITEBYTECODE=1 \
    GODOT_SILENCE_ROOT_WARNING=1
USER 10001:10001
WORKDIR /opt/ace/app
VOLUME ["/data"]
EXPOSE 9080 9081
HEALTHCHECK --interval=20s --timeout=3s --start-period=40s --retries=3 \
    CMD ["python3", "/opt/ace/ops/healthcheck.py"]
ENTRYPOINT ["/opt/ace/ops/start.sh"]

FROM ${CADDY_IMAGE} AS proxy
RUN setcap -r /usr/bin/caddy && mkdir -p /data /config && chown -R 10001:10001 /data /config
COPY Caddyfile /etc/caddy/Caddyfile
USER 10001:10001
ENV XDG_DATA_HOME=/data XDG_CONFIG_HOME=/config
