# syntax=docker/dockerfile:1

# =============================================================================
#  Nexus Media 一体化镜像（edwinhuish/nexus-media）
#
#  单容器整合：后端运行时基座（本仓库源码构建）+ 前端静态产物（web 仓库源码构建）+ Nginx
#
#  · 后端：由本仓库源码用 uv 构建依赖，运行 Granian（绑 127.0.0.1）
#  · 前端：构建期克隆 nexus-media-web 源码并 pnpm build:nexus，产出静态产物
#  · 只保留一个 Nginx：前端产物直接由镜像自带 Nginx 托管，丢弃其独立 Nginx
#  · 对外只暴露 8080；后端 3000 仅容器内回环可达
#  · 进程沿用 s6-overlay 托管，保留 PUID / PGID 机制
#
#  前端源码仓库（暂用）：https://github.com/linyuan0213/nexus-media-web
# =============================================================================

# --- 阶段 1：前端静态产物 ---
# 使用 BUILDPLATFORM：静态产物与目标架构无关，多架构构建时前端只在本机原生编译一次，
# 避免在 QEMU 仿真中编译 node/vite 导致卡死（上游 web 仓库即为此在 CI 原生构建产物）。
FROM --platform=$BUILDPLATFORM node:24-slim AS web

ENV PNPM_HOME="/pnpm" \
    PATH="/pnpm:$PATH" \
    NODE_OPTIONS=--max-old-space-size=3072 \
    TURBO_CONCURRENCY=2 \
    CI=true

# 前端源码位置：默认取 web 仓库；FRONTEND_REF 可指定分支 / tag（不存在时回退默认分支）
ARG FRONTEND_REPO=https://github.com/linyuan0213/nexus-media-web.git
ARG FRONTEND_REF=

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /web
RUN set -eux; \
    if [ -n "${FRONTEND_REF}" ]; then \
        git clone --depth 1 --branch "${FRONTEND_REF}" "${FRONTEND_REPO}" . \
        || { rm -rf /web/* /web/.[!.]* 2>/dev/null || true; git clone --depth 1 "${FRONTEND_REPO}" .; }; \
    else \
        git clone --depth 1 "${FRONTEND_REPO}" .; \
    fi

RUN npm i -g corepack \
    && pnpm install --frozen-lockfile \
    && pnpm run build:nexus

# --- 阶段 2：后端依赖（本仓库源码）---
FROM python:3.14-slim-trixie AS builder

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# 编译依赖
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    gcc libffi-dev libxml2-dev libxslt1-dev libssl-dev libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /nexus-media
COPY pyproject.toml uv.lock ./
COPY src ./src
COPY alembic ./alembic
COPY alembic.ini run.py start-prod.sh start-dev.sh restart-server.sh stop-server.sh ./

ARG UV_INDEX_URL=https://pypi.org/simple
ENV UV_INDEX_URL=${UV_INDEX_URL}

RUN uv venv .venv \
    && uv sync --frozen --no-cache --no-install-package nexus-media

# ==================== 运行时 ====================
FROM python:3.14-slim-trixie

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ARG UV_INDEX_URL=https://pypi.org/simple
ENV UV_INDEX_URL=${UV_INDEX_URL}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    nginx curl bash sudo tzdata wget xz-utils netcat-openbsd \
    libxml2 libxslt1.1 libffi8 libssl3 libpq5 \
    && rm -rf /var/lib/apt/lists/* /tmp/*

ARG S6_OVERLAY_VERSION=3.2.3.0
RUN S6_ARCH=$(case "$(uname -m)" in x86_64) echo "x86_64";; aarch64) echo "aarch64";; esac) \
    && curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" | tar -Jxpf - -C / \
    && curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" | tar -Jxpf - -C / \
    && curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz" | tar -Jxpf - -C / \
    && curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-arch.tar.xz" | tar -Jxpf - -C /

COPY --chmod=755 docker/rootfs /
RUN mkdir -p /var/log/nginx /var/run /usr/share/nginx/html

ENV S6_SERVICES_GRACETIME=30000 \
    S6_KILL_GRACETIME=60000 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    HOME="/nexus" \
    TERM="xterm" \
    LANG="C.UTF-8" \
    TZ="Asia/Shanghai" \
    NEXUS_MEDIA_CONFIG="/data/config.yaml" \
    NEXUS_MEDIA_DATA="/data" \
    PS1="\u@\h:\w \$ " \
    PUID=0 \
    PGID=0 \
    UMASK=000 \
    NEXUS_PORT=3000 \
    NEXUS_HOST=127.0.0.1 \
    WORKDIR="/nexus-media"

RUN groupadd -r -g 911 nexus \
    && useradd -r -g nexus -d ${HOME} -s /bin/bash -u 911 nexus \
    && mkdir -p ${WORKDIR} ${HOME} /data/logs \
    && echo "nexus ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR ${WORKDIR}

COPY --chown=nexus:nexus . ${WORKDIR}/
COPY --from=builder --chown=nexus:nexus /nexus-media/.venv ${WORKDIR}/.venv

# 前端静态产物：由镜像自带 Nginx 直接托管（nexus 身份读取，故 chown）
COPY --from=web --chown=nexus:nexus /web/apps/nexus-media/dist/ /usr/share/nginx/html/

RUN chmod +x \
    ${WORKDIR}/start-prod.sh \
    ${WORKDIR}/start-dev.sh \
    ${WORKDIR}/restart-server.sh \
    ${WORKDIR}/stop-server.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/health || exit 1

# 容器内唯一对外端口：Nginx 8080，反代内部 nexus-media（3000，仅绑回环）
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["/init"]
