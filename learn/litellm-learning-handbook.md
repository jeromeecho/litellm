# LiteLLM 中文学习手册：从协议适配到可运营的模型网关

资料核对日期：2026-09-11

本手册面向已经接触过模型 API、希望理解 LiteLLM 并能独立排错的个人学习者。主要依据直接查阅的官方文档，引用编号对应文末完整链接。安装练习固定 `1.100.0`，这是便于对照本地历史环境的复现基线，不是“当前最新版”或生产推荐版本

阅读时区分三层证据：标有引用的是查阅日的官方说明；第十章是 2026-09-10 本地记录及最终补充证据；命令和实验是供读者执行的练习，没有声称本次已经启动服务或完成真实调用。在线文档持续更新，新参数、UI 入口、插件以及协议能力未必与已安装的 `1.100.0` 完全一致

## 目录与学习路线

| 章节 | 要回答的问题 |
|---|---|
| 一、定位与能力地图 | LiteLLM 解决什么，不解决什么 |
| 二、架构与请求生命周期 | SDK、Proxy、Router 如何协作 |
| 三、模型、地址与协议 | 一个请求到底去了哪里 |
| 四、独立安装与最小配置 | 怎样不碰现有 Docker 做练习 |
| 五、配置、凭据与持久化 | YAML、数据库和 UI 谁说了算 |
| 六、路由策略详解 | 怎样选择部署，怎样比较取舍 |
| 七、重试、冷却与回退 | 失败后如何恢复，代价是什么 |
| 八、限流、预算与缓存 | 控制的是哪一层资源 |
| 九、可观测性与生产边界 | 如何验证，而不只看“成功” |
| 十、Foundry 有界案例 | 如何避免把局部现象当平台限制 |
| 十一、排错决策树与实验 | 从单请求推进到多部署 |
| 十二、术语与参考索引 | 查概念和原始资料 |

建议先读第一至五章并做单部署实验，再读第六至八章。准备连接编码助手时，先完成协议和工具回传验证，不要从调大上下文、开启回退或修改模型菜单开始

## 一、定位与能力地图

LiteLLM 是模型调用的适配层，也是可独立部署的模型网关。它把多个提供商的接口差异封装在相对统一的调用方式后面，并提供路由、凭据隔离、使用量记录等能力。它不训练模型，也不会因为改了公开别名，就让一个部署获得另一个模型的推理、上下文或工具能力 [1]

理解它的价值，可以从“每个应用维护多套提供商代码”变成“应用面向统一入口，平台集中维护适配与治理”。代价是增加一个需要升级、监控和验证语义兼容性的组件。个人单脚本未必需要完整网关，多应用共享模型、团队授权和预算时，Proxy 的价值更明显

| 能力 | 适合解决的问题 | 不能直接推导的结论 |
|---|---|---|
| 统一调用与异常映射 | 减少提供商 SDK 差异 | 所有参数、错误细节和能力都相同 |
| Chat、Responses、流式、工具调用 | 接入常见应用与编码助手 | 接口存在就完整支持每种事件与工具 |
| Embeddings、图像、音频等接口 | 统一不同模态入口 | 任意模型都能接受这些请求 |
| Router | 多部署分流、故障恢复 | 自动理解每个问题应该用什么模型 |
| Virtual Key 与团队管理 | 隔离凭据、模型访问和用量 | 网关 Key 能直接调用提供商 |
| 成本与日志 | 追踪应用消耗、排查请求 | 页面费用就是最终云账单 |
| Guardrails、MCP、Agent 接入 | 在网关扩展策略与工具治理 | 所有版本、协议和版本授权都相同 |

官方首页还提供 Agent 与 MCP 网关入口，但学习时应先掌握模型请求链路。SSO、高级访问控制、审计、特定 Guardrail 和企业集成可能受版本或授权影响，要逐项检查对应文档与已部署版本，不能把整个功能类别一概标为免费或企业专属 [1][18]

## 二、架构与请求生命周期

### 2.1 SDK、Proxy、Router 不是三个互斥产品

**SDK** 是 Python 库，应用直接调用 `litellm.completion()`、`litellm.responses()` 等函数。模型凭据通常在应用进程中，适合脚本或希望自己控制服务生命周期的后端

**Proxy** 是独立 HTTP 服务，接收客户端请求，执行网关认证与治理，再调用模型。应用可以继续用 OpenAI SDK，把 `base_url` 改成自己的网关，并使用网关 Key。跨语言客户端不需要安装 LiteLLM Python 包 [1][3]

**Router** 是部署选择与可靠性组件，可以直接嵌入 Python 应用，也可以由 Proxy 根据配置使用。它维护模型组、候选部署与路由状态。使用 SDK 并不自动意味着配置了 Router，使用 Router 也不要求一定部署 Proxy [2]

```text
应用 / 编码助手 / OpenAI SDK
    |
    | HTTP 请求：公开模型别名 + 网关凭据 + 具体协议
    v
LiteLLM Proxy：认证、权限、预算、日志与策略入口
    |
    v
Router：模型组解析、候选筛选、部署选择、失败恢复
    |
    v
Provider 适配器：路径、参数、认证、请求与响应转换
    |
    v
提供商端点：模型部署 / 上游模型路由服务

PostgreSQL：配置、Key 元数据、团队、预算记录、花费日志
Redis：共享短期计数、冷却状态、缓存与多进程协调
Admin UI：通过管理接口操作网关，不是推理模型
```

这是一张逻辑图，不是所有版本每个函数的严格执行顺序。缓存、插件和不同 API 路径会改变细节。排错时需要的是确定认证、模型解析、协议转换、上游调用和结果记录分别发生在哪里，而不是背诵一条永远不变的流水线

一次成功调用至少包含四种结果：客户端收到业务响应；某个部署实际完成请求；使用量被识别；日志或费用记录被写入。前一项成功不保证后三项全部正确。例如流式文本已返回，但最终 usage 丢失，可能影响记账；数据库暂时不可用时，日志落库也可能延迟 [6][10][19]

### 2.2 控制面与数据面

添加模型、创建 Key、修改预算属于控制面；应用的 Chat 或 Responses 请求属于数据面。UI 能打开只说明部分控制面可用，`/v1/models` 能列出别名只说明模型目录和访问范围可读，两者都不能证明上游推理成功

同样，提供商门户能看到部署，不代表当前身份有数据调用权限。应分别记录“谁管理配置”和“谁调用模型”，不要拿管理员浏览器登录状态解释服务端 API Key 的权限

## 三、模型、地址与协议

### 3.1 五个容易混淆的标识

| 字段或概念 | 作用 | 示例 |
|---|---|---|
| `model_name` | 客户端使用的公开别名，也用于组成模型组 | `study-chat` |
| `litellm_params.model` | LiteLLM 适配器与上游模型标识 | `openai/YOUR_DEPLOYMENT` |
| `api_base` | 适配器使用的上游基础地址 | `https://YOUR_HOST/openai/v1` |
| 上游 deployment name | 提供商已创建的部署名称 | `YOUR_DEPLOYMENT` |
| `model_info.id` | LiteLLM 中一条部署配置的标识 | `study-a` |

`model_name` 可以自己命名，不需要等于提供商型号。两条配置使用相同 `model_name`，通常会组成一个可负载均衡的模型组。`model_info.id` 应能区分其中的部署，它不是云资源 ID，也不是自动创建上游模型的指令 [2][3]

`openai/` 表示选择 OpenAI 协议适配路径，并不保证请求发往 OpenAI 公网。自定义 `api_base` 可以指向实现相应协议的服务。反过来，部署出现在 Azure Foundry 门户，也不能据此把任意 URL 都交给 `azure_ai/` 处理。适配器选择与 URL 路径必须匹配 [3][13]

客户端 `base_url` 指向 LiteLLM，例如 `http://127.0.0.1:4001/v1`；服务端 `api_base` 指向真正上游。不要把两者配置成同一网关并形成递归调用。基础地址通常不应包含已由 SDK 追加的 `/chat/completions` 或 `/responses`，也要检查尾部空格、重复 `/v1` 与编码后的 `%20`

### 3.2 统一入口不是无损透传保证

Chat Completions 以 `messages`、`choices` 和 `tool_calls` 为主要结构；Responses 使用 `input`、`output`、具名事件及工具结果项。工具声明在两个协议中的层级也不同，复制 JSON 时只改 URL 往往不够

**原生路径** 是入口协议与上游实际接口对应，例如 Responses 请求最终调用上游 `/responses`。**桥接路径** 是 LiteLLM 将一种 API 形状转换为另一种，再转换返回结果。官方 Responses 文档面向多提供商提供统一入口，但“支持 Responses 调用”不等于每个适配器都拥有原生 Responses 实现 [6]

桥接需逐项验证流式事件、函数参数、工具调用 ID、工具回传、推理内容、图片、结构化输出和错误映射。`previous_response_id`、响应检索/删除、后台任务或提供商内置工具可能依赖上游状态，不能从“普通文本成功”推断这些功能可用

不要把 `use_chat_completions_api: false` 理解为全局禁止任何自动桥接。实际选择还取决于适配器注册和版本能力，第十章有 `1.100.0` 的具体反例。`drop_params` 也不是通用兼容性补丁，丢弃参数可能让请求成功却失去所需语义 [3][6]

学习协议时先固定一个部署，顺序验证文本、流式、工具声明、工具结果回传，最后再加入复杂 Schema。每增加一项，只改变一个变量

## 四、独立安装与最小配置

### 4.1 建立隔离环境

以下示例面向 PowerShell 7 和已安装的 Python 3.11。所有文件放在学习目录，端口使用 `4001`，与配套 PPT 保持一致，不停止、不升级、不重建现有 `4000` 端口的 Docker 服务。先确认 `4001` 未被占用；若已占用，选择其他端口并同步修改命令

```powershell
Get-NetTCPConnection -LocalPort 4001 -ErrorAction SilentlyContinue
py -3.11 -m venv .\learn\.venv-handbook
.\learn\.venv-handbook\Scripts\python.exe -m pip install "litellm[proxy]==1.100.0"
.\learn\.venv-handbook\Scripts\python.exe -c "from importlib.metadata import version; print(version('litellm'))"
```

预期版本查询输出 `1.100.0`。固定包版本只是复现的第一步，依赖、Python、模型价格表和上游服务仍可能变化。生产应选择完成安全评估和回归验证的版本，锁定依赖及镜像 digest，记录配置版本。不要照抄在线 Quickstart 的浮动 `latest` 到长期环境，也不要为了学习替换用户正在运行的容器 [17]

若 Windows 上完整 Proxy 依赖不兼容，可另建隔离容器或 WSL 环境，不要混用现有服务的环境和数据库。选择容器时核验官方仓库、目标版本与 digest；本文不提供未经核验的镜像哈希

### 4.2 完整最小配置：单部署、无数据库

把下面完整内容保存为 `.\learn\handbook-config.yaml`。它要求一个支持 OpenAI-compatible Chat Completions 的上游，`YOUR_DEPLOYMENT` 必须替换为真实部署标识。它可以运行推理入口，但不包含数据库管理、Virtual Key 或可靠的网关预算上限 [3][17]

```yaml
model_list:
  - model_name: study-chat
    litellm_params:
      model: openai/YOUR_DEPLOYMENT
      api_base: os.environ/STUDY_API_BASE
      api_key: os.environ/STUDY_PROVIDER_KEY
    model_info:
      id: study-a

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

router_settings:
  routing_strategy: simple-shuffle
  num_retries: 0
  timeout: 60
```

先在可信密码管理器中生成并保存一个以 `sk-` 开头的长随机学习 Master Key，再在独立学习终端中设置环境变量。`Read-Host -MaskInput` 隐藏键入内容，但变量在进程内仍是明文，环境变量不是密钥保险箱。不要启用会记录敏感输出的 transcript，也不要把 Key 打印或粘贴到请求示例中

```powershell
$env:LITELLM_MODE = "PRODUCTION"
$env:STUDY_API_BASE = Read-Host "支持 Chat 的上游 Base，包含所需 /v1"
$env:STUDY_PROVIDER_KEY = Read-Host "上游 Key" -MaskInput
$env:LITELLM_MASTER_KEY = Read-Host "密码管理器保存的学习 Master Key" -MaskInput
.\learn\.venv-handbook\Scripts\litellm.exe --config .\learn\handbook-config.yaml --host 127.0.0.1 --port 4001 --num_workers 1
```

`LITELLM_MODE=PRODUCTION` 在这里用于避免自动读取仓库 `.env`，并不意味着这套学习配置已经满足生产要求。应检查新终端没有继承其他实验的数据库或 Redis 配置。前台服务用 Ctrl+C 停止，退出终端后清除本次进程中的凭据 [10]

在另一个独立终端从密码管理器安全输入同一个学习 Master Key，然后调用接口，不要通过日志传播。下例只显示返回信息，不显示认证头

```powershell
$gatewayKey = Read-Host "本次学习网关 Key" -MaskInput
$headers = @{ Authorization = "Bearer $gatewayKey" }
$body = @{
  model = "study-chat"
  messages = @(@{ role = "user"; content = "Reply with OK only" })
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri "http://127.0.0.1:4001/health/liveliness"
$result = Invoke-WebRequest -Uri "http://127.0.0.1:4001/v1/chat/completions" -Method Post -Headers $headers -ContentType "application/json" -Body $body
$result.StatusCode
$result.Headers["x-litellm-model-id"]
$result.Content
```

预期证据是 HTTP 成功状态、可解析业务响应，以及可用时的部署 ID 与 usage。模型未必严格只输出 `OK`，不能把这三个字符当成完整验证。此请求会消耗真实提供商额度，应先在上游设定学习限额

### 4.3 Docker 学习路径：独立容器、只读配置、固定镜像

也可以完全跳过 Python 虚拟环境，用已运行的 Docker Desktop Linux 容器模式完成同一实验。复用 4.2 的**完整最小 YAML**及三个学习凭据环境变量，不需要下载 Compose，更不需要把远程脚本或 Compose 内容管道送入 shell。Python 和 Docker 两条路径二选一，不能同时占用 `4001` [17]

先从官方镜像发布信息核对所需版本、平台与可信 digest。若要复现 `1.100.0`，选择能够核验其实际包版本的历史镜像；如果找不到，不要擅自换成 `latest`。本文没有核验历史标签是否仍可下载，因此要求输入已确认的完整镜像引用，而不编造标签或哈希。下面限制到官方仓库的 digest 形式，例如 `docker.litellm.ai/berriai/litellm@sha256:` 后接真实的 64 位摘要

```powershell
docker version
$studyImage = Read-Host "已核验的官方镜像完整 digest 引用"
if ($studyImage -notmatch '^docker\.litellm\.ai/berriai/litellm@sha256:[0-9a-f]{64}$') {
  throw "请提供核验过的官方镜像 digest，不接受浮动标签"
}
docker pull $studyImage
if ($LASTEXITCODE -ne 0) { throw "镜像拉取失败，停止本轮实验" }
docker run --rm --entrypoint python $studyImage -c "from importlib.metadata import version; print(version('litellm'))"
```

核对最后的版本输出。以 `1.100.0` 为基线时输出必须匹配，否则停止并查明镜像来源；选择其他经过验证的版本时，应明确记录新的实验基线。digest 固定内容，但不能代替确认发布者、平台和供应链来源

确认学习 YAML 已保存，环境变量已在**当前终端**设置，`4001` 空闲，再启动一个带唯一名称的学习容器。这里只挂载单个配置文件，不挂载整个仓库、现有 `.env` 或数据库卷。容器内 `/app/config.yaml` 是 Linux 路径，宿主机仍使用 Windows 路径

```powershell
$configPath = (Resolve-Path .\learn\handbook-config.yaml).Path
$studyContainer = "litellm-handbook-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$dockerArgs = @(
  "run", "--detach",
  "--name", $studyContainer,
  "--publish", "127.0.0.1:4001:4000",
  "--mount", "type=bind,source=$configPath,target=/app/config.yaml,readonly",
  "--env", "STUDY_API_BASE",
  "--env", "STUDY_PROVIDER_KEY",
  "--env", "LITELLM_MASTER_KEY",
  "--env", "LITELLM_MODE=PRODUCTION",
  $studyImage,
  "--config", "/app/config.yaml",
  "--host", "0.0.0.0",
  "--port", "4000",
  "--num_workers", "1"
)
docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw "学习容器启动失败" }
docker ps --filter "name=$studyContainer" --format "{{.Names}} {{.Status}}"
Invoke-RestMethod -Uri "http://127.0.0.1:4001/health/liveliness"
```

启动可能需要等待，探针未通时先检查这个学习容器的状态和脱敏日志，不能只看到容器 ID 就算成功。随后复用 4.2 的真实 Chat 请求，确认模型响应和部署 ID。容器内 `localhost` 指容器自身，若上游模型在 Windows 宿主机，需使用可达的宿主地址，例如 Docker Desktop 的 `host.docker.internal`，不能直接沿用宿主机回环地址

实验后只删除本次唯一命名的容器。以下回滚不删除镜像、不清理卷、不影响其他服务，也不使用 `docker compose down` 或全局 prune

```powershell
docker stop $studyContainer
docker rm $studyContainer
```

此容器仍是无数据库模式，不提供 UI 数据库模型管理、Virtual Key 或有效的全局预算上限。进一步学习这些能力时，再连接专用 PostgreSQL，并在保存首个模型前设置稳定的 `LITELLM_SALT_KEY`。Docker 管理员能够读取容器环境变量，`--env` 只是避免在命令参数中展开 Key，并非防止宿主管理员访问秘密

## 五、配置、凭据与持久化

### 5.1 四个配置区域

`model_list` 描述部署；`router_settings` 控制路由、超时和恢复；`litellm_settings` 控制库级行为，例如日志、参数处理、响应缓存；`general_settings` 描述 Proxy、数据库和管理员配置。把字段放错区域，可能导致未生效或加载失败。官方页面存在少量旧拼写和旧枚举，应结合当前参数参考及目标版本验证 [3][16]

### 5.2 YAML 和 UI 不是互相覆盖的一张表

按当前官方说明，启用 `store_model_in_db` 后，UI/API 添加的模型存入数据库，与 YAML 模型一起被服务。相同公开别名的数据库模型不会自动替换 YAML 条目，而可能成为同一组的额外部署。文件模型由文件管理，不能期待 UI 删除操作顺带修改本地 YAML [3][9]

配置节的规则不同：UI 写入数据库的 `general_settings`、`router_settings`、`litellm_settings`、`environment_variables` 会覆盖相同键的 YAML 值。官方说明是深合并，部分空值不覆盖。因此“改 YAML 再重启仍没变化”可能来自数据库覆盖，不一定是缓存坏了。这是查阅日规则，旧版本须用有效配置和重启实测确认

选择一个主要模型管理来源：GitOps 适合 YAML，可审查和回退；频繁运营调整适合数据库与管理 API。混用时必须记录每条模型来自哪里、由谁更新。UI 保存成功也不表示所有副本同时刷新，官方生产说明仍描述轮询同步，应观察每个实例的生效时间 [9][10]

### 5.3 四类 Key 必须分开

| 凭据 | 使用位置 | 关键边界 |
|---|---|---|
| Provider Key | LiteLLM 到上游 | 拥有真实云资源调用权限 |
| Master Key | Proxy 管理员认证 | 高权限，不能作为普通应用的长期 Key |
| Virtual Key | 应用到 Proxy | 可限制模型、预算、速率、有效期 |
| Salt Key | 数据库中凭据的加解密 | 不是调用令牌，也不是用于生成模型答案 |

Master Key 按官方要求以 `sk-` 开头。Salt Key 应独立生成并安全保管，尤其在数据库中已有模型凭据后不能随意改变。当前文档说明，未设置 Salt Key 时可能退回使用 Master Key 加密，因此管理员凭据轮换与历史加密数据恢复必须一起规划 [4][9][10]

一把 Virtual Key 可以授权多个公开模型，模型选择仍由请求 `model` 决定。`All Proxy Models` 不负责创建客户端模型菜单。Key 的权限还可能受到团队、用户及管理路由规则影响，不要仅凭“由管理员创建”就假定它是受限普通 Key [4]

### 5.4 PostgreSQL 和 Redis 各自解决什么

PostgreSQL 是持久记录的基础，用于 Virtual Key、团队、模型配置及花费等数据。Redis 负责高频共享状态和缓存，不能代替关系数据库持久保存模型管理记录；数据库也不会自动代替 Redis 提供低延迟共享计数 [4][8]

下面是合并到完整配置的片段，不可单独启动。数据库和 Salt Key 需预先安全配置，数据库应是本次实验专用实例或库，不能指向现有生产库

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true
```

应用启动和迁移方式依安装形态确认。备份不仅包括数据库，还包括可恢复的加密密钥、环境配置与镜像版本。删除容器不是备份，数据库卷丢失或 Salt Key 丢失都会影响恢复

## 六、路由策略详解

### 6.1 先区分三种“路由”

负载均衡回答“同一模型组的哪条部署处理请求”；智能路由回答“这个任务该使用哪个能力或成本层级”；失败回退回答“当前尝试失败后改用什么”。它们可以组合，但不是同一算法。LiteLLM Router 和 Azure 的 `model-router` 部署也不是同一个组件，前者可以把后者作为一个上游候选 [2][5][14][15]

当前文档既有旧版策略列表，又有新增策略和路由组。不要记“LiteLLM 只有四种/五种策略”。下面覆盖常见的明确名称，是否适用于同步、异步、Responses 或某个插件，应以目标版本实现和针对性请求为准

### 6.2 双部署练习基底

这是**替换最小配置中整个 `model_list` 的片段**。保留原有 `general_settings`，每次只采用一种 `router_settings` 策略。两个上游须支持相同的请求协议及必要功能，不能只因为别名相同就当作等价模型

```yaml
model_list:
  - model_name: study-chat
    litellm_params:
      model: openai/YOUR_DEPLOYMENT_A
      api_base: os.environ/STUDY_API_BASE_A
      api_key: os.environ/STUDY_PROVIDER_KEY_A
      weight: 3
      rpm: 60
      tpm: 30000
    model_info:
      id: study-a
  - model_name: study-chat
    litellm_params:
      model: openai/YOUR_DEPLOYMENT_B
      api_base: os.environ/STUDY_API_BASE_B
      api_key: os.environ/STUDY_PROVIDER_KEY_B
      weight: 1
      rpm: 20
      tpm: 10000
    model_info:
      id: study-b
```

权重和配额数值仅为演示，必须按实际配额修改。尤其是两条配置共享同一上游配额池时，不能把额度算两遍。学习权重时保留 `weight`；研究配额加权时删除两个 `weight`，避免同时变化而解释不清 [2]

### 6.3 策略工作方式、配置与取舍

**`simple-shuffle`：随机或加权选择**。没有相关权重与配额配置时随机选部署；配置 `weight`，或按文档使用 `rpm`/`tpm`，可以影响选择概率。官方目前推荐它作为生产起点，原因是选择开销小。3:1 是长期统计倾向，不代表每四次请求严格三次去 A。它不根据问题难度分配模型，也不能仅凭加权概率保证不触发限流 [2]

```yaml
router_settings:
  routing_strategy: simple-shuffle
  enable_pre_call_checks: true
```

`enable_pre_call_checks` 打开调用前检查，可结合模型信息和部署限制减少明显不合适的尝试，但不是对提供商实时配额的权威查询。同步 SDK 与异步 Proxy 的覆盖需分别验证，不能凭开关名称假设所有限制都完全相同

**`least-busy`：选择进行中请求较少的部署**。它关注未完成调用数量，不是本分钟 token 总数。适合耗时不均匀的并发请求，短串行测试很难体现差异。一个长上下文请求与一个短请求在“数量”上可能都只算一次，因此并发少不等于计算量小。流式完成与取消路径是否及时释放计数也应测试 [2]

```yaml
router_settings:
  routing_strategy: least-busy
```

**`usage-based-routing-v2`：异步配额感知路由**。文档描述其过滤将超过配置 RPM/TPM 的候选，并选择当分钟 TPM 使用量较低的部署，使用异步 Redis 操作共享用量。它看的是使用量，不是简单按“剩余额度百分比”排序。适合需要主动避开配额热点的异步流量，但计数访问增加延迟，Redis 本身也成为依赖 [2][8]

```yaml
router_settings:
  routing_strategy: usage-based-routing-v2
  enable_pre_call_checks: true
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD
```

路由文档的 v2 段落存在示例仍写 `simple-shuffle` 的不一致；要学习 v2，应显式填写 `usage-based-routing-v2` 并确认运行时策略。该页同时警告 usage-based 路由在高流量时的额外性能开销，不应把 v2 的“异步”理解成必然比默认策略吞吐更高

**`latency-based-routing`：依据历史响应时延选择**。通过近期请求更新部署时延，并偏向较快的候选。它不是提前知道下个请求需要多久，冷启动、任务长度、跨区域网络和突发排队都会干扰历史指标。官方提供 `ttl` 调整观察窗口，`lowest_latency_buffer` 放宽候选范围以减少把流量全部压给一个部署 [2]

```yaml
router_settings:
  routing_strategy: latency-based-routing
  routing_strategy_args:
    ttl: 60
    lowest_latency_buffer: 0.5
```

这里的 `0.5` 表示围绕较低时延候选设置相对缓冲，不是固定增加 0.5 秒。应使用相近请求长度预热并比较 p50、p95、首 token 和总完成时间，不能把历史响应时延直接当作 TTFT。窗口过短易抖动，过长则跟不上部署状态变化

**`cost-based-routing`：偏向配置成本较低的健康部署**。官方以异步路由介绍：筛选健康和配额允许的部署，再使用价格映射或自定义价格选择较低成本候选。价格字段是每 token 的美元成本，不是每百万 token。部署名不在价格表中时，文档提到内部默认比较值，不能将它当作真实的“一次请求一美元” [2]

```yaml
router_settings:
  routing_strategy: cost-based-routing
```

下面仅展示某条部署 `litellm_params` 中的**虚构教学价格片段**，不是任何模型报价。每百万 token 报价需要先换算为每 token，并分别核对输入和输出价格

```yaml
input_cost_per_token: 0.000001
output_cost_per_token: 0.000004
```

它不保证最终账单最低：输出长度未知、重试、缓存折扣、上游路由附加费和质量返工都可能改变总成本。更便宜的不同模型放进同组后，语义质量也可能改变。先建立质量门槛，再比较“成功完成一个任务”的成本

**`usage-based-routing`：旧版用量路由**。同样围绕当分钟较低 TPM 用量和配置配额工作，但不是 v2 的异步实现。现有系统可能仍使用它，新项目应先比较默认策略与 v2，不要只因旧配置能加载就继续沿用。切换名称后还要验证异步覆盖、计数、错误与性能，而不是把它当成字符串别名 [2]

```yaml
router_settings:
  routing_strategy: usage-based-routing
  enable_pre_call_checks: true
```

**自定义策略与 hooks**。官方提供 `CustomRoutingStrategyBase` 和 `router.set_custom_routing_strategy(...)`，允许实现同步/异步部署选择。另有路由插件用于缩小候选池和发布信号，以及分类插件用于选择智能路由层级。这些是不同扩展点，不应统称为某个随意编造的 `routing_strategy: custom` [2][18]

优先使用内置策略。自定义扩展需要明确处理无候选、超时、同步/异步差异、权限与冷却状态，不能在插件失败时无条件回退到被策略禁止的模型。当前插件文档标注了版本演进，具体 Proxy YAML 装载位置与 SDK 接口需要按安装版核对，不建议初学者直接复制整套生产插件

### 6.4 智能路由如何与负载均衡组合

当前 Auto Routing 文档介绍启发式评分、LLM 分类器、词汇/语义规则及自定义分类器，先选层级，再选择目标模型或候选池。文档标注从 `v1.94.x` 提供且处于 beta，旧 semantic auto router 已被标记为 deprecated，但仍兼容已有配置。语义匹配只是当前智能路由体系中的一种手段，不能把旧 semantic auto router 当作唯一现行方案；升级前应核对配置与对应版本 [15]

下面是**当前文档风格的可选模型条目片段**，不是 `1.100.0` 已验证配方。它依赖提前配置 `study-small` 和 `study-strong` 两个公开模型组

```yaml
- model_name: study-smart
  litellm_params:
    model: auto_router/complexity_router
    complexity_router_config:
      tiers:
        SIMPLE: study-small
        MEDIUM: study-small
        COMPLEX: study-strong
        REASONING: study-strong
    complexity_router_default_model: study-small
```

启发式不需要额外模型调用，但可能误判中文、代码和隐含难度；LLM 分类器可能更灵活，却增加延迟、费用与失败点。评估应使用真实任务集，比较质量、费用和尾延迟，并记录选择原因。Azure Model Router 则在 Azure 服务内部选模型，LiteLLM 未必能观察其内部决策过程 [14][15]

## 七、重试、冷却与回退

重试是失败后再尝试，可能重用或重选部署；冷却是暂时把持续失败的部署移出候选；回退通常是在当前模型组重试失败后转向另一公开模型组。它们解决可用性，不替代正常流量的负载均衡，也不能让不支持的工具参数突然被支持 [5]

以下是合并到配置的恢复片段。必须先定义 `study-backup` 和 `study-long-context`，并确认它们分别满足原业务和更长上下文需求，否则配置只是悬空的别名关系

```yaml
router_settings:
  routing_strategy: simple-shuffle
  timeout: 60
  num_retries: 1
  allowed_fails: 2
  cooldown_time: 30
  fallbacks:
    - study-chat: [study-backup]
  context_window_fallbacks:
    - study-chat: [study-long-context]
```

`timeout` 不能简单当作应用端总耗时上限，重试等待、多个回退、客户端自己的重试及流式行为会叠加。配置错误和明确不支持的参数应先修正，不应不断重试 400。可用 `retry_policy` 区分错误类型，但须对照版本及异常映射验证 [5][16]

超时不一定意味着上游没执行，连接断开后请求仍可能产生成本。工具调用若由应用执行，还要避免重复副作用。开始输出后的流式失败尤其需要约定：不能把两个模型的半截答案无声拼在一起，也不能承诺切换模型后恢复同一段内部状态

回退目标必须满足权限、地域、数据处理和质量要求。不要把内容策略回退当成规避安全限制的办法。官方文档还描述按具体 `model_info.id` 回退时可能跳过冷却检查，初学者宜先使用普通模型组回退，避免引入特殊语义 [5]

自 Proxy `1.85.0` 起，`mock_testing_fallbacks` 等测试字段在入站请求中被剥离，不能通过普通 Proxy 请求可靠触发回退。直接 Router 单元测试与 HTTP 网关测试必须区分。练习应在隔离环境中制造可控故障并观察真实恢复链路 [5]

## 八、限流、预算与缓存

### 8.1 配额、速率、预算不是同一个数

RPM 控制单位时间请求量，TPM 控制 token 用量，并行请求限制控制在途数量，预算控制累计货币消耗。部署级 `rpm`/`tpm` 用于描述上游承载能力；Key 或团队上的 `rpm_limit`、`tpm_limit` 用于治理客户端。它们既不自动增加 Azure 配额，也不保证与提供商内部计数窗口一致

输出 token 在请求开始时未知，上游可能按估算量或更短窗口限流，其他应用也可能共享同一配额。不要照抄旧资料中的固定 RPM/TPM 换算公式，必须查实际部署的额度与提供商规则

预算依赖可用的花费记录。当前官方明确说明，无数据库 Proxy 不能依赖 `litellm_settings.max_budget` 实施全局花费上限，Virtual Key、团队与用户预算也需要数据库。即使有数据库，并发和延迟写入也可能造成超额，仍需上游限额与告警作为第二道保护 [11][17]

下面是数据库就绪后创建学习 Key 的 PowerShell 示例，假设 `$headers` 是管理员认证头。只把生成的 Key 存入变量，不输出完整响应。不同版本 API 字段以本地管理接口为准

```powershell
$keyBody = @{
  models = @("study-chat")
  key_alias = "handbook-lab"
  duration = "1h"
  max_budget = 1.0
  budget_duration = "1d"
  rpm_limit = 5
  tpm_limit = 2000
} | ConvertTo-Json -Depth 10
$issued = Invoke-RestMethod -Uri "http://127.0.0.1:4001/key/generate" -Method Post -Headers $headers -ContentType "application/json" -Body $keyBody
$studyKey = $issued.key
```

一小时有效期与一天预算周期是不同维度，不意味着自动续期。团队 Key 的预算继承在历史版本发生过变化，当前文档区分团队/成员预算与个人预算。必须用实际身份和实际 Key 验证，不要仅凭 UI 中某个预算字段推断全部继承关系 [4][11]

### 8.2 为什么 LiteLLM 费用不等于云账单

费用估算依赖模型识别、usage、价格表及自定义定价。自定义部署别名、错误的模型元数据、reasoning token、缓存读写价格、批处理、Router 服务附加费和价格更新都可能影响准确性。网关对一次请求显示零费用，可能是缓存命中，也可能是价格缺失或没有识别完整 usage [4][12]

对账至少保留调用时间、网关 call ID、公开组、部署 ID、上游返回模型、token 细分和费用。用提供商账单核对采样窗口，尤其对经 OpenAI-compatible 入口调用的非 OpenAI 服务。记录价格表版本，避免相同请求在升级前后采用不同价格却没有解释

### 8.3 两层缓存

**LiteLLM 响应缓存** 保存生成结果，相同请求命中后可能不调用上游。**上游 prompt caching** 复用输入前缀计算，仍然进行模型请求和生成，通常只影响部分输入成本与延迟。一个缓存命中标志不能证明另一个也命中 [7][12]

以下为单 worker 实验合并片段，不适合多副本共享缓存

```yaml
litellm_settings:
  cache: true
  cache_params:
    type: local
```

精确缓存要求缓存键对应相同请求语义，动态时间、工具结果或参数变化通常导致未命中。语义缓存基于相似度复用结果，可能把“看起来相似”的不同需求混淆，对多轮 Agent 和权限相关数据尤其危险。缓存范围、TTL、租户隔离和删除机制都要明确 [7]

上游 prompt cache 应查看协议对应的 cached token 字段，例如 Chat 的 `prompt_tokens_details.cached_tokens` 或 Responses 的输入 token 细分。不要用 Anthropic 专有的缓存写入字段判断所有提供商。不同模型的长度门槛、有效期和缓存标记要求不同，需要查询提供商说明 [12]

多 worker 或多副本时，Redis 应分别接入所需 Router 状态和 Proxy/缓存路径。当前官方说明仅设置环境变量不一定启用所有使用点；路由状态配置与响应缓存配置不是同一件事。没有 Redis 时，局部计数、冷却和 Key 失效传播可能不一致，不能把某个 worker 的正确行为当作全局一致性 [8]

## 九、可观测性与生产边界

### 9.1 应该观察什么

一次调用的最小证据包应包含脱敏请求、HTTP 状态、错误体、网关版本、call ID、实际部署 ID、响应模型、usage 和总耗时。`x-litellm-call-id` 适合串联日志，`x-litellm-model-id` 适合验证分流；响应头可能因版本或网关转发配置缺失，需要结合服务日志判断 [19]

模型说“我是某某型号”不是身份凭证。`response.model` 更有用，但它也必须结合提供商协议和适配结果解释。直接路由与上游智能路由的可见信息不同，不能声称公开别名证明了内部具体模型

健康检查分层进行：`/health/liveliness` 主要回答进程是否存活；`/health/readiness` 判断能否接收流量及相关依赖；`/health` 可发起真实模型调用，可能收费。把 `/health` 当作高频存活探针会产生不必要成本，多个副本还可能放大检查流量 [20]

### 9.2 生产上线前的关键边界

部署版本、镜像 digest、数据库迁移、有效配置和加密密钥必须可追溯。升级先在隔离环境恢复配置并运行协议回归，再灰度流量。数据库迁移之后，旧镜像未必能直接读取新结构，回滚计划不能只有“换回旧 tag”

扩容要同时计算数据库连接池。副本数乘 worker 数乘每 worker 连接上限，可能远超数据库承载。Redis 也需监控连接、延迟、内存和失效行为。先确认瓶颈来自上游、网关、数据库还是 Redis，再增加副本 [10]

日志可能包含 prompts、工具参数、文件内容、认证相关元数据和资源地址。关闭正文日志不等于所有调试输出都已脱敏，应分别检查 console、追踪回调和数据库记录。只有组织批准后才接入外部可观测平台，生产不长期打开 `--detailed_debug` [19]

最后给配置建立契约：哪些模型支持哪个协议、哪些工具和 Schema、上下文上限来自哪里、哪些回退可以接受、失败时是否允许降级。升级回归围绕这些契约，而不是只发一次“你好”

### 9.3 Guardrails 与 Hook：检测、拒绝和修改请求

Guardrails 把输入检测、PII 脱敏、输出审核等策略接入模型调用。`pre_call` 在上游调用前检查输入，适合必须阻止敏感内容离开网关的场景；`during_call` 与上游请求并行执行输入检查，可能减少等待，但不能保证敏感输入未发送；`post_call` 检查返回结果，不能撤销已经发生的上游请求与费用。具体集成支持哪些阶段，需要核对其文档 [21]

流式输出还需要考虑检查时机。已经交付给客户端的片段不能收回，因此“返回前审核”和“边生成边返回”之间存在真实取舍。外部检测服务不可用时，是拒绝请求还是继续处理，应由业务明确决定并记录，而不是用默认行为代替安全设计

配置入口通常是 YAML 的 `guardrails` 段，已部署版本的 UI 也可能提供相应集成与设置。先选择支持目标协议的检测器，再配置 `guardrail_name`、具体 `guardrail` 类型、执行 `mode` 及独立凭据。不同集成需要不同字段，本手册不把某个厂商的配置当作所有 Guardrail 通用模板

Hook 是另一类扩展：它允许加载自定义 Python 逻辑。官方提供 `async_pre_call_hook` 修改或拒绝入站请求，成功、失败与流式输出也分别有对应 Hook。一般通过 YAML 的 `litellm_settings.callbacks` 注册处理器实例，Python 模块必须能被实际运行的 Proxy 导入；仅把文件放在宿主仓库，不会自动进入没有挂载该文件的容器 [22]

例如只对某个模型组过滤某个工具，应同时限定适用模型、客户端或调用类型，记录过滤行为，并分别验证 Chat 与 Responses 的工具形状。删除工具声明会改变模型可用能力，随意删掉 `oneOf` 则可能放宽参数约束。请求不再报错，不代表计划任务创建、参数校验或工具结果回传仍然正确。`drop_params` 不能替代这种有明确范围的兼容实现

学习时先用无敏感内容验证“不匹配请求保持不变、匹配请求被拒绝或按预期修改、流式与非流式结果一致”，再测试日志脱敏、错误可见性和撤销配置。此处是扩展方法说明，没有对当前运行服务安装 Guardrail 或 Hook

## 十、Foundry 有界案例：怎样从现象得到可靠结论

本章参考同目录的 [Codex、LiteLLM 与 Foundry 实践记录](codex-litellm-foundry-practice.md)，并以 2026-09-10 最终补充证据校正早期判断。这里的 `Router` 指 Azure Model Router，不是 LiteLLM 的 Router 类。结果仅覆盖当时的资源、项目、部署、请求和运行中的 LiteLLM `1.100.0`

基础文本实验中，资源级 Responses 对 GPT Sol 成功、对 Router 返回不支持操作；项目级 Responses 对两者成功。这说明当时应选择测通的入口，不能推出“Router 永远不支持 Responses”。微软当前文档明确展示通过项目客户端使用同一 `responses.create()` 调用 Router 或指定部署 [14]

工具 Schema 的最终对照更重要：

| 被测路径 | 根级 `oneOf` | 补充证据 |
|---|---|---|
| 项目级 Responses，GPT Sol 部署 | 成功 | 不能泛化成所有 GPT/接口都成功 |
| 项目级 Responses，Router 部署 | 拒绝 | 绕过 LiteLLM 直接调用 Azure 仍复现 |
| 项目级 Responses，Router 部署，改为属性内嵌套 `oneOf` | 成功 | 是已观察的可行形状，不是全量 Schema 保证 |
| 资源级 Chat Completions，GPT Sol 与 Router | 两者都拒绝根级形状 | Chat 与 Responses 的结果不能混用 |

直接上游复现说明该项错误不依赖 LiteLLM 才发生，但**不能证明拒绝发生在 Router 前置校验、底层模型还是内部协议转换阶段**。没有内部追踪就不应编造根因，更不能写成“Azure 全面禁止根级 `oneOf`”

另一个独立问题是适配路径。本次 `openai/` 配合已测通的项目级 OpenAI-compatible Base 使用原生 Responses。`openai/` 不是 Azure AI 专用适配器；运行中的 `1.100.0` 没有 `azure_ai` 的原生 Responses 注册，相关请求会自动走 Chat 桥接，即使 `use_chat_completions_api` 为 false。这是版本与路径结论，不是最新版本的永久能力判断

早期桥接流式路径还遇到空 `choices` 事件问题，切换原生路径绕开了它，但没有修复桥接实现。UI 的 Mode 主要关联健康检查接口选择，不能当作 Azure Router 的质量/成本模式，更不是保证原生协议的开关 [20]

本案例的可迁移方法是做对照矩阵：固定 Key 与请求，分别改变端点、部署、协议和 Schema；有必要时绕过网关重放；把“已观察”“已排除”“尚未证明”分开。项目 Key 曾成功、某个 Entra 身份曾被拒绝，也只能说明当时调用和权限状态，不能推出所有 Foundry API 接受同一种认证

## 十一、排错决策树与递进实验

### 11.1 先定位失败层

```text
请求失败
  |
  +-- TCP/TLS 不通
  |     检查端口、监听地址、代理、证书与 DNS
  |
  +-- 网关 401/403
  |     区分 Master/Virtual Key，检查到期、模型权限与团队规则
  |
  +-- 找不到模型 / 404
  |     核对公开别名、有效模型列表、上游部署和 URL 拼接
  |
  +-- 400 / unsupported parameter
  |     固定部署，删到最小请求，分辨 Chat/Responses 与 Schema 层级
  |     直接上游也失败：继续查上游契约，不先修改 LiteLLM
  |     只有网关失败：对比适配器、实际路径、转换和版本
  |
  +-- 429 / no available deployments
  |     区分网关限流、预算、上游配额、冷却和候选被过滤
  |
  +-- 非流式成功，流式或工具失败
  |     检查 SSE 完成事件、工具 ID、参数分片、结果回传与桥接
  |
  +-- 调用成功，日志/费用异常
        核对 usage、价格映射、缓存、异步写入与数据库连接
```

### 11.2 实验阶梯

下表是操作计划，所有“预期”都需要读者实际执行并记录。每轮先设上游小额限额，用无敏感内容的请求，保存脱敏证据。任何实验都不得修改现有 Docker 服务、真实生产 Key 或共享数据库

| 阶段 | 操作 | 应留下的可观察证据 | 回滚 |
|---|---|---|---|
| A：单部署 | 用第四章配置完成文本调用，再列模型 | 版本、公开别名、状态、部署 ID、usage | Ctrl+C 停止学习进程 |
| B：协议 | 对确认支持 Responses 的上游先直接请求，再经网关请求；测试流式和工具回传 | 两端请求差异、完成事件、相同工具调用 ID 的闭环 | 回到已测通协议，不保留未经验证的桥接开关 |
| C：权限 | 专用数据库创建只允许 `study-chat` 的 Key，再调用另一个已配置别名 | 允许请求成功，未授权请求被网关拒绝且未到达上游 | 在 UI 删除本次 Key，确认新请求失效 |
| D：负载 | 使用双部署 3:1 权重，逐步积累少量短请求 | 按部署 ID 计数，分布逐渐有偏向而非严格轮询 | 恢复单部署配置 |
| E：策略 | 同一任务集分别测试默认、least-busy 与 latency 策略 | 并发在途数、首 token、总耗时、错误率和价格 | 一次只恢复一个策略字段 |
| F：故障 | 在专用测试端点制造可控 503 或关闭仅用于实验的后端，再发普通请求 | 错误、重试次数、冷却时间、备用部署 ID | 恢复后端与原配置，确认冷却后恢复 |
| G：缓存/预算 | 先重复完全相同请求，再关闭响应缓存测试上游 prompt cache；使用小额 Key 观察预算 | 缓存命中与上游调用次数、cached tokens、花费延迟与拒绝证据 | 关闭缓存、删除本次 Key，不清空共享 Redis |
| H：重启恢复 | 专用库新增一个模型，重启学习进程；修改 YAML 同名条目观察来源 | DB 模型仍存在，来源和实际部署列表可解释 | 只删除本次 DB 模型，恢复原学习 YAML |

权重实验可复用第四章变量，每次收集状态与部署 ID，不打印认证头。十次调用只验证观测方法，不能证明概率正确；扩大样本前先确认成本

```powershell
$observations = 1..10 | ForEach-Object {
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:4001/v1/chat/completions" -Method Post -Headers $headers -ContentType "application/json" -Body $body
  [pscustomobject]@{
    Status = $r.StatusCode
    Deployment = [string]$r.Headers["x-litellm-model-id"]
  }
  Start-Sleep -Seconds 4
}
$observations | Group-Object Deployment | Select-Object Name, Count
```

排错练习的完成标准不是“最终返回 200”，而是能够解释请求使用了哪个身份、哪种协议、哪个模型组、哪条部署、为什么选它，以及费用是否有可靠依据。对生产准备而言，还应能证明重启、密钥撤销和故障恢复不会破坏这些约束

## 十二、术语与参考索引

### 12.1 术语速查

| 术语 | 在本手册中的含义 |
|---|---|
| Provider adapter | 提供商或协议适配实现，决定参数、认证与路径处理 |
| Public model name | 客户端调用的稳定别名 |
| Model group | 一组共享公开别名的候选部署 |
| Deployment | 一个实际可选择的上游配置，不一定等于独立配额池 |
| Native / bridge | 原生调用对应接口 / 在不同 API 形状间转换 |
| Control plane / data plane | 配置管理 / 实际业务请求 |
| Virtual Key | 网关发给应用的受控访问令牌 |
| Cooldown | 部署故障后暂时不参与普通选择 |
| Fallback | 原请求失败后转向其他模型组或明确目标 |
| RPM / TPM | 每分钟请求数 / token 用量限制 |
| TTFT | 从发出请求到首个输出 token 的时间 |
| p95 | 95% 观测值不超过的分位点，不是平均值 |
| Response cache | 复用完整生成结果的网关缓存 |
| Prompt cache | 上游复用输入前缀计算的缓存 |
| Spend | LiteLLM 根据 usage 和价格规则记录的消耗 |
| Salt Key | 数据库凭据加解密所需秘密，不是 Virtual Key |
| Image digest | 用内容摘要固定容器镜像，避免浮动标签变化 |

### 12.2 官方资料索引

下列网页均直接查阅于 **2026-09-11**。链接指向持续更新的官方页面，不是锁定 `1.100.0` 的快照。文档中的旧模型名、旧 API 日期和复制错误没有被当作通用安装参数照搬

| 编号 | 官方资料与用途 | 完整 URL | 查阅日期 |
|---|---|---|---|
| [1] | LiteLLM 首页，SDK、Proxy 与能力入口 | https://docs.litellm.ai/docs/ | 2026-09-11 |
| [2] | Router，负载均衡、策略与自定义选择 | https://docs.litellm.ai/docs/routing | 2026-09-11 |
| [3] | Proxy 配置、模型映射、数据库覆盖规则 | https://docs.litellm.ai/docs/proxy/configs | 2026-09-11 |
| [4] | Virtual Key、权限与使用量 | https://docs.litellm.ai/docs/proxy/virtual_keys | 2026-09-11 |
| [5] | Fallback、重试、冷却与测试边界 | https://docs.litellm.ai/docs/proxy/reliability | 2026-09-11 |
| [6] | Responses API 入口和跨提供商支持 | https://docs.litellm.ai/docs/response_api | 2026-09-11 |
| [7] | Proxy 响应缓存 | https://docs.litellm.ai/docs/proxy/caching | 2026-09-11 |
| [8] | 哪些状态需要 Redis | https://docs.litellm.ai/docs/proxy/redis_requirements | 2026-09-11 |
| [9] | 模型管理、UI 与 YAML 来源 | https://docs.litellm.ai/docs/proxy/model_management | 2026-09-11 |
| [10] | 生产配置、Salt Key、连接与刷新 | https://docs.litellm.ai/docs/proxy/prod | 2026-09-11 |
| [11] | 用户、团队、全局预算与数据库要求 | https://docs.litellm.ai/docs/proxy/users | 2026-09-11 |
| [12] | 上游 prompt caching 与 usage | https://docs.litellm.ai/docs/completion/prompt_caching | 2026-09-11 |
| [13] | Azure Responses 适配与调用方式 | https://docs.litellm.ai/docs/providers/azure/azure_responses | 2026-09-11 |
| [14] | Microsoft Foundry Responses 模型路由 | https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses-model-routing | 2026-09-11 |
| [15] | Auto Routing、分类方式与 beta 边界 | https://docs.litellm.ai/docs/proxy/auto_routing | 2026-09-11 |
| [16] | 配置参数参考 | https://docs.litellm.ai/docs/proxy/config_settings | 2026-09-11 |
| [17] | Gateway Quickstart 与无数据库限制 | https://docs.litellm.ai/docs/proxy/docker_quick_start | 2026-09-11 |
| [18] | 路由插件职责与版本演进 | https://docs.litellm.ai/docs/routing_plugins | 2026-09-11 |
| [19] | 日志、call ID 与消息脱敏 | https://docs.litellm.ai/docs/proxy/logging | 2026-09-11 |
| [20] | 健康探针、真实模型检查与 Mode | https://docs.litellm.ai/docs/proxy/health | 2026-09-11 |
| [21] | Guardrails、执行阶段与配置入口 | https://docs.litellm.ai/docs/proxy/guardrails/quick_start | 2026-09-11 |
| [22] | 请求改写、拒绝和响应处理 Hook | https://docs.litellm.ai/docs/proxy/call_hooks | 2026-09-11 |

尚待目标环境验证的事项包括：`1.100.0` 的全部协议/策略组合、新版插件配置与 UI 覆盖细节、组织实际授权、分布式预算超额幅度、上游 Router 的完整计费以及特定 Schema 的内部拒绝阶段。它们应进入实验记录，不能用“官方支持”四个字代替验证
