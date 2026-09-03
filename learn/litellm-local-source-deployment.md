# LiteLLM：从 Fork 到本地源码部署

## 1. 文档目标

本文记录 LiteLLM 从 GitHub Fork、克隆到 Windows、本地配置、Docker Compose 构建和运行的完整过程，并解释 README 中几种容易混淆的安装方式

本文重点说明：

- `uv tool install 'litellm[proxy]'` 安装了什么
- `litellm --model gpt-4o` 启动了什么
- 为什么当前使用 Fork 后的本地源码，而不是在线 Compose YAML
- 本地源码如何通过 Docker Compose 构建
- `registry.npmjs.org` 和 `files.pythonhosted.org` 无法访问时为什么会构建失败
- 如何把内部 npm 和 PyPI 镜像传入 Docker 构建阶段
- LiteLLM、PostgreSQL 和 Prometheus 分别运行在哪里

## 2. LiteLLM 是什么

LiteLLM 可以用两种主要形态运行

### 2.1 Python SDK

应用直接把 LiteLLM 当成 Python 库使用

```python
from litellm import completion

response = completion(
    model="openai/gpt-4o",
    messages=[{"role": "user", "content": "Hello"}],
)
```

这种方式没有独立的 Gateway 服务器。LiteLLM 运行在当前 Python 应用进程里

### 2.2 AI Gateway

LiteLLM 作为独立服务器运行，对客户端提供统一 API

```text
Claude Code / Codex / OpenAI SDK / 业务应用
                       |
                       v
                 LiteLLM :4000
                       |
          +------------+------------+
          |            |            |
        OpenAI      Anthropic      其他上游
```

Gateway 可以提供统一 API、模型路由、认证、Virtual Key、费用记录、限额和管理界面

## 3. README 中两条命令的含义

README 给出了：

```bash
uv tool install 'litellm[proxy]'
litellm --model gpt-4o
```

这是一个快速体验 LiteLLM Gateway 的方式

### 3.1 `uv tool install 'litellm[proxy]'`

这条命令使用 `uv` 从 Python 包仓库安装已经发布的 LiteLLM 包

```text
PyPI 上发布的 litellm 包
          |
          v
uv 创建独立工具环境
          |
          v
安装 litellm CLI 和 proxy 依赖
```

`[proxy]` 表示安装 LiteLLM Gateway 所需的额外依赖，不只是基础 Python SDK

它还会安装 Proxy 需要的附加包，例如：

```text
litellm-proxy-extras
```

`uv tool install` 的特点：

- 安装的是 PyPI 上已经发布的版本
- 创建独立的工具环境，不污染当前项目的 Python 环境
- 安装后可以直接运行 `litellm` 命令
- 不会使用当前 Git clone 目录中的源码
- 修改当前 Fork 中的 Python 文件不会影响这个已安装的 CLI
- 不会自动启动 PostgreSQL 或 Prometheus

它类似于安装一个全局可用、但环境隔离的命令行应用

### 3.2 `litellm --model gpt-4o`

这条命令启动一个简单的 LiteLLM Gateway，并只配置一个模型

等价理解：

```text
启动 LiteLLM HTTP Server
监听默认端口 4000
把模型名称 gpt-4o 路由到对应 Provider
```

使用 OpenAI 模型时，一般还需要先设置：

```powershell
$env:OPENAI_API_KEY = "<OpenAI API Key>"
```

然后运行：

```powershell
litellm --model gpt-4o
```

客户端可以通过统一的 OpenAI 兼容接口调用：

```text
http://localhost:4000
```

这条命令适合：

- 快速确认 LiteLLM 能否运行
- 测试单个模型
- 学习基本代理调用
- 不需要数据库、Prometheus 和完整本地源码构建的场景

它不适合验证当前 Fork 的源码修改，因为运行的是 `uv tool install` 安装的发布版本

## 4. 四种运行方式的区别

| 方式 | 使用的代码 | 是否构建当前源码 | PostgreSQL | Prometheus | 适合场景 |
|---|---|---:|---:|---:|---|
| Python SDK | Python 环境中的包 | 否 | 否 | 否 | 在应用中直接调用模型 |
| `uv tool install` + `litellm --model` | PyPI 发布包 | 否 | 否 | 否 | 快速体验单模型 Gateway |
| 在线 Compose YAML | 官方预构建镜像 | 否 | 通常有 | 取决于 YAML | 快速部署官方镜像 |
| Fork + 本地 Compose | 当前 Git 目录源码 | 是 | 有 | 有 | 学习源码、修改、调试和构建 |

当前采用的是第四种方式：

```text
个人 Fork
  |
  v
本地 Git clone
  |
  v
docker compose build
  |
  v
使用当前目录源码生成镜像
```

## 5. 为什么不直接使用在线 YAML

在线快速启动通常类似：

```powershell
curl.exe -sSL https://docs.litellm.ai/docker-compose.yml |
  docker compose -f - up -d
```

这种方式：

- 不会克隆 LiteLLM 源码
- 不会创建项目目录
- Compose 内容只通过标准输入交给 Docker
- 通常拉取官方已经构建好的镜像
- 修改本地 LiteLLM 源码不会生效

当前仓库根目录的 `docker-compose.yml` 使用：

```yaml
services:
  litellm:
    build:
      context: .
```

`context: .` 表示 Docker 使用当前仓库目录作为构建上下文

因此：

```powershell
docker compose up -d --build
```

会读取当前目录中的：

```text
Dockerfile
pyproject.toml
uv.lock
litellm\
enterprise\
ui\
```

并根据本地源码重新生成 LiteLLM 镜像

## 6. Fork LiteLLM

原始仓库：

```text
https://github.com/BerriAI/litellm
```

个人 Fork：

```text
https://github.com/jeromeecho/litellm
```

可以在 GitHub 页面点击 **Fork**，也可以使用 GitHub CLI：

```powershell
gh repo fork BerriAI/litellm `
  --clone=false `
  --remote=false
```

Fork 的意义是：

- 在自己的 GitHub 账号下保存仓库副本
- 可以推送自己的分支
- 可以向原始仓库提交 Pull Request
- 原始仓库更新后，可以继续同步

## 7. 克隆个人 Fork

```powershell
Set-Location C:\Users\honzhao
git clone https://github.com/jeromeecho/litellm.git
Set-Location .\litellm
```

查看远端：

```powershell
git remote -v
```

通常：

```text
origin = https://github.com/jeromeecho/litellm.git
```

添加原始仓库作为 `upstream`：

```powershell
git remote add upstream https://github.com/BerriAI/litellm.git
git fetch upstream
```

以后可以使用：

```powershell
git fetch upstream
```

查看上游更新。合并前应先确认当前分支和本地改动，不要在有未保存改动时直接覆盖工作区

## 8. 当前本地运行结构

仓库根目录的 Compose 会运行三个主要服务

| Compose 服务 | 容器作用 | 宿主机端口 |
|---|---|---:|
| `litellm` | LiteLLM Gateway 和管理界面 | `4000` |
| `db` | PostgreSQL 数据库 | `5432` |
| `prometheus` | Prometheus 监控服务器 | `9090` |

它们运行在 Docker Desktop 管理的 Linux 环境中：

```text
Windows
  |
  v
Docker Desktop Linux VM
  |
  +-- LiteLLM 容器
  +-- PostgreSQL 容器
  +-- Prometheus 容器
```

LiteLLM 通过 Compose 内部 DNS 名称 `db` 连接 PostgreSQL

PostgreSQL 保存：

- 模型配置
- Virtual Key
- 用户和团队配置
- 请求及费用数据

Prometheus 保存：

- 请求指标
- 延迟
- 错误率
- 其他时间序列监控数据

## 9. 创建 `.env`

仓库根目录的 Compose 声明：

```yaml
env_file:
  - .env
```

因此本地需要创建：

```text
C:\Users\honzhao\litellm\.env
```

至少需要：

```dotenv
LITELLM_MASTER_KEY=<强随机值>
LITELLM_SALT_KEY=<另一个强随机值>
```

两者用途不同：

| 变量 | 用途 |
|---|---|
| `LITELLM_MASTER_KEY` | 管理员登录和 Gateway 主认证 Key |
| `LITELLM_SALT_KEY` | 加密数据库中保存的 Provider 凭据 |

`LITELLM_SALT_KEY` 在保存 Provider 凭据后不应随意更换，否则已有加密数据可能无法解密

`.env` 已被 `.gitignore` 忽略，不应提交到 Git

## 10. 构建和运行

在仓库根目录运行：

```powershell
docker compose up -d --build
```

参数含义：

| 参数 | 含义 |
|---|---|
| `up` | 创建并启动 Compose 服务 |
| `-d` | 在后台运行 |
| `--build` | 启动前根据本地 Dockerfile 和源码构建镜像 |

查看状态：

```powershell
docker compose ps
```

查看 LiteLLM 日志：

```powershell
docker compose logs -f litellm
```

停止服务：

```powershell
docker compose down
```

访问：

```text
LiteLLM API: http://localhost:4000
管理界面:     http://localhost:4000/ui
Prometheus:  http://localhost:9090
PostgreSQL:  localhost:5432
```

管理界面的默认管理员用户名通常是：

```text
admin
```

密码使用 `.env` 中的 `LITELLM_MASTER_KEY`

## 11. Docker 构建过程

根目录 `Dockerfile` 是多阶段构建

### 11.1 `ui-builder`

使用 Node.js 构建管理界面：

```text
npm ci
npm run build
```

主要下载地址来自 npm registry

### 11.2 `builder`

使用 `uv` 安装 Python 依赖并构建 LiteLLM：

```text
uv sync
```

Python 包索引通常来自：

```text
https://pypi.org/simple
```

包文件通常从：

```text
https://files.pythonhosted.org/
```

下载

### 11.3 `runtime`

最终运行阶段只复制已经构建好的应用和依赖，减少镜像体积和构建工具暴露

## 12. 本次 npm 下载失败

最初 `ui-builder` 在执行：

```text
npm ci --prefer-offline
```

时失败：

```text
ERR_SSL_SSL/TLS_ALERT_HANDSHAKE_FAILURE
```

失败地址包括：

```text
https://registry.npmjs.org/
https://registry.npmjs.org/zwitch/-/zwitch-2.0.4.tgz
```

实际测试结果：

- Windows 访问公共 npm registry 时 TLS 握手失败
- Docker 容器访问公共 npm registry 时同样失败
- Windows 和 Docker 都可以访问内部 npm 镜像

本机 npm 已配置：

```text
https://packagefeedproxy.microsoft.io/npm/
```

问题是 Docker build 不会自动继承 Windows 用户目录中的 npm 配置

## 13. npm 镜像配置改动

### 13.1 `.env`

```dotenv
NPM_CONFIG_REGISTRY=https://packagefeedproxy.microsoft.io/npm/
```

### 13.2 `docker-compose.yml`

```yaml
services:
  litellm:
    build:
      context: .
      args:
        NPM_CONFIG_REGISTRY: ${NPM_CONFIG_REGISTRY:-https://registry.npmjs.org/}
```

这里的语法表示：

```text
如果 .env 设置了 NPM_CONFIG_REGISTRY
    使用 .env 中的地址
否则
    使用 npm 官方地址
```

你的环境最终使用内部镜像，官方地址只是其他网络环境的默认值

### 13.3 `Dockerfile`

在 `ui-builder` 阶段接收参数：

```dockerfile
ARG NPM_CONFIG_REGISTRY=https://registry.npmjs.org/
```

Docker Compose 传入值后，构建阶段中的 npm 会识别 `NPM_CONFIG_REGISTRY`

最终链路：

```text
.env
NPM_CONFIG_REGISTRY=内部 npm 镜像
           |
           v
docker-compose.yml build.args
           |
           v
Dockerfile ARG
           |
           v
npm ci 使用内部 npm 镜像
```

不能只在 Compose 中配置 `env_file`

```yaml
env_file:
  - .env
```

因为 `env_file` 主要给最终运行容器注入变量，而 `npm ci` 发生在镜像构建阶段

## 14. 本次 Python 包下载失败

npm 问题解决后，构建继续到：

```text
uv sync
```

随后下载 `openai` wheel 失败：

```text
https://files.pythonhosted.org/.../openai-2.33.0-py3-none-any.whl
```

错误仍然是：

```text
HandshakeFailure
```

进一步测试确认：

| 地址 | Windows | Docker |
|---|---|---|
| `https://pypi.org/simple/openai/` | 可访问 | 可访问 |
| `https://files.pythonhosted.org/` | TLS 失败 | TLS 失败 |
| 具体 `openai` wheel | TLS 失败 | TLS 失败 |

这说明 PyPI 索引可以打开，但真正保存 wheel 文件的域名被当前网络环境阻止

本机 pip 已配置内部 PyPI 镜像：

```text
https://packagefeedproxy.microsoft.io/pypi/simple/
```

Docker build 同样不会自动继承 Windows 的 pip 配置

## 15. PyPI 镜像配置改动

### 15.1 `.env`

```dotenv
UV_DEFAULT_INDEX=https://packagefeedproxy.microsoft.io/pypi/simple/
```

### 15.2 `docker-compose.yml`

```yaml
services:
  litellm:
    build:
      args:
        UV_DEFAULT_INDEX: ${UV_DEFAULT_INDEX:-https://pypi.org/simple}
```

含义是：

```text
如果 .env 设置了 UV_DEFAULT_INDEX
    使用内部 PyPI 镜像
否则
    使用官方 PyPI 索引
```

### 15.3 `Dockerfile`

在 Python `builder` 阶段接收：

```dockerfile
ARG UV_DEFAULT_INDEX=https://pypi.org/simple
```

仓库中的 `uv.lock` 保存了 PyPI 公共文件域名的绝对下载地址，而 `--frozen` 会直接使用这些地址。为了让 Docker 构建改用内部镜像，两次安装都先在镜像内部重新锁定，再执行冻结安装

项目同时配置了：

```toml
[tool.uv]
exclude-newer = "3 days"
```

这个设置要求包索引提供每个文件的上传时间。官方 PyPI 提供该字段，但当前内部镜像中的部分包没有上传时间。直接执行下面的命令会出现大量 `missing an upload date` 警告，并最终因 `has no publish time` 而解析失败：

```dockerfile
RUN uv lock --default-index "$UV_DEFAULT_INDEX"
```

生成的 `uv.lock` 也会把该设置固化为：

```toml
[options]
exclude-newer = "2026-08-26T18:33:25.773031Z"
exclude-newer-span = "P3D"
```

uv 0.11.7 的 `UV_EXCLUDE_NEWER` 只接受日期、时间戳或持续时间，不能使用 `false` 关闭。构建曾因设置 `UV_EXCLUDE_NEWER=false` 直接失败：

```text
invalid value 'false' for '--exclude-newer'
```

因此，重新锁定前需要从 Docker 构建环境中的 `pyproject.toml` 和 `uv.lock` 副本同时移除时间过滤配置：

```dockerfile
RUN sed -i \
    -e '/^exclude-newer = /d' \
    -e '/^exclude-newer-span = /d' \
    pyproject.toml uv.lock && \
    uv lock --default-index "$UV_DEFAULT_INDEX" && \
    uv sync --default-index "$UV_DEFAULT_INDEX" --frozen ...
```

现有 `uv.lock` 仍然作为版本选择的基础，`uv lock` 主要重新解析包来源和下载地址。构建最初使用 Python 3.14 时，锁文件中的 `uvloop 0.21.0` 没有对应 wheel，并且不支持 Python 3.14，因此曾临时升级到 `uvloop 0.22.1`

最终构建固定为 Python 3.13.13，原锁文件中的 `uvloop 0.21.0` 已有对应 wheel 且受支持，因此不再单独升级 `uvloop`，减少与官方锁文件的版本偏差

第一次重新锁定发生在安装第三方依赖前。后续的 `COPY . .` 会把仓库原始 `pyproject.toml` 和 `uv.lock` 重新复制进镜像，所以第二次安装前也需要再次删除时间过滤配置并重新锁定

这些修改和重新生成的锁文件只存在于 Docker 构建环境，不会修改宿主机仓库中的 `pyproject.toml` 或 `uv.lock`，也不会把内部镜像地址提交到公共仓库

### 15.4 Wolfi 基础镜像与 Rust/LLVM 的 glibc 版本

LiteLLM 的 Python 包通过 Maturin 构建 Rust 扩展。Wolfi 基础镜像使用固定 digest，但 `apk` 软件仓库持续滚动更新，可能出现以下组合：

```text
固定基础镜像中的旧 glibc
            +
apk 仓库中的新 Rust 和 LLVM
            =
libLLVM.so requires GLIBC_2.44
```

此时 `rustc -vV` 会在真正编译 LiteLLM 前失败。最初尝试在 builder 安装 Rust 前升级基础系统包：

```dockerfile
RUN apk upgrade --no-cache
```

实际构建证明 `apk upgrade` 仍无法消除仓库中 Rust、LLVM 和 glibc 的版本不一致，因此不能继续使用 Wolfi 仓库中的 `rust`

项目根 `Cargo.toml` 声明 Rust 1.88 或更高版本，但当前 `Cargo.lock` 中的 AWS Rust SDK 已要求 Rust 1.94.1。Dockerfile 改为从固定 digest 的官方 Rust 1.94.1 slim 镜像复制工具链：

```dockerfile
ARG RUST_IMAGE=rust:1.94.1-slim-bookworm@sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2

FROM $RUST_IMAGE AS rustbin

COPY --from=rustbin /usr/local/cargo /usr/local/cargo
COPY --from=rustbin /usr/local/rustup /usr/local/rustup

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH="/usr/local/cargo/bin:/app/.venv/bin:${PATH}"
```

同时从 `apk add` 中删除 `rust`。这样 Maturin 使用独立且固定的 Rust 工具链，不再加载 Wolfi 仓库中要求 GLIBC 2.44 的 `libLLVM.so.22.1`

Rust 工具链只存在于 builder 阶段。最终 runtime 镜像只复制构建完成的 Python 虚拟环境，不包含 Cargo、rustc 或 Rust 构建依赖

### 15.5 Prisma CLI 内部执行的 npm 安装

Admin UI 的 `npm ci` 在 `ui-builder` 阶段执行，但 Python 的 Prisma CLI 会在后面的 `builder` 阶段再次启动 npm，安装固定的 Prisma CLI 包：

```text
npm install prisma@5.4.2
```

Dockerfile 的构建参数按阶段隔离。只在 `ui-builder` 声明 `NPM_CONFIG_REGISTRY`，不会自动传入 `builder`，因此 Prisma 的 npm 子进程仍会访问公共 registry

需要在 `builder` 中再次声明：

```dockerfile
FROM $LITELLM_BUILD_IMAGE AS builder

ARG NPM_CONFIG_REGISTRY=https://registry.npmjs.org/
ARG UV_DEFAULT_INDEX=https://pypi.org/simple
```

执行 Prisma 时显式将其传给 npm 子进程：

```dockerfile
RUN HOME=/opt/prisma \
    XDG_CACHE_HOME=/opt/prisma/.cache \
    PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries \
    NPM_CONFIG_REGISTRY="$NPM_CONFIG_REGISTRY" \
    npm_config_cache=/root/.npm \
    prisma generate --schema=./schema.prisma
```

### 15.6 builder 与 runtime 的 Python 解释器必须一致

`uv` 默认下载和管理 Python，并把虚拟环境连接到类似下面的目录：

```text
/root/.local/share/uv/python/cpython-3.14.4-linux-x86_64-gnu/
```

最终 runtime 只复制 `/app/.venv`，不会自动复制 builder 的 `/root/.local/share/uv/python`。此时 `.venv/bin/python` 会成为指向不存在位置的链接，运行 `python` 时可能退回 runtime 的系统解释器，从而无法导入已经安装在虚拟环境中的 `prisma`

最初尝试让 builder 和 runtime 都使用 Wolfi 的 `/usr/bin/python3`，但实际构建证明当前滚动仓库中的 Python 也要求 GLIBC 2.44，无法在固定的旧 Wolfi 基础镜像中启动：

```text
ImportError: /usr/lib/libm.so.6: version `GLIBC_2.44' not found
```

因此不能使用 Wolfi 仓库中的 Python。最初使用 `uv` 管理的 Python 3.14.4 后，干净容器中仅执行 `from prisma import config` 仍超过 3 分钟，LiteLLM 主进程也会在启动早期持续占用 CPU。当前 Prisma Python 生成代码在 Python 3.14 下不适合作为本地运行基线

固定的 uv 0.11.7 镜像内置下载清单不包含 Python 3.13.15。通过在实际 builder 基础镜像中运行 `uv python list 3.13 --all-versions`，确认其支持的最新 3.13 版本是 Python 3.13.13，因此最终固定使用 3.13.13，并将安装目录设为会被复制进 runtime 的 `/opt/python`：

```dockerfile
ENV UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_PYTHON=3.13.13

RUN uv sync ... --python 3.13.13
```

`--python 3.13.13` 只约束对应的 `uv sync` 命令，不能约束前面的 `uv lock`。此前虽然两次 `uv sync` 都指定了 Python 3.13，`uv lock` 仍然下载并使用 Python 3.14.4。`UV_PYTHON=3.13.13` 作用于整个 builder 阶段，使重新锁定和安装使用同一个解释器版本

内部 PyPI 返回的下载地址会重定向到内部 Azure Blob 存储。一次构建曾在下载 `pytest` wheel 时因连接超时失败，这属于网络传输失败，不是包解析或 Python 兼容错误。Dockerfile 使用 uv 官方支持的超时和重试变量，并复用 BuildKit 下载缓存：

```dockerfile
ENV UV_HTTP_CONNECT_TIMEOUT=60 \
    UV_HTTP_TIMEOUT=120 \
    UV_HTTP_RETRIES=5

RUN --mount=type=cache,target=/root/.cache/uv \
    uv lock ... && \
    uv sync ...
```

缓存不会掩盖真实错误，但在临时网络失败后重新构建时，不需要再次下载已经成功获取的包

runtime 不再通过 `apk` 安装损坏的 `python3`，而是同时复制解释器和虚拟环境：

```dockerfile
COPY --from=builder /opt/python /opt/python
COPY --from=builder /app/.venv /app/.venv
```

最终镜像检查直接调用虚拟环境解释器，确保解释器和已安装包都真实可用：

```dockerfile
RUN /app/.venv/bin/python -c "from prisma.client import BINARY_PATHS; ..."
```

该处理不仅修复镜像构建检查，也保证容器启动时 `litellm` 和数据库迁移脚本使用的虚拟环境解释器在 runtime 中真实存在

### 15.7 Prisma runtime 的 Node 解释器

Prisma CLI 是 Node 程序。构建阶段执行 `prisma generate` 时，Prisma Python 包会在下面的目录下载自己的 Node 和 npm：

```text
/opt/prisma/.cache/prisma-python/nodeenv/bin/
```

最初的 runtime 又通过 Wolfi `apk` 安装了 `nodejs`。与 Python 和 Rust 相同，这个滚动仓库中的 Node 也要求 GLIBC 2.44，导致数据库迁移启动前就失败：

```text
Preparing the Prisma CLI toolchain failed:
node: /usr/lib/libm.so.6: version `GLIBC_2.44' not found
```

Prisma Python 0.11.0 默认让 nodeenv 下载最新 Node。当前构建下载到了 Node 26.8.1，但固定的 Prisma CLI 5.4.2 发布时支持的是较早的 Node LTS。`prisma --version` 可以返回，但执行 `prisma migrate status` 无法在 120 秒内完成

`PRISMA_NODEENV_EXTRA_ARGS` 在当前 Prisma Python 0.11.0 与 Pydantic 2 组合下会保留为字符串，而配置模型要求 `list[str]`，因此不能使用环境变量传递数组

该版本源码从当前目录的 `pyproject.toml` 读取 `[tool.prisma]`。为了不修改宿主机项目配置，只在 Docker 构建副本中追加 TOML 数组：

```dockerfile
RUN printf '\n[tool.prisma]\nnodeenv_extra_args = ["--node=20.20.2"]\n' >> pyproject.toml && \
    prisma generate --schema=./schema.prisma
```

Prisma 自带的 Node 还需要 GCC 的运行库 `libatomic.so.1`、`libgcc_s.so.1` 和 `libstdc++.so.6`。runtime 因此不再安装 Wolfi 的 `nodejs`，只安装这些轻量运行库，并将 Prisma Node 放到 PATH 最前：

```dockerfile
RUN apk add --no-cache bash openssl tzdata libatomic libgcc libstdc++ libsndfile

ENV PATH="/opt/prisma/.cache/prisma-python/nodeenv/bin:/app/.venv/bin:${PATH}"
```

runtime 关闭 Python 标准输出缓冲，保证启动和迁移日志立即出现在 `docker compose logs`：

```dockerfile
ENV PYTHONUNBUFFERED=1
```

镜像构建结束前执行 Node 版本检查，确保最终镜像中的 Prisma Node 真实可运行：

```dockerfile
RUN /opt/prisma/.cache/prisma-python/nodeenv/bin/node --version
```

Compose 还设置：

```yaml
ENFORCE_PRISMA_MIGRATION_CHECK: "true"
```

以后数据库迁移失败时，LiteLLM 容器会直接退出并暴露错误，不再以 healthy 状态继续运行一个没有数据库表的服务

最终链路：

```text
.env
UV_DEFAULT_INDEX=内部 PyPI 镜像
           |
           v
docker-compose.yml build.args
           |
           v
Dockerfile builder ARG
           |
           v
删除 pyproject.toml 和 uv.lock 构建副本中的时间过滤配置
           |
           v
uv lock --default-index "$UV_DEFAULT_INDEX" --upgrade-package uvloop
           |
           v
生成使用内部下载地址的临时 uv.lock
           |
           v
uv sync --default-index "$UV_DEFAULT_INDEX" --frozen
           |
           v
使用内部 PyPI 镜像
```

## 16. 当前相关配置汇总

`.env` 中包含：

```dotenv
LITELLM_MASTER_KEY=<本地生成的随机值>
LITELLM_SALT_KEY=<本地生成的随机值>
NPM_CONFIG_REGISTRY=https://packagefeedproxy.microsoft.io/npm/
UV_DEFAULT_INDEX=https://packagefeedproxy.microsoft.io/pypi/simple/
```

`docker-compose.yml` 的构建参数：

```yaml
build:
  context: .
  args:
    target: runtime
    NPM_CONFIG_REGISTRY: ${NPM_CONFIG_REGISTRY:-https://registry.npmjs.org/}
    UV_DEFAULT_INDEX: ${UV_DEFAULT_INDEX:-https://pypi.org/simple}
```

`Dockerfile` 的对应阶段：

```dockerfile
FROM --platform=$BUILDPLATFORM $UI_BUILD_IMAGE AS ui-builder

ARG NPM_CONFIG_REGISTRY=https://registry.npmjs.org/
```

```dockerfile
FROM $LITELLM_BUILD_IMAGE AS builder

ARG UV_DEFAULT_INDEX=https://pypi.org/simple

RUN sed -i \
    -e '/^exclude-newer = /d' \
    -e '/^exclude-newer-span = /d' \
    pyproject.toml uv.lock && \
    uv lock --default-index "$UV_DEFAULT_INDEX" --upgrade-package uvloop && \
    uv sync --default-index "$UV_DEFAULT_INDEX" --frozen ...
```

## 17. 为什么不关闭 SSL 校验

不应使用以下方式绕过问题：

```text
npm config set strict-ssl false
pip --trusted-host ...
关闭 TLS 证书验证
```

当前问题不是普通证书链缺失，而是连接收到 fatal TLS alert。关闭证书检查既不一定能解决，也会降低供应链安全性

正确方式是使用组织允许访问并维护的内部镜像

## 18. 源码开发与普通运行如何选择

### 只想快速体验

```powershell
uv tool install 'litellm[proxy]'
$env:OPENAI_API_KEY = "<Provider Key>"
litellm --model gpt-4o
```

这不会使用当前 Fork 的源码

### 想使用完整 Gateway、数据库和监控

使用官方在线 Compose 或预构建镜像

这通常不会使用当前 Fork 的源码

### 想学习和修改 LiteLLM 源码

```powershell
git clone https://github.com/jeromeecho/litellm.git
Set-Location .\litellm
docker compose up -d --build
```

这是当前采用的方式

## 19. 常用命令

以下命令由使用者在仓库根目录按需执行

构建并启动：

```powershell
docker compose up -d --build
```

只构建 LiteLLM：

```powershell
docker compose build litellm
```

查看状态：

```powershell
docker compose ps
```

查看日志：

```powershell
docker compose logs -f litellm
```

停止服务：

```powershell
docker compose down
```

查看构建时 Compose 解析后的配置：

```powershell
docker compose config
```

`docker compose config` 会展开变量。输出或分享结果前，应先检查是否包含敏感值

## 20. 后续与 GitHub Copilot Proxy 连接

当前目录的 LiteLLM 可以放在 `ghcp-api-console` 前面，提供统一入口

```text
Claude Code / Codex / SDK
           |
           v
      LiteLLM :4000
           |
           v
GitHub Copilot Proxy :3000
           |
           v
 GitHub Copilot API
```

两层职责不同：

| 组件 | 主要职责 |
|---|---|
| LiteLLM | 统一 API、认证、Virtual Key、模型别名、路由、费用和协议适配 |
| GitHub Copilot Proxy | Copilot OAuth 账号、identity 映射、Copilot token 和上游兼容处理 |

具体模型配置和协议路径应在两个服务都成功独立运行后再配置

## 21. 当前结论

README 中：

```bash
uv tool install 'litellm[proxy]'
litellm --model gpt-4o
```

是安装并运行 PyPI 发布版 LiteLLM 的快速体验方式

当前本地 Fork 使用：

```powershell
docker compose up -d --build
```

是根据当前 Git 仓库源码构建完整 LiteLLM Gateway、PostgreSQL 和 Prometheus 的方式

两者都能启动 LiteLLM Gateway，但代码来源、运行组件和用途不同。当前目标是学习及修改源码，因此应继续使用 Fork 后的本地 Compose 方式
