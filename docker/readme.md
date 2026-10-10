# Nexus Media 一体化 Docker 镜像（edwinhuish/nexus-media）

把 **Nginx + nexus-media（后端）+ nexus-media-web（前端）** 整合进 **一个容器**，对外只暴露一个端口。
镜像源码、`Dockerfile`、`docker-compose*.yml` 均在本仓库 `main` 分支。

## 镜像特点

- 单容器：Nginx + 后端 + 前端静态产物，前端不再是独立服务、不再有第二个 Nginx
- **只暴露一个端口**（容器内 8080）；后端 Granian 绑 `127.0.0.1:3000`，容器外不可达
- 后端由本仓库源码用 `uv` 构建，前端在构建期从
  [linyuan0213/nexus-media-web](https://github.com/linyuan0213/nexus-media-web) 源码编译
- 基于 Debian（`python:3.14-slim-trixie`），支持 amd64 / arm64
- 非 root 用户运行（`nexus:nexus`，UID 911，可用 PUID/PGID 覆盖）
- s6-overlay 进程管理，支持优雅退出；数据库迁移在容器启动时自动执行（`alembic upgrade head`，幂等）

## 端口约定

只有 **一个对外端口**：容器内 Nginx 监听 **8080**，反向代理到内部 nexus-media 服务（3000）。

| 服务 | 容器内端口 | 宿主机映射 |
|---|---|---|
| 全部服务（经 Nginx） | 8080 | `${WEB_PORT:-8080}:8080` |
| nexus-media 后端 | 3000（仅绑 `127.0.0.1`） | 不映射 |
| Redis | 6379 | 不映射（仅内网） |
| MySQL（可选） | 3306 | `3306:3306` |
| PostgreSQL（可选） | 5432 | 不映射（仅内网） |
| nexus-chrome（可选） | 9850 / 6080 | `9850:9850` / `6080:6080` |
| nexus-verify（可选） | 9300 | `9300:9300` |

## 快速开始

项目根目录提供 **3 个独立 compose 文件**，按场景选一个（三者互斥，只选一个部署）：

| 文件 | 场景 | 启动 |
|---|---|---|
| `docker-compose.yml` | 一体化 + Redis（SQLite，开箱即用） | `docker compose up -d` |
| `docker-compose.mysql.yml` | MySQL 完整版（+Redis+OCR+Chrome） | `docker compose -f docker-compose.mysql.yml up -d` |
| `docker-compose.postgresql.yml` | PostgreSQL 完整版（+Redis+OCR+Chrome） | `docker compose -f docker-compose.postgresql.yml up -d` |

### 1. 修改配置

```bash
cp .env.example .env
```

**必填项**：

```bash
VIDEO_DIR=/mnt/media     # 媒体库目录（宿主机路径）
WEB_PORT=8080            # 唯一对外端口
PUID=1000                # 填宿主机 `id -u`
PGID=1000                # 填宿主机 `id -g`
```

MySQL / PostgreSQL 变体还需设置密码（`DB_PASSWORD`，MySQL 额外 `MYSQL_ROOT_PASSWORD`，Chrome 变体 `VNC_PASSWORD`）。

宿主机侧保证数据目录可写（详见「PUID / PGID」）：

```bash
mkdir -p data
sudo chown -R "$(id -u):$(id -g)" data
```

### 2. 启动与访问

```bash
docker compose up -d                                     # 基础版
docker compose -f docker-compose.mysql.yml up -d         # MySQL 完整版
docker compose -f docker-compose.postgresql.yml up -d    # PostgreSQL 完整版
```

- 前端 Web UI：http://localhost:8080
- 后端 API：http://localhost:8080/api/
- 健康检查：http://localhost:8080/health

数据库迁移由后端启动时自动执行，无需单独操作。

## 单独运行

```bash
docker run -d \
  --name nexus-media --hostname nexus-media \
  -p 8080:8080 \
  -v "$(pwd)/data:/data" \
  -v /mnt/media:/media \
  -e PUID="$(id -u)" -e PGID="$(id -g)" \
  -e TZ=Asia/Shanghai \
  -e REDIS__HOST=你的redis地址 \
  --restart always \
  edwinhuish/nexus-media:latest
```

> 单容器运行不带 Redis / 数据库，需用 `REDIS__*` / `DATABASE__*` 指向外部实例。

## 环境变量

优先级：`环境变量 > .env > config.yaml`。嵌套分隔符为 `__`，例如 `APP__WEB_HOST`、`DATABASE__TYPE`、`REDIS__HOST`。

### 镜像专用变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 0 | 容器内 nexus 用户 uid / gid |
| `UMASK` | 000 | 文件权限掩码 |
| `TZ` | Asia/Shanghai | 时区 |
| `NEXUS_HOST` | 127.0.0.1 | 后端监听地址（默认仅绑回环） |
| `NEXUS_PORT` | 3000 | 后端监听端口，**同时决定** Granian 端口与 Nginx upstream |
| `NEXUS_MEDIA_DATA` | /data | 数据目录（配置 / SQLite / 插件） |
| `NEXUS_MEDIA_CONFIG` | /data/config.yaml | 配置文件路径（可选） |
| `SKIP_MIGRATION` | false | `true` 时跳过启动时的 `alembic upgrade head` |

### 构建期变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FRONTEND_REPO` | `https://github.com/linyuan0213/nexus-media-web.git` | 前端源码仓库 |
| `FRONTEND_REF` | 空（默认分支） | 前端源码分支 / tag；不存在时自动回退默认分支 |
| `UV_INDEX_URL` | `https://pypi.org/simple` | Python 包索引 |

> 应用配置变量（`APP__*` / `DATABASE__*` / `REDIS__*` / `LOG__*`）以 `src/app/core/settings.py` 为准。

## 目录说明

| 容器路径 | 说明 |
|---|---|
| `/data` | 配置文件、数据库、插件数据（必须挂载） |
| `/usr/share/nginx/html` | 前端静态产物（由 Nginx 直接托管） |
| `/media` | 媒体库目录（需自行映射） |

## PUID / PGID

**目标：容器内进程以宿主机用户的身份运行，写出的文件属主与宿主机一致。**

两道 cont-init 接力（s6 按文件名顺序执行）：

| 脚本 | 做什么 |
|---|---|
| `020-fixuser` | `groupmod -o -g $PGID nexus`、`usermod -o -u $PUID nexus`，并 chown `${HOME}`(= `/nexus`) 与 `/config`、nginx 运行目录 |
| `030-nginx-runtime-perms` | 把 **Web 根目录**（`/usr/share/nginx/html`）与 nginx 的 log / pid / temp 目录重新 chown 给调整后的 nexus |

宿主机侧还需保证 `./data` 对 `PUID:PGID` 可写：

```bash
mkdir -p data data/redis_data
sudo chown -R "$(id -u):$(id -g)" data
```

> 媒体目录 `/media` 建议只读挂载（`-v /mnt/media:/media:ro`）；镜像刻意不递归 chown `/data`、`/media`。

## 构建镜像

本地构建（默认取 web 仓库默认分支的前端源码）：

```bash
docker build -t edwinhuish/nexus-media:latest .
```

锁定前端版本：

```bash
docker build --build-arg FRONTEND_REF=v4.24.5 -t edwinhuish/nexus-media:latest .
```

> 推送 `v*` 形式的 git tag 会触发 `.github/workflows/build.yml` 自动构建并推送镜像
> （`edwinhuish/nexus-media:latest` + `:<version>`），并把该 tag 作为 `FRONTEND_REF` 传给前端构建。

## 与上游两容器方案的差异

| 维度 | 上游（2 容器） | 本镜像（1 容器） |
|---|---|---|
| 容器数 | 2（web + backend） | 1 |
| Nginx 实例 | 2 | 1 |
| 对外端口 | 8080(前端) + 3000(后端 API) | 只有 8080 |
| 前端→后端 | `BACKEND_HOST:PORT` 跨容器 | `127.0.0.1:$NEXUS_PORT`，容器内回环 |
| 进程管理 | 前端 nginx 裸跑 + 后端 s6 | 统一 s6 托管，`nginx` 依赖 `nexus-media` 就绪后启动 |
| `NEXUS_PORT` 语义 | 只改 Nginx upstream | 同时作用于应用与 Nginx，语义自洽 |
