# GitHub Copilot API Console：从 Fork 到本地部署

## 1. 文档目标

本文记录将 `enjoyopenfuture/ghcp-api-console` Fork 到个人 GitHub 账号、克隆到 Windows、本地配置、构建 Docker 镜像、启动服务，以及导入 GitHub Copilot OAuth 账号的完整过程

这套部署主要用于学习和 Demo。没有 GitHub Enterprise Managed Users、SAML、SCIM、Enterprise Billing 和管理 PAT 时，仍可把项目作为单账号或多账号的 GitHub Copilot API Proxy 使用，但无法演示完整的企业账号自动创建、同步和 Copilot seat 分配流程

## 2. 项目架构

项目由 Docker Compose 编排多个 Node.js 服务

| 服务 | 默认端口 | 作用 |
|---|---:|---|
| Proxy | `3000` | 对外提供 OpenAI、Responses 和 Anthropic Messages 兼容 API |
| SSO | `7001` | 管理本地用户、SAML、SCIM 和登录身份 |
| Login | `7003` | 执行 GitHub Device Flow 和自动登录任务 |
| Console | `7004` | 提供管理控制台 |

主要调用关系如下

```text
客户端
  |
  | API_KEY + X-User-Identity
  v
Proxy :3000
  |
  +-- SSO :7001
  +-- Login :7003
  +-- GitHub Copilot API

管理员
  |
  v
Console :7004
```

## 3. 前置条件

Windows 本机需要准备以下工具

```text
Git
GitHub CLI
Docker Desktop
Node.js
npm
OpenSSL
```

确认工具可用

```powershell
git --version
gh --version
docker version
docker compose version
node --version
npm --version
openssl version
```

确认 GitHub CLI 已登录正确账号

```powershell
gh auth status
```

## 4. Fork 仓库

原始仓库是：

```text
https://github.com/enjoyopenfuture/ghcp-api-console
```

Fork 后的仓库是：

```text
https://github.com/jeromeecho/ghcp-api-console
```

可以在 GitHub 页面点击 **Fork**，也可以使用 GitHub CLI

```powershell
gh repo fork enjoyopenfuture/ghcp-api-console `
  --clone=false `
  --remote=false
```

检查 Fork

```powershell
gh repo view jeromeecho/ghcp-api-console `
  --json nameWithOwner,parent,defaultBranchRef,url
```

## 5. 克隆并配置远端

克隆自己的 Fork

```powershell
Set-Location C:\Users\honzhao
git clone https://github.com/jeromeecho/ghcp-api-console.git
Set-Location .\ghcp-api-console
```

默认的 `origin` 应指向个人 Fork

```powershell
git remote -v
```

为了以后同步原始仓库，可以添加 `upstream`

```powershell
git remote add upstream https://github.com/enjoyopenfuture/ghcp-api-console.git
git fetch upstream
```

同步原始仓库的 `main` 分支

```powershell
git switch main
git pull --ff-only origin main
git fetch upstream
git merge --ff-only upstream/main
git push origin main
```

如果 Fork 中已有自己的提交，`--ff-only` 可能拒绝合并。此时先检查分支差异，不要直接执行 `reset --hard`

## 6. 主目录与 Worktree

本次实际运行 Demo 的主目录是：

```text
C:\Users\honzhao\ghcp-api-console
```

Git worktree 是同一仓库的另一个独立工作目录。它和主目录共享 Git object database，但拥有独立的分支、工作区文件和未跟踪文件

这意味着：

- worktree 中的代码修改不会自动出现在主目录
- `.env`、证书等未跟踪文件不会在两个目录之间共享
- worktree 中的修改需要提交，再由主目录 merge 或 cherry-pick
- Docker 镜像由同一个 Docker Desktop 共享，但 `docker compose up --build` 会读取当前目录的 Dockerfile

运行和排错前，先确认当前所在目录

```powershell
Get-Location
git status --short --branch
```

## 7. 创建 `.env`

从模板创建本地配置

```powershell
Copy-Item .env.example .env
```

打开文件

```powershell
notepad .env
```

至少需要替换模板中的敏感占位值

```dotenv
API_KEY=<生成一个强随机值>
INTERNAL_API_TOKEN=<生成一个不同的强随机值>
SESSION_SECRET=<生成一个不同的强随机值>
```

这几个值用途不同

| 变量 | 用途 |
|---|---|
| `API_KEY` | 客户端访问 Proxy 公共 API |
| `INTERNAL_API_TOKEN` | Console、Proxy、SSO 和 Login 之间的内部接口认证 |
| `SESSION_SECRET` | Console 和 SSO 的 Cookie Session 签名 |

可以在 PowerShell 中生成随机值。命令只输出到当前终端，复制后不要提交到 Git

```powershell
function New-Secret {
  $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
  [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

New-Secret
New-Secret
New-Secret
```

确认 `.env` 不会进入 Git

```powershell
git check-ignore .env
```

如果需要修改端口或路径，以仓库当前的 `.env.example` 和 `docker-compose.yml` 为准

## 8. 生成本地 SAML 证书

SSO 容器启动时需要读取：

```text
certs\idp-cert.pem
certs\idp-key.pem
```

仓库提供了：

```bash
bash scripts/gen-certs.sh
```

Windows checkout 可能使用 CRLF，脚本可能在 `set -o pipefail` 处失败。Windows 环境下可以直接使用 OpenSSL

```powershell
New-Item -ItemType Directory -Force .\certs

openssl req -x509 `
  -newkey rsa:2048 `
  -nodes `
  -keyout .\certs\idp-key.pem `
  -out .\certs\idp-cert.pem `
  -days 3650 `
  -subj "/CN=localhost"
```

确认文件存在

```powershell
Get-ChildItem .\certs
```

预期至少看到：

```text
idp-cert.pem
idp-key.pem
```

这些是本地 Demo 证书，不应用于生产环境

## 9. Docker Compose 启动

Docker Compose 模式不要求先在 Windows 上运行 `npm install`。每个服务的 Dockerfile 会在镜像构建阶段安装依赖

启动并构建全部服务

```powershell
npm run compose:up
```

该 npm script 本质上执行：

```powershell
docker compose up -d --build
```

检查容器

```powershell
docker compose ps
```

检查项目健康状态

```powershell
npm run validate:health
```

打开控制台

```text
http://localhost:7004
```

查看所有服务日志

```powershell
docker compose logs --tail 200
```

查看单个服务日志

```powershell
docker compose logs sso --tail 200
docker compose logs login --tail 200
docker compose logs proxy --tail 200
docker compose logs console --tail 200
```

停止服务

```powershell
docker compose down
```

不要随意使用 `docker compose down -v`。`-v` 会同时删除 Compose 管理的数据卷

## 10. 本地 Node.js 开发模式

如果要频繁修改和调试单个服务，可以不用 Compose，改为本地 Node.js 模式

安装依赖并检查项目

```powershell
npm ci
npm run build:deploy
npm run typecheck:deploy
```

分别在不同终端启动服务

```powershell
npm run start:sso
```

```powershell
npm run start:login
```

```powershell
npm run start:proxy
```

```powershell
npm --workspace @ghcp/console run build
npm run start:console
```

只想快速运行 Demo 时，优先使用 Docker Compose

## 11. 本次遇到的问题

### 11.1 Docker 无法连接

典型错误：

```text
failed to connect to the docker API
```

先确认 Docker Desktop 已启动，并且使用 Linux containers

```powershell
docker info
docker context show
```

### 11.2 Docker context 文件被占用

典型错误：

```text
The process cannot access the file because it is being used by another process
```

涉及的文件通常位于 Docker context 的 `meta.json`。这是 Docker Desktop 的临时文件锁问题，先等待 Docker Desktop 恢复，再重新执行 Compose，不要删除整个 Docker 配置目录

### 11.3 `npm ci` 报 `Exit handler never called`

本次 verbose 日志显示，真正原因是 Docker 构建容器访问 `registry.npmjs.org` 时发生 TLS 握手失败，而不是项目代码错误

宿主机 npm 使用了可访问的内部 npm registry，但 Docker build 不会自动继承宿主机的 npm 配置

先分别验证宿主机和容器网络

```powershell
npm config get registry
curl.exe -I https://registry.npmjs.org/typescript
docker run --rm node:22-bookworm-slim `
  node -e "fetch('https://registry.npmjs.org/typescript').then(r=>console.log(r.status)).catch(e=>{console.error(e.cause||e);process.exit(1)})"
```

如果所在网络要求内部 registry，应通过 Docker build argument、BuildKit secret 或组织认可的镜像配置方式传入，不要把个人凭据或内部认证信息提交到公开仓库

### 11.4 SSO 容器退出

典型错误：

```text
ENOENT: no such file or directory, open '/certs/idp-cert.pem'
```

这说明 Compose volume mount 已生效，但宿主机没有生成对应文件。执行第 8 节的 OpenSSL 命令，再重新启动

```powershell
docker compose up -d
npm run validate:health
```

## 12. 创建 SSO User

进入：

```text
http://localhost:7004
```

在 Console 的 **SSO Users** 页面创建用户

需要理解两个不同概念

| 对象 | 作用 |
|---|---|
| SSO User | 本地身份目录，保存用户名、密码哈希、角色及 GitHub 登录名 |
| Proxy Account | 保存 API identity、GitHub 登录名、Copilot OAuth token 和请求统计 |

CSV 导入 Copilot OAuth token 前，必须先存在同名的 SSO User

创建用户时：

- `ssoUser` 是核心用户名
- `email` 留空时可由系统按运行时域名生成
- `role` 默认可以使用 `user`
- 本地密码不是 GitHub 密码，也不是 Microsoft Entra 密码
- 显式填写密码时使用该密码
- 留空时系统可能使用 `SSO_DEFAULT_USER_PASSWORD`，未配置时可能回退到用户名

仅创建 SSO User 不会在无真实 SCIM/EMU 环境中自动创建 Proxy Account

## 13. 导入 Copilot OAuth Token

无真实 EMU 自动开户链路时，首次创建 Proxy Account 应使用 CSV 导入

进入：

```text
Console -> Proxy Accounts -> Import Copilot OAuth tokens
```

CSV 格式：

```csv
name,copilotOauthToken
demo-user-1,<GitHub Device Flow 生成的 OAuth token>
demo-user-2,<GitHub Device Flow 生成的 OAuth token>
```

注意：

- `name` 必须与已创建的 SSO User 一致
- token 应来自项目支持的 GitHub Device Flow OAuth client
- token 通常以 `gho_` 开头
- 它不是 GitHub Developer Settings 创建的 PAT
- 它也不是 `gh auth token`
- 不要把真实 token 保存到文档、代码或 Git

导入时，Proxy 会调用 Copilot `/models` 验证 token

| 结果 | 含义 |
|---|---|
| 成功 | 账号和 Copilot token 可用，创建或更新 Proxy Account |
| `401` | token 无效或已过期 |
| `403` | 账号没有 Copilot seat，或被组织策略阻止 |

`Reauthorize Copilot` 只适用于已经存在的 Proxy Account。Proxy Accounts 为空时，不能依靠该按钮完成首次开户

## 14. 验证 Proxy

先列出模型

```powershell
$headers = @{
  Authorization = "Bearer <API_KEY>"
  "X-User-Identity" = "demo-user-1"
}

Invoke-RestMethod `
  -Uri "http://localhost:3000/v1/models" `
  -Headers $headers
```

测试 Anthropic Messages API

```powershell
$headers = @{
  "x-api-key" = "<API_KEY>"
  "X-User-Identity" = "demo-user-1"
  "anthropic-version" = "2023-06-01"
  "Content-Type" = "application/json"
}

$body = @{
  model = "<从 /v1/models 返回结果中选择>"
  max_tokens = 256
  messages = @(
    @{
      role = "user"
      content = "你好，请回复一条测试消息"
    }
  )
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:3000/v1/messages" `
  -Headers $headers `
  -Body $body
```

不要假设模型名称。先调用 `/v1/models`，再选择当前账号可见并支持目标 API path 的模型

## 15. Claude Code、Codex 和 LiteLLM

项目默认可以启用：

```dotenv
CLAUDE_CODE_OPTIMIZED=true
```

它主要优化 `/v1/messages` 和 Claude Code 请求，不会把 OpenAI Responses 协议自动转换成 Anthropic Messages 协议

因此：

- Claude Code 使用 Claude 模型时走 `/v1/messages`
- Codex 或 GPT 模型通常走 `/responses`
- Codex 客户端通过 `/responses` 请求 Claude 模型时，可能因为 API 协议不匹配而失败
- `CLAUDE_CODE_OPTIMIZED` 开关无法解决 Responses 和 Messages 之间的协议转换
- 开启优化后，`GET /v1/models` 可能只返回适合 Claude Code 的模型，可通过 `X-Claude-Code-Optimized: false` 请求完整列表

如果在前面再部署 LiteLLM，可以让 LiteLLM 负责统一入口、鉴权、模型别名和必要的协议适配，当前项目继续负责 GitHub Copilot 账号与 token 管理

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

## 16. 安全与运维注意事项

- `.env`、OAuth token、私钥和证书私钥不得提交到 Git
- Demo 使用的自签名证书不能直接用于生产
- 每个 GitHub 账号应使用独立的 Copilot OAuth token
- 每个 API 调用应携带正确的 `X-User-Identity`
- `API_KEY`、`INTERNAL_API_TOKEN` 和 `SESSION_SECRET` 应使用不同随机值
- 生产环境应使用正式 TLS、可靠的 secret manager、持久化备份和最小权限账号
- 错误诊断可能包含请求信息，对外分享日志前必须检查并脱敏
- 删除用户、SCIM identity 和 Proxy Account 涉及多个服务，不应假设它们构成一个数据库事务

## 17. 最短启动清单

```powershell
git clone https://github.com/jeromeecho/ghcp-api-console.git
Set-Location .\ghcp-api-console

Copy-Item .env.example .env
# 编辑 .env，替换所有敏感占位值

New-Item -ItemType Directory -Force .\certs
openssl req -x509 `
  -newkey rsa:2048 `
  -nodes `
  -keyout .\certs\idp-key.pem `
  -out .\certs\idp-cert.pem `
  -days 3650 `
  -subj "/CN=localhost"

npm run compose:up
docker compose ps
npm run validate:health
```

然后访问：

```text
Console: http://localhost:7004
Proxy:   http://localhost:3000
SSO:     http://localhost:7001
Login:   http://localhost:7003
```

