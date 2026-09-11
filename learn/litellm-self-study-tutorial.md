# LiteLLM 自学教程：从一次成功调用到理解模型网关

资料核对日期：2026-09-11

**适合谁：**你已经启动了一个 LiteLLM 实例，配置了一个模型，发过请求，也看过日志。你有基本编程经验，但还不了解 LiteLLM 的路由、权限、限流、预算、缓存和监控

**这份文档怎么用：**把它当作教程正文，边读边做，不需要先读完全部官方文档。正文先解释一个实际问题，再引入解决它的功能。每章都有操作、观察标准、容易误判的地方和自测答案。原来的 [学习手册](litellm-learning-handbook.md) 留作较密集的查阅材料

**时间安排：**第一遍阅读约 2–3 小时；完成基础实验约 3–5 小时。数据库、Redis 和第二个部署的准备时间另算。这是学习安排建议，不是实测完成时间

**事实边界：**本文依据文末官方来源编写，没有运行你的实例，没有调用你的模型，没有验证你部署的具体版本。所有“预期结果”都是验收目标，不是本次执行记录。当前在线文档、仓库代码和你的安装版本可能不同。遇到不一致时，先核对运行版本与对应接口，不要为了追随教程直接升级原有服务

---

## 学习导航：先学会解释，再增加组件

你已经证明“请求能够成功”。下一步是能够解释：请求经过了谁，凭什么被允许，为什么选中这个部署，失败后会怎样，最后产生了什么成本

| 阶段 | 章节 | 你要获得的能力 | 实验资源 |
|---|---|---|---|
| 建立基础 | 0–2：实验边界、请求链路、配置 | 能区分客户端、网关与上游，读懂模型配置 | 当前实例、一个模型 |
| 理解接口 | 3：流式、Responses、工具调用 | 能判断“接口返回成功”是否等于应用真正可用 | 一个支持相应能力的模型 |
| 管好访问 | 4–5：Key、用户团队、配置持久化 | 应用不再共用管理员凭据，知道配置存在哪里 | 独立测试 PostgreSQL |
| 理解可靠性 | 6–7：路由、重试、冷却、回退 | 能解释部署选择与失败恢复 | 路由对比需要两个可区分部署 |
| 控制消耗 | 8–10：限流、预算、缓存 | 分清吞吐、费用与重复计算 | Key 实验需数据库；缓存需 Redis |
| 学会运营 | 11–13：日志监控、生产边界、扩展能力 | 知道怎样验证健康、怎样定位故障、下一步学什么 | 部分练习只需现有实例 |
| 综合练习 | 14：毕业实验 | 用证据解释一次成功和一次失败 | 按已经具备的资源选择 |

只有一个模型也能完成大部分概念学习、协议实验和日志观察。暂时没有数据库或 Redis 时，照常阅读对应章节，完成纸面推演，给实操标记“待资源就绪”。不要把“我理解了原理”记成“我已验证了运行行为”

---

## 第 0 章：给学习划出边界，不把现有实例当故障试验场

### 0.1 为什么先做这一步

假设你已经让一个编辑器通过 LiteLLM 调用模型。为了学习 fallback，你把上游地址改错。如果改的是编辑器正在使用的配置，学习过程就变成了服务中断

因此，本文区分两个目标：对当前实例做读取与少量正常请求；把配置变更、无效地址、限流、Key 撤销等实验放在独立学习实例。客户端请求端口约定为 `4001`，不是要求你改掉正在使用的 `4000`

**本教程不要求更换现有模型。**模型示例统一用你已成功使用的部署，公开别名叫 `study-chat`。这个别名不是供应商型号，也不代表某个最新模型

### 0.2 先记录五件事

在你自己的学习记录中填下面的表，不记录实际密钥。启动方式不同，查版本的方法也不同，不能拿本机另一个 Python 环境的版本代替容器里的版本

| 项目 | 记录内容 |
|---|---|
| 运行方式 | Docker、Python CLI，还是其他方式 |
| 运行版本 | 运行进程内安装的 LiteLLM 版本，以及容器镜像 ID（如适用） |
| 客户端入口 | 例如 `http://127.0.0.1:4000`，是否还经过其他反向代理 |
| 已成功的公开模型名 | 请求 JSON 的 `model`，不是云控制台上的资源名 |
| 配置来源 | YAML、Admin UI、数据库，或者混合 |

Python CLI 环境可以在**启动服务的同一环境**查询。Docker 环境则对你明确选中的容器查询，下面不会输出容器环境变量

```powershell
python -c "from importlib.metadata import version; print(version('litellm'))"
```

```powershell
$ContainerName = Read-Host "现有 LiteLLM 容器名"
docker exec $ContainerName python -c "from importlib.metadata import version; print(version('litellm'))"
docker inspect --format '{{.Image}}' $ContainerName
```

预期得到一个包版本号；Docker 第二条命令得到本地镜像 ID。若提示找不到 Python 或容器，先根据实际启动方式修正查询，不能把查询失败理解为 LiteLLM 没装

### 0.3 准备统一的客户端变量

本文命令使用 **PowerShell 7**，工作目录为仓库根目录。Windows PowerShell 5.1 不支持文中部分参数，例如 `-SkipHttpErrorCheck`。先在终端执行 `$PSVersionTable.PSVersion`，确认主版本至少为 7

先对当前实例做基础观察时填它的地址；进入独立实验后重新运行这一段，把地址换成 `http://127.0.0.1:4001`。地址末尾不要附加 `/v1`，后续命令会自己追加路径

```powershell
$ErrorActionPreference = "Stop"
$BaseUrl = (Read-Host "网关地址，不带 /v1，例如 http://127.0.0.1:4000").TrimEnd("/")
$ModelAlias = Read-Host "已经成功调用过的公开模型名"
$GatewayKey = Read-Host "网关 Key，无认证的本机学习实例可留空" -MaskInput
$AuthHeaders = if ([string]::IsNullOrWhiteSpace($GatewayKey)) {
    @{}
} else {
    @{ Authorization = "Bearer $GatewayKey" }
}
$OutputLimit = @{ max_tokens = 128 }
```

`$OutputLimit` 用来限制实验输出规模。若你已经确认该模型使用 `max_completion_tokens` 而不是 `max_tokens`，将最后一行改为 `@{ max_completion_tokens = 512 }`。部分推理模型会把推理 token 算在上限内，过低可能没有可见文本。按该模型官方要求调整，不要通过静默丢弃参数绕过错误

> **注意：**限制输出数量不等于精确限制金额。模型调用、工具往返和某些健康检查都可能收费。正文不执行这些命令，由你决定哪些请求可以发出。不要开启终端录屏或 transcript 后输入真实凭据

### 0.4 为后续实验准备一个独立实例

如果你已有隔离的学习实例，可跳到第一章。否则，第二章会给出最小配置，再用下面对应的启动方法。先不要运行一个配置尚未准备好的命令

Python CLI 路线：使用你已经安装且能够启动 LiteLLM 的环境，不额外升级包。确认 `4001` 未占用，准备好第二章的文件后，在单独终端前台运行

```powershell
Get-NetTCPConnection -LocalPort 4001 -ErrorAction SilentlyContinue
litellm --config .\learn\lab-config.yaml --host 127.0.0.1 --port 4001
```

端口查询有结果就换一个未使用端口，并同步修改 `$BaseUrl`。无结果只是没查到该监听端口，最终仍以启动是否成功为准。停止时，在这个专门的终端按 `Ctrl+C`，不要按进程名称批量结束服务

Docker 路线：复用现有容器对应的本地镜像，不下载浮动 `latest`。第二章准备好文件与环境变量后，执行下面命令。它不会复制原容器的数据库或持久化卷

```powershell
$LabImage = docker inspect --format '{{.Image}}' $ContainerName
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LabImage)) {
    throw "无法确定原容器镜像，停止创建实验实例"
}
$LabConfig = (Resolve-Path .\learn\lab-config.yaml).Path
docker run --rm --name litellm-study-lab `
    -p 127.0.0.1:4001:4000 `
    --mount "type=bind,source=$LabConfig,target=/app/config.yaml,readonly" `
    -e LAB_MODEL -e LAB_API_BASE -e LAB_UPSTREAM_API_KEY -e LITELLM_MASTER_KEY `
    $LabImage --config /app/config.yaml --host 0.0.0.0 --port 4000
```

这条命令适用于现有 LiteLLM 镜像使用标准 CLI 入口的情况。若原容器自定义了入口，按自己的启动定义另建实例，不要通过修改原容器来适配示例。`--rm` 表示停止后删除本次临时容器，配置文件仍在宿主机；不要给它挂载生产数据卷

容器中的 `127.0.0.1` 指容器自身。后续连接宿主机上的上游、数据库或 Redis 时，需要使用该容器可达的地址，Docker Desktop 通常可用 `host.docker.internal`

**完成标准：**你知道每个实验会访问哪个实例，知道怎样只停止实验实例，且没有复制生产数据库连接串或明文凭据到文档中

官方依据：[配置与启动][S1]、[Gateway Quickstart][S2]

---

## 第 1 章：重新看一次已经成功的请求

### 1.1 同样是“调用模型”，三层职责不同

你有一个问答脚本，原来直接调用供应商。现在脚本改为调用 LiteLLM。供应商 API Key 留在网关，脚本拿到的是网关允许使用的凭据

**客户端**负责组织请求和处理响应。**Proxy** 是接收 HTTP 请求的网关进程。**Provider 适配器**负责把请求转换为对应上游接受的地址、参数和认证形式。后面会学的 **Router** 负责从配置的候选部署中选择一个去调用

LiteLLM 也提供可以嵌入 Python 程序的 **SDK**。使用 Proxy 的客户端不需要安装 LiteLLM SDK，可以使用 HTTP 或兼容的客户端库

```text
你的问答脚本
    |
    | 网关地址、公开模型名、网关 Key
    v
LiteLLM Proxy
    |
    | 认证与治理；有多个部署时交给 Router 选择
    v
Provider 适配器
    |
    | 上游地址、上游模型标识、上游凭据
    v
真正执行推理的模型服务
```

这是一张职责图，不是每个接口内部函数的严格执行顺序。缓存、插件和协议转换可能改变实际流程

### 1.2 先读模型目录，再发请求

先请求模型目录，确认你使用的凭据能够看见什么。它只检查入口与可见范围，不会证明每个模型都能推理

```powershell
$Catalog = Invoke-RestMethod -Uri "$BaseUrl/v1/models" -Headers $AuthHeaders
$Catalog.data | Select-Object id
```

预期列表包含你准备调用的别名。如果没有，先检查 `$BaseUrl`、身份权限和实际加载的配置，不要去猜供应商型号

接着发送一个短请求，保留状态码、响应头和正文，后面几章会重复用到 `$ChatJson`

```powershell
$ChatPayload = @{
    model = $ModelAlias
    messages = @(
        @{ role = "user"; content = "Reply with one short greeting." }
    )
} + $OutputLimit
$ChatJson = $ChatPayload | ConvertTo-Json -Depth 12
$ChatHttp = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" `
    -Headers $AuthHeaders -ContentType "application/json" -Body $ChatJson
$Chat = $ChatHttp.Content | ConvertFrom-Json
$ChatHttp.StatusCode
$Chat.choices[0].message.content
$Chat.usage
```

预期得到 HTTP 200、一个完成响应，以及模型返回的内容。回答不必逐字相同。`usage` 是用量结构，通常包括输入和输出 token 数；**token 是模型处理文本的计数单位，不等于一个汉字或一个单词**

如果文本为空，先看 `finish_reason`、是否有 `tool_calls`、输出上限是否被推理消耗，不要立刻判定“模型没工作”。如果 `usage` 缺失，应单独记录用量链路问题，不能自动按零费用处理

### 1.3 在日志里认出同一次请求

响应头可能含有请求标识、部署标识和成本信息。先读取下列候选字段，不把“没有某个头”当作请求失败

```powershell
$ChatHttp.Headers["x-litellm-call-id"]
$ChatHttp.Headers["x-litellm-model-id"]
$ChatHttp.Headers["x-litellm-response-cost"]
```

用实际返回的 call ID 或同一时间、模型别名去日志中定位请求。记录“入口别名、被选部署、状态、耗时、用量”，不要复制包含 Key 或完整用户内容的日志到公共位置

> **容易误判：**回答里模型自称某个型号，不是实际路由证据。模型可能不知道部署名称，回答可能来自提示词。优先看部署 ID、受控上游记录和服务端日志

### 1.4 自测与答案

**问题：**模型目录能读，为什么生成请求仍可能失败？同一次 200 响应能否证明成本落库成功？为什么客户端与上游的 Key 不应该混用？

**答案：**模型目录验证的是目录可见性，不验证上游网络、权限和协议。文本返回与成本识别、异步日志落库是不同结果。网关 Key 用于网关准入，上游 Key 用于供应商认证，权限范围和泄露后果不同

本章完成后，你已经把“成功了”拆成了几件可以分别验证的事：入口可见、模型推理、结果返回、用量记录

官方依据：[配置与模型名][S1]、[响应头][S3]、[成本跟踪][S4]

---

## 第 2 章：读懂配置，而不是背 YAML

### 2.1 为什么需要公开别名

假设问答脚本里到处写着供应商部署名称。换供应商时，每个脚本都要改。你可以让应用始终请求 `study-chat`，把实际部署映射留在网关里

这个稳定名字就是 **公开模型别名**，对应 `model_name`。它是入口名称，不会把一个模型变成另一个模型

| 配置 | 回答的问题 | 例子 |
|---|---|---|
| `model_name` | 应用请求哪个名字 | `study-chat` |
| `litellm_params.model` | 使用哪个适配器与上游标识 | `openai/实际部署名` |
| `api_base` | 上游服务在哪 | 已经成功使用的基础地址 |
| `api_key` | 用什么认证上游 | `os.environ/LAB_UPSTREAM_API_KEY` |
| `model_info.id` | 这条候选配置是谁 | `study-primary` |

`openai/` 在这里表示 OpenAI 协议适配路径，不保证请求发往 OpenAI 公网。`api_base` 可以是其他兼容服务。不能仅凭供应商控制台名字，决定使用哪个 LiteLLM 适配器

### 2.2 建立一个可恢复的基线

下面是 **OpenAI-compatible 上游**的完整最小示例。若你现有成功配置使用 Azure 专用参数、Bedrock、Vertex 等，请复制自己已经验证的 `litellm_params` 结构，只改公开别名和部署 ID，保留所需的 `api_version`、区域、身份认证等字段。不要强行套成 OpenAI-compatible

在 `learn\lab-config.yaml` 新建以下内容。该文件是你动手时创建的私有实验文件，本文没有替你生成或填入任何凭据

```yaml
model_list:
  - model_name: study-chat
    litellm_params:
      model: os.environ/LAB_MODEL
      api_base: os.environ/LAB_API_BASE
      api_key: os.environ/LAB_UPSTREAM_API_KEY
    model_info:
      id: study-primary

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

在**启动学习实例的终端**设置变量。`LAB_MODEL` 填已经成功使用的完整 LiteLLM 模型标识，不是 `study-chat`。基础地址保留已有成功配置的路径，不在末尾追加 `/chat/completions`

```powershell
$env:LAB_MODEL = Read-Host "已验证的适配器/上游模型标识"
$env:LAB_API_BASE = Read-Host "已验证的上游基础地址"
$env:LAB_UPSTREAM_API_KEY = Read-Host "上游 API Key" -MaskInput
$env:LITELLM_MASTER_KEY = Read-Host "仅本实验使用的强随机 master key，以 sk- 开头" -MaskInput
```

`os.environ/变量名` 是 LiteLLM 的环境变量引用形式。它减少密钥出现在 YAML 中的风险，但不是密钥保险箱。进程环境仍然需要访问控制，不要公开完整的 `docker inspect` 输出

按第 0 章启动独立实例。然后在客户端终端重新设置 `$BaseUrl` 为学习入口、`$ModelAlias` 为 `study-chat`，输入刚设置的学习 master key，并重建 `$AuthHeaders`。重新执行第一章请求

**预期：**客户端仍可得到有效响应，使用的公开模型名是 `study-chat`。若未启动成功，先确认变量存在于服务进程中，而不是只存在于另一个终端

### 2.3 四个配置区块，各管一类事情

以后看到大配置时，先按区块分类，不要逐字读完才开始理解

| 区块 | 管什么 | 本教程后续例子 |
|---|---|---|
| `model_list` | 候选模型部署 | 加入第二个部署 |
| `router_settings` | 选择部署与可靠性 | 策略、重试、超时、fallback |
| `litellm_settings` | LiteLLM 模块行为 | 响应缓存、监控 callback |
| `general_settings` | 网关管理行为 | master key、配置存储 |

**后续 YAML 片段都是对这份学习配置的合并修改。**已有 `router_settings` 时，把字段放进原区块，不要再添加同名顶层区块。每章结束后恢复本章修改，下一章从干净基线开始

不要对未知字段先加 `drop_params: true`。它允许丢弃不支持的模型请求参数，可能让请求从报错变成 200，同时失去你想测试的语义。学习阶段应该弄清哪个参数不兼容

### 2.4 小练习：只改入口名

在独立实例的文件中把 `model_name` 改成 `study-chat-renamed`，上游配置不变，重启该学习实例。先请求原别名，再请求新别名

**预期：**在没有别名映射、通配配置或数据库同名条目的干净环境中，原别名不可用，新别名能调用同一个上游。若两个名字都还能用，检查是否加载了错误的文件，或有其他配置来源

练习后恢复 `study-chat` 并重启。把客户端变量也恢复，避免后面误以为其他功能坏了

### 2.5 自测与答案

**问题：**更改 `model_name` 会提升上下文长度吗？`api_base` 应该指向自己这台网关吗？为什么 YAML 引用的变量在终端里有值，服务仍可能读不到？

**答案：**别名不改变模型能力。`api_base` 指向真正上游，误指回自己可能形成递归。进程通常继承启动时的环境，另一个终端的变量不会自动进入已经启动的进程或容器

官方依据：[配置语义][S1]、[配置参数参考][S5]

---

## 第 3 章：普通文本成功之后，还需要验证什么

### 3.1 流式响应：收到数据，不等于收到完整答案

普通请求像一次性交卷，服务完成后返回整份 JSON。**流式响应**把结果分段传回，用户可以较早看到内容。常见传输形式是 **SSE**，即在一个 HTTP 连接上持续发送文本事件

流式体验涉及两个不同时间：**首 token 时间**是等待第一段有效输出的时间；**总耗时**是直到流结束的时间。更早开始输出，不保证更快结束

先在已有请求上加 `stream`。下面为了保持依赖简单，用 PowerShell 收集原始事件后显示，**它检查事件格式，不测实时首 token 延迟**

```powershell
$StreamPayload = @{
    model = $ModelAlias
    messages = @(
        @{ role = "user"; content = "Count from one to five in words." }
    )
    stream = $true
} + $OutputLimit
$StreamHttp = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" `
    -Headers $AuthHeaders -ContentType "application/json" `
    -Body ($StreamPayload | ConvertTo-Json -Depth 12)
$StreamHttp.Headers["Content-Type"]
$StreamHttp.Content
```

对于 Chat 流，预期看到多段 `data:` 事件，内容片段通常在 `choices[].delta`，完成时有结束信号。不要把整个事件串直接 `ConvertFrom-Json`，它不是一个完整 JSON 对象

要观察“边生成边显示”，在你已使用的客户端开启流式显示，或者使用支持 SSE 的客户端逐事件读取。不要根据上述缓冲命令的显示方式判断服务器是否真的流式

> **容易误判：**连接返回 HTTP 200 后仍可能在中途报错或断开。客户端需要处理结束信号、错误事件和不完整输出。空文本片段也可能承载角色、工具参数或用量，不应直接判定为无效

### 3.2 Chat 与 Responses：入口格式不同

**Chat Completions** 主要用 `messages` 输入、`choices` 输出。**Responses API** 主要用 `input` 输入、`output` 输出，还可能包含工具调用、推理等不同类型的输出项

如果你的应用要用 Responses，就要实际测试该入口，而不是只测试 Chat 后推断它一定兼容

```powershell
$ResponsesPayload = @{
    model = $ModelAlias
    input = "Reply with one short greeting."
    max_output_tokens = 512
}
$ResponseHttp = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/responses" `
    -Headers $AuthHeaders -ContentType "application/json" `
    -Body ($ResponsesPayload | ConvertTo-Json -Depth 12)
$ResponseObject = $ResponseHttp.Content | ConvertFrom-Json
$ResponseObject.status
$ResponseObject.output | ConvertTo-Json -Depth 15
$ResponseObject.usage
```

预期获得 Responses 结构，不要求每个模型都支持这个实验。若返回不支持的参数或接口错误，先核对模型、适配器和版本；保留失败记录也是有效学习结果

文本可能位于 `output` 中类型为 `message` 的项，再进入 `content` 中的 `output_text`。不能假设第一项永远是文本。SDK 提供的便利属性也不一定是原始 HTTP JSON 字段

**协议桥接**表示 LiteLLM 将入口格式转换成另一种上游格式，再转换回来。因此“Responses 请求能完成”不证明上游原生支持 Responses。`previous_response_id`、后台执行、检索、删除和内置工具涉及额外能力，应分别验证

### 3.3 工具调用：模型提出请求，程序执行操作

假设你问“测试订单 LAB-001 的状态是什么”。模型不知道业务数据库，但可以请求一个名为 `get_order_status` 的工具

完整过程有四步：应用声明工具；模型返回工具名与参数；应用验证参数并执行；应用把结果连同对应调用 ID 传回模型，模型再给用户答案。**声明工具不代表模型已经执行了函数**

以下用一个固定、无外部副作用的测试订单，避免学习时访问真实业务系统。要求当前模型支持 Chat 工具调用及指定工具选择；若不支持，不要强行继续

```powershell
$OrderMessages = @(
    @{ role = "user"; content = "Use the tool to check order LAB-001." }
)
$OrderTools = @(
    @{
        type = "function"
        function = @{
            name = "get_order_status"
            description = "Read the status of the single tutorial order."
            parameters = @{
                type = "object"
                properties = @{
                    order_id = @{ type = "string"; enum = @("LAB-001") }
                }
                required = @("order_id")
                additionalProperties = $false
            }
        }
    }
)
$ToolRequest = @{
    model = $ModelAlias
    messages = $OrderMessages
    tools = $OrderTools
    tool_choice = @{
        type = "function"
        function = @{ name = "get_order_status" }
    }
} + $OutputLimit
$ToolResponse = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AuthHeaders `
    -ContentType "application/json" `
    -Body ($ToolRequest | ConvertTo-Json -Depth 20)
$AssistantTurn = $ToolResponse.choices[0].message
$ToolCalls = @($AssistantTurn.tool_calls)
if ($ToolCalls.Count -ne 1 -or $null -eq $ToolCalls[0]) {
    throw "本练习要求恰好一次工具调用，请检查模型能力与响应"
}
$Call = $ToolCalls[0]
if ($Call.function.name -ne "get_order_status") {
    throw "拒绝执行未声明的工具"
}
$Arguments = $Call.function.arguments | ConvertFrom-Json
if ($Arguments.order_id -ne "LAB-001") {
    throw "拒绝访问练习范围外的订单"
}
$ToolResult = @{ order_id = "LAB-001"; status = "ready_for_pickup" } |
    ConvertTo-Json -Compress
```

预期得到一个 `tool_calls` 项，其中 `function.arguments` 是需要解析的 JSON 字符串，而不是已经执行的结果。这里的固定状态由我们的程序提供，不来自订单数据库

接着保留 assistant 的工具声明，并将对应结果回传。`tool_call_id` 必须使用刚才那次调用的 ID，不能自己编一个

```powershell
$FollowupMessages = @(
    $OrderMessages[0]
    @{
        role = "assistant"
        content = $AssistantTurn.content
        tool_calls = $ToolCalls
    }
    @{
        role = "tool"
        tool_call_id = $Call.id
        content = $ToolResult
    }
)
$FollowupPayload = @{
    model = $ModelAlias
    messages = $FollowupMessages
    tools = $OrderTools
    tool_choice = "none"
} + $OutputLimit
$FinalAnswer = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AuthHeaders `
    -ContentType "application/json" `
    -Body ($FollowupPayload | ConvertTo-Json -Depth 20)
$FinalAnswer.choices[0].message.content
```

预期模型根据 `ready_for_pickup` 给出说明，而不是编造执行了配送操作。某些推理模型还要求保留特定 assistant 扩展字段，本例只覆盖标准 Chat 工具往返；遇到相关校验错误，应按对应模型协议补齐，不要丢弃错误继续

> **安全边界：**即使工具参数符合 JSON Schema，也不代表业务权限正确。真实系统还要校验调用者能否访问该订单。不要把模型返回的工具名作为任意脚本名执行，更不要直接执行生成的命令

### 3.4 练习与答案

**练习：**在纸面画出上述两次请求，标出谁生成调用 ID，谁执行工具，谁提供状态。再解释为什么仅看到一次 `tool_calls` 不足以证明编码助手能正常工作

**参考答案：**调用 ID 由模型响应链路提供，应用执行受控函数，状态由应用的数据来源提供。编码助手还依赖参数拼接、工具结果关联、多轮消息、流式事件和错误处理，普通工具声明成功只验证了其中一部分

做完本章后，恢复普通非流式 `$ChatJson` 用于后续治理实验，避免一次测试混入多个变量

官方依据：[流式响应][S6]、[Responses API][S7]、[工具调用][S8]

---

## 第 4 章：Virtual Key，把“能调用”变成“谁可以调用”

### 4.1 为什么不能一直用 master key

你现在准备给两个脚本使用网关：一个做学习问答，一个做批量处理。如果它们共用 master key，脚本泄露就可能暴露网关管理权限，也很难单独限制或撤销某个脚本

**Virtual Key** 是网关签发给应用的访问令牌，可以关联模型权限、额度和用量。**master key** 是管理入口的高权限凭据。两者都不是供应商 Key

本章开始需要 **PostgreSQL**，一种关系型数据库，用来持久保存 Key、用户团队及相关管理数据。没有数据库时可以继续学原理，但不要期待完整 Key 管理流程只靠内存完成

### 4.2 前置条件：连接独立测试数据库

本教程不改动你当前实例的数据库，也不安装数据库服务。你需要先准备一个**空的、独立的测试数据库及账号**。如果已经有数据库服务，可创建单独的学习数据库；不能把现有生产数据库当测试库

在启动学习实例的终端设置连接串。用户名、密码和地址由你的测试数据库提供，含特殊字符的密码需要正确 URL 编码

```powershell
$env:DATABASE_URL = Read-Host "独立测试数据库连接串 postgresql://..." -MaskInput
```

Python 路线重启学习进程，让它继承变量。Docker 路线在第 0 章的 `docker run` 命令中增加 `-e DATABASE_URL`，重新创建**学习容器**。模型配置仍用第二章的基线

代理启动可能创建或迁移数据库结构，这也是不能连接生产数据库的原因。遇到迁移权限或数据库不可达错误，先解决连接和账号权限，不能通过忽略启动错误继续

### 4.3 生成第一个受限 Key

回到客户端终端，`$BaseUrl` 必须指向学习实例。输入它的 master key，单独保存管理请求头，避免稍后把测试请求也错误地用管理员身份发出

先创建一个普通学习用户作为测试 Key 的归属。这里的 `internal_user` 是普通内部用户角色，不是管理员；`auto_create_key: false` 表示此时只创建用户，稍后显式创建 Key。这样第八章的限流实验不会意外使用管理员身份。该用户仅存在于你的独立学习数据库，不发送邀请邮件

```powershell
$MasterKey = Read-Host "学习实例 master key" -MaskInput
$AdminHeaders = @{ Authorization = "Bearer $MasterKey" }
$StudyUserId = "study-user-" + [guid]::NewGuid().ToString("N")
$NewUserBody = @{
    user_id = $StudyUserId
    user_role = "internal_user"
    auto_create_key = $false
    send_invite_email = $false
} | ConvertTo-Json
$StudyUser = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/user/new" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $NewUserBody
if ($StudyUser.user_id -ne $StudyUserId) {
    throw "未确认学习用户创建成功，请检查当前版本 API 响应"
}
$NewKeyBody = @{
    key_alias = "study-app"
    user_id = $StudyUserId
    models = @("study-chat")
    duration = "1h"
} | ConvertTo-Json -Depth 8
$CreatedKey = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/key/generate" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $NewKeyBody
$StudyKey = $CreatedKey.key
if ([string]::IsNullOrWhiteSpace($StudyKey)) {
    throw "响应中没有新 Key，请按当前版本 API 检查结果"
}
$StudyHeaders = @{ Authorization = "Bearer $StudyKey" }
```

预期生成有效期一小时、可直接访问 `study-chat` 的 Key。不要在终端输出 `$CreatedKey` 的完整内容，也不要把生成结果粘贴到文档中

`models` 使用公开模型名。**空数组在当前管理 API 中表示允许所有模型，不是禁止所有模型**，所以本练习明确写出一个名字

用新 Key 发同一个普通请求，观察业务调用与管理员操作已经分离

```powershell
$Allowed = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $StudyHeaders `
    -ContentType "application/json" -Body $ChatJson
$Allowed.StatusCode
```

预期成功。若失败，检查 `$ChatJson` 是否仍使用旧实例的别名，或者学习实例是否实际加载了 `study-chat`

### 4.4 权限实验要有有效对照

向不存在的模型发请求失败，不能证明模型权限限制生效。因为管理员调用它也会失败

在学习 YAML 中，复制成功的 `study-chat` 条目，改公开名字为 `study-other`、部署 ID 为 `study-other-id`，保持同一个上游，重启。这里只是创建权限测试对象，不是模拟独立后端

构造 `study-other` 请求，先用管理员确认它真实可用，再用受限 Key 请求。`-SkipHttpErrorCheck` 让我们读取拒绝状态和响应正文，不代表忽略错误

```powershell
$OtherJson = (@{
    model = "study-other"
    messages = @(
        @{ role = "user"; content = "Reply with one short greeting." }
    )
} + $OutputLimit) | ConvertTo-Json -Depth 12
$Control = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $OtherJson
$Denied = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $StudyHeaders `
    -ContentType "application/json" -Body $OtherJson -SkipHttpErrorCheck
$Control.StatusCode
$Denied.StatusCode
$Denied.Content
```

预期管理员调用成功，受限 Key 被拒绝。具体错误码与正文以运行版本为准。如果两者都成功，检查新 Key 的实际权限，不能只看生成请求里的意图

> **容易误判：**本实验验证直接模型访问权限。当前官方文档说明，管理员配置的 fallback 默认可能跨到 Key 不允许直接调用的模型。严格限制 fallback 时需检查版本并启用 `general_settings.enforce_fallback_model_access: true`，同时配置合法备用模型权限

### 4.5 查询与撤销

为了避免把 Key 放在 URL 的查询参数中，下面用当前官方 API 支持的“查询自身”方式。若你的版本不支持，查看学习实例的 `/openapi.json`；不要到处复制带密钥的 URL

```powershell
$OwnInfo = Invoke-RestMethod -Uri "$BaseUrl/key/info" -Headers $StudyHeaders
$OwnInfo.info | Select-Object models, spend, max_budget, expires
```

预期看到该 Key 的权限、消耗等信息。字段完整性以部署版本为准，不能假设查询接口会再次返回明文 Key

完成本章且不再使用这个 Key 时，由管理员只撤销本次创建的对象

```powershell
$DeleteBody = @{ keys = @($StudyKey) } | ConvertTo-Json
$DeleteResult = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/key/delete" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $DeleteBody
$AfterDelete = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $StudyHeaders `
    -ContentType "application/json" -Body $ChatJson -SkipHttpErrorCheck
$AfterDelete.StatusCode
$AfterDelete.Content
```

预期撤销后的新请求被拒绝。若仍可调用，先记录时间和 worker 数，排查鉴权缓存与撤销传播，而不是把删除 API 成功当成完整验收。后面实验会新建专用 Key，不复用已撤销 Key

### 4.6 自测与答案

**问题：**一个脚本泄露 Key 后，为什么单独的 Virtual Key 更容易处置？为什么权限实验要先做管理员成功对照？撤销 Key 和停用上游 Key 有什么不同？

**答案：**可以单独撤销、限制和追踪应用身份，不必更换全部客户端凭据。成功对照排除模型本身不存在或坏掉的影响。Virtual Key 撤销影响网关入口，停用供应商 Key 影响所有使用该上游凭据的调用

清理时移除 `study-other` 测试条目并重启学习实例，保留独立测试数据库供后续章节使用

官方依据：[Virtual Keys][S9]、[官方管理 API][S10]、[fallback 权限][S11]

---

## 第 5 章：用户、团队、数据库和 UI，各自管什么

### 5.1 一个 Key 不等于一个人

假设你有个人交互脚本和夜间批处理脚本。它们可以属于同一个用户，但应当使用不同 Key，以便单独撤销与追踪。多个用户又可以归入一个团队，共享组织层面的模型范围和预算策略

**User** 表示使用者身份，**Team** 表示管理分组，**Key** 表示具体应用的凭据，**End User** 则可能表示应用背后的最终业务用户。这些身份不是同一个字段，也不应该全部用一个字符串代替

先记住“策略可能来自多层”，不要假设给 Key 设置一个较大额度，就能越过团队或组织层面的限制。继承、覆盖和可选功能应按当前版本文档逐项确认

### 5.2 为什么改了 YAML，看起来却没生效

YAML 是文件配置。Admin UI 是管理界面，本身不是另一份独立运行的模型网关。UI 的修改通过管理 API 写入后端存储

当前官方配置文档说明，启用 `store_model_in_db` 后，部分配置区块会从数据库覆盖到 YAML 上：先加载文件，再叠加数据库中的值。对于被 UI 写入的同名设置，仅修改 YAML 并重启可能不会改变运行值

模型条目又不同：数据库添加的同名模型可能作为额外部署与 YAML 模型一起服务，并不简单替换文件中的模型

| 你看到的现象 | 首先检查什么 |
|---|---|
| 重启后设置仍是旧值 | 是否有数据库覆盖 |
| 一个别名出现多条部署 | 是否同时在 YAML 和 UI 添加过 |
| UI 保存了模型，但容器重建后丢失 | 数据库是否持久化、是否连到同一数据库 |
| 数据库恢复后上游凭据无法解密 | 原加密密钥是否还在 |

### 5.3 认识 Salt Key

如果把上游凭据存进数据库，需要能够在保存时加密、读取时解密。`LITELLM_SALT_KEY` 参与这类凭据保护，不是用于客户端认证的 Virtual Key

在你第一次向学习数据库保存上游凭据前，按官方部署指南设置并安全保存它。不要在教程中使用公开固定值。**改变 Salt Key 可能使旧数据无法解密，不能把轮换它当普通重启练习**

这里不要求你开启 UI 存储，也不要求把已有 YAML 全搬到数据库。先选一个主要管理方式，明确哪些设置由谁维护，比同时使用两套界面更容易排错

### 5.4 纸面实验：建立配置来源表

打开学习实例的 `http://127.0.0.1:4001/ui`；若端口不同请替换。没有 UI 或未配置登录时直接查看自己的配置文件，不需要为完成本章改变认证方式

查看模型页面里 `study-chat` 的条目数，再与 YAML 对照。不要点击“测试连接”，除非接受它可能真实调用上游

为公开别名、上游地址、超时、Key 权限和预算分别记录“从文件来、从数据库来、尚不确定”。预期不是获得特定截图，而是能够指出自己每个配置的权威来源

### 5.5 自测与答案

**问题：**UI 能打开是否证明数据调用健康？同名数据库模型一定替换 YAML 模型吗？为什么备份数据库却丢失 Salt Key 仍可能恢复失败？

**答案：**UI 验证的是部分管理链路，不是推理链路。当前文档说明模型可能一起成为候选部署。加密数据需要原来的解密条件，数据库文件本身不包含完整恢复能力

官方依据：[配置覆盖规则][S1]、[用户与团队][S12]、[生产配置][S13]、[模型管理][S14]

---

## 第 6 章：Router，先区分“模型组”与“部署”

### 6.1 为什么一个名字会对应多个服务

假设你在两个区域各有一个可用部署。应用只想请求 `study-chat`，不应该自己决定用哪个区域。网关可以把两个部署放在同一个公开名字下面

**模型组**是一组共享公开模型名的候选配置。**部署**是一条具体的上游配置，通常具有自己的地址、凭据、限额或区域属性

Router 选择的是候选部署。常规负载均衡并不意味着它理解问题内容，也不意味着它会自动在强模型和便宜模型之间做语义判断

### 6.2 四种策略，各自在看什么

| 策略 | 大致依据 | 适合先理解的场景 | 不能承诺什么 |
|---|---|---|---|
| `simple-shuffle` | 随机或按配置权重选择 | 多个同类部署分担流量 | 小样本严格轮流或严格比例 |
| `least-busy` | 正在处理的调用数 | 请求时长差异较大 | 每次选到网络延迟最低者 |
| `latency-based-routing` | 观测到的历史延迟 | 对响应速度有偏好 | 冷启动时已有准确样本 |
| `usage-based-routing-v2` | 使用量和可用限额 | 接近 TPM/RPM 配额的分流 | 没有额外状态与 Redis 开销 |

当前官方文档把 `simple-shuffle` 作为推荐起点。先证明“候选配置正确、路由证据能观察”，再尝试复杂策略。策略可用性与细节以实际版本为准

### 6.3 有两个真实部署时，做一个小实验

在独立学习配置中复制已有模型条目，使两条都叫 `study-chat`，第二条填入**第二个已验证上游**。以下沿用第二章的 OpenAI-compatible 示例，其他提供商保留原来的认证结构

```yaml
model_list:
  - model_name: study-chat
    litellm_params:
      model: os.environ/LAB_MODEL
      api_base: os.environ/LAB_API_BASE
      api_key: os.environ/LAB_UPSTREAM_API_KEY
    model_info:
      id: study-a
  - model_name: study-chat
    litellm_params:
      model: os.environ/LAB_MODEL_B
      api_base: os.environ/LAB_API_BASE_B
      api_key: os.environ/LAB_UPSTREAM_API_KEY_B
    model_info:
      id: study-b

router_settings:
  routing_strategy: simple-shuffle
  num_retries: 0
```

这是本章模型与路由区块的替换示例，保留原来的 `general_settings`。在启动终端设置第二套环境变量；Docker 还需增加对应的 `-e` 参数。先分别确认两个上游都能成功调用，再合并测试

暂时关闭响应缓存，不配置 fallback。否则两次一样的答案可能是缓存，另一个部署的响应也可能是故障回退，都会混淆路由实验

接受少量调用费用后，发六次顺序请求并按部署 ID 分组

```powershell
$Observations = foreach ($Index in 1..6) {
    $Http = Invoke-WebRequest -Method Post `
        -Uri "$BaseUrl/v1/chat/completions" -Headers $AuthHeaders `
        -ContentType "application/json" -Body $ChatJson
    [pscustomobject]@{
        Request = $Index
        Deployment = ($Http.Headers["x-litellm-model-id"] -join ",")
        Status = $Http.StatusCode
    }
}
$Observations
$Observations | Group-Object Deployment | Select-Object Name, Count
```

预期可以用响应头或服务端日志识别被选中的部署。六次全部命中同一个部署并不能单独证明随机策略失效，不要无限追加付费请求追求某个比例

只有一个真实上游时，可以复制它观察“配置条目的选择”，但要在记录中明确：**这仍是同一个上游故障域，也可能共享同一个配额，不证明吞吐翻倍或高可用**

### 6.4 为什么后面会需要 Redis

一个进程可以在内存里记住当前调用数。两个 worker 各有一份内存，如果没有共享状态，可能都觉得某个部署还有很多额度

**Redis** 是这里用于共享短期状态的服务。它可以参与限流计数、冷却状态和缓存。一个容器里也可能运行多个 worker，因此“只有一个容器”不等于“只有一份状态”

先用单 worker 学习。多 worker 或多副本部署时，按官方 Redis 要求显式配置共享连接，不能只创建 Redis 容器就假设 LiteLLM 会自动使用

### 6.5 自测与答案

**问题：**为什么同名配置能构成模型组？为什么两个别名指向同一上游不等于高可用？顺序发送六个请求适合比较 `least-busy` 吗？

**答案：**Router 根据公开模型组组织候选部署。底层地址、凭据或区域故障仍可能同时影响两个别名。顺序请求通常没有重叠的进行中调用，不能有效体现最少忙碌策略，需要受控并发实验

恢复单部署基线。没有第二个独立部署时，把真实路由对比标记为待完成，不影响学习下一章

官方依据：[Router 策略][S15]、[Redis 要求][S16]

---

## 第 7 章：重试、冷却、回退，是三种不同的恢复动作

### 7.1 一次失败之后，有哪些选择

假设模型服务偶发 500。**重试（retry）**是在策略允许时再尝试请求，适合某些短暂故障。**冷却（cooldown）**是暂时把表现不健康的部署移出正常候选集合，避免后续请求反复撞向它。**回退（fallback）**是转向预先指定的其他模型组

**超时（timeout）**限制等待时间，是失败判定的一部分。客户端等待超时、网关超时和供应商超时不是同一个设置

不能用“增加重试次数”解决所有问题。错误凭据、无效参数和永远不存在的路径通常不会因为重试而变对。重试还可能增加调用量、费用与尾部延迟

### 7.2 先读懂配置，不马上制造故障

```yaml
router_settings:
  num_retries: 1
  timeout: 20
  allowed_fails: 2
  cooldown_time: 10
  fallbacks:
    - study-primary: [study-backup]
```

这段教学配置表达：允许一定重试，为请求设置超时与冷却参数，给 `study-primary` 模型组配置备用组。它不表示“每次一定等 20 秒、严格失败两次后才冷却、总共最多调用两次”

不同错误类型、部署级设置、重试策略和已经消耗的时间会影响具体路径。当前文档还说明某些错误可能触发即时冷却，不能只靠 `allowed_fails` 推导所有行为

`fallbacks` 里的名字必须对应模型组名，不是 `model_info.id`。常见配置错误是把部署 ID 写进去，导致失败时找不到备用目标

### 7.3 单个健康模型也能做的有界回退实验

这个实验只放在独立学习实例。它人为添加一个连接失败的主组，把你现有健康模型作为备用组。它能证明“错误触发回退链路”，不能证明两个真实供应商之间的容灾

先确认学习实例自身网络空间内的 `127.0.0.1:1` 没有监听服务。下面的地址故意无效，绝不能用于正常模型配置。如果该端口有服务，改用经确认未监听的本机端口

将模型配置改为下列形状，健康备用的 `litellm_params` 保留你已经成功的原配置

```yaml
model_list:
  - model_name: study-primary
    litellm_params:
      model: openai/lab-unreachable
      api_base: http://127.0.0.1:1/v1
      api_key: lab-unused
    model_info:
      id: study-unreachable
  - model_name: study-backup
    litellm_params:
      model: os.environ/LAB_MODEL
      api_base: os.environ/LAB_API_BASE
      api_key: os.environ/LAB_UPSTREAM_API_KEY
    model_info:
      id: study-healthy-backup

router_settings:
  num_retries: 0
  timeout: 30
  fallbacks:
    - study-primary: [study-backup]
```

保留 master key 设置，关闭缓存并重启学习实例。使用学习管理员请求，避免本章同时引入 Key fallback 权限变量

```powershell
$FallbackJson = (@{
    model = "study-primary"
    messages = @(
        @{ role = "user"; content = "Reply with one short greeting." }
    )
} + $OutputLimit) | ConvertTo-Json -Depth 12
$FallbackHttp = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $FallbackJson
$FallbackHttp.StatusCode
$FallbackHttp.Headers["x-litellm-model-id"]
$FallbackHttp.Headers["x-litellm-attempted-fallbacks"]
```

若你跳过了第四章，先按该章方法建立 `$AdminHeaders`。预期主组连接失败后由健康备用完成，并在日志或响应头中看到备用部署证据。备用调用会真实收费

再从 YAML 移除 `fallbacks`，重启并发同一个请求。此时使用 `-SkipHttpErrorCheck` 读取错误正文，预期失败。这个反向对照说明前一次成功依赖备用路径，而不是错误地址实际可用

若第一次就失败，按顺序检查主组错误是否被归类为可回退、备用名字是否存在、备用本身是否可用、权限是否允许，以及整体时间是否已经耗尽。不要直接增加十次重试

> **版本陷阱：**当前官方文档说明，Proxy 自 v1.85.0 起不再接受旧 `mock_testing_*fallbacks` 请求参数来触发模拟故障。不要从旧博客复制这些字段，然后把没有发生回退理解成配置错误

### 7.4 回退成功仍可能损害应用语义

备用模型也许只支持文本，不支持工具；上下文更短；输出格式不同；数据必须跨到另一个区域。此时 HTTP 200 不一定意味着业务正确

生产回退需要同时验证能力、权限、成本和数据边界。对有副作用的业务工具，还要避免重复执行：模型请求重试与应用订单操作重试不是同一件事

### 7.5 自测与答案

**问题：**重试和 fallback 的主要区别是什么？为什么本实验不能证明真实高可用？为何备用返回 200 后还要测工具调用？

**答案：**重试是在策略内再次尝试，fallback 是转向指定备用组。本实验只有一个真实健康上游，主组是人为连接失败。备用可能不具备相同协议和能力，应用可能在后续步骤失败

完成后恢复第二章 `study-chat` 单部署配置，删除故意无效的主组，重启并确认普通调用恢复。不要让后续实验悄悄依赖故障配置

官方依据：[可靠性与 fallback][S11]、[超时][S17]、[响应头][S3]

---

## 第 8 章：限流，限制的是速度，不是总花费

### 8.1 RPM 与 TPM 分别解决什么问题

假设批处理脚本每秒发很多请求，会挤占交互脚本的服务能力。**RPM** 表示每分钟请求量，**TPM** 表示每分钟 token 量。一个长请求可能消耗很多 TPM，但只占一次请求

Key 的 `rpm_limit` 是网关对应用的限制。部署配置里的 `rpm`、`tpm` 则用于描述候选上游容量等路由信息。两层数值不是同一份额度，供应商还有自己的配额系统

### 8.2 做一个只有 RPM 在起作用的实验

前置条件是独立测试数据库、`study-chat` 恢复健康、单 worker。关闭响应缓存，不加低 TPM 和极低预算，避免你不知道究竟是哪一层拒绝

用第四章的管理请求头新建 Key，并明确归属第四章创建的普通学习用户 `$StudyUserId`。不要把 Key 关联到管理员用户，当前文档说明 proxy admin users 不适用普通限流。若你跳过了第四章，先完成用户创建步骤

```powershell
$RateKeyBody = @{
    key_alias = "study-rpm"
    user_id = $StudyUserId
    models = @("study-chat")
    duration = "1h"
    rpm_limit = 2
} | ConvertTo-Json
$RateCreated = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/key/generate" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $RateKeyBody
$RateKey = $RateCreated.key
if ([string]::IsNullOrWhiteSpace($RateKey)) {
    throw "没有生成限流实验 Key"
}
$RateHeaders = @{ Authorization = "Bearer $RateKey" }
```

顺序发送最多三次请求，碰到错误即停止，不用大并发压测

```powershell
foreach ($Attempt in 1..3) {
    $RateHttp = Invoke-WebRequest -Method Post `
        -Uri "$BaseUrl/v1/chat/completions" -Headers $RateHeaders `
        -ContentType "application/json" -Body $ChatJson -SkipHttpErrorCheck
    [pscustomobject]@{
        Attempt = $Attempt
        Status = $RateHttp.StatusCode
        RetryAfter = ($RateHttp.Headers["retry-after"] -join ",")
    }
    if ($RateHttp.StatusCode -ge 400) {
        $RateHttp.Content
        break
    }
}
```

在请求足够快且限流生效的环境中，预期观察到网关限流拒绝，通常是 429。若三次都成功，检查是否跨过了有效窗口、Key 身份是否是管理员、配置是否生效，而不是断言 limiter 无效

**不承诺严格第三次必然拒绝，也不承诺整点分钟恢复。**窗口实现可能随策略和版本变化，记录真实的 `retry-after`、reset 信息和日志。限流恢复不由 `budget_duration` 控制

### 8.3 如果收到 429，先问“是谁限的”

供应商 429 可能表示上游配额不足，LiteLLM 429 可能表示 Key、团队或部署选择阶段的限制。相同 HTTP 状态不代表同一个原因

记录响应错误类型、请求时间、所用 Key、候选部署与供应商日志。应用应根据实际返回信息退避，避免每毫秒重新尝试。退避是逐步延长等待时间，通常还加入随机抖动，防止许多客户端同时重试

TPM 实验另开一个新 Key，并使用固定短输入与适当输出上限。当前文档描述部分路径有 token 预留和结算机制，因此不能仅凭屏幕上看见的文本长度精确预测准入结果

### 8.4 自测、答案与清理

**问题：**RPM 为 2 是否意味着每分钟最多花两美元？客户端等一分钟仍失败一定是计数没清吗？为什么不能用 master key 测应用限流？

**答案：**RPM 限请求量，不限单次费用。还有上游额度、其他限制或实际窗口未到期等原因。管理员身份可能绕过普通应用限流，无法构成有效测试

实验后按第四章 `/key/delete` 的 `keys` 数组格式撤销 `$RateKey`，只撤销本次生成的 Key

官方依据：[限流与用户设置][S12]、[共享状态][S16]、[响应头][S3]

---

## 第 9 章：预算，把“调用权限”与“费用边界”联系起来

### 9.1 一美元预算并不等于供应商一美元硬保险丝

假设你想让学习脚本每天只使用有限金额。LiteLLM 可以基于识别到的 token 用量、模型价格与预算状态控制后续请求

**Spend** 是 LiteLLM 记录的费用，**budget** 是你设置的预算阈值。它们和供应商最终账单之间还隔着价格映射、折扣、特殊计费、延迟记录等条件

当前文档描述了请求前的预算预留与完成后的结算，不能笼统地说“所有预算都只在请求结束后检查”。但也不能反过来认为每个模型、每种 API 和每个历史版本都有完全相同的预留能力

### 9.2 创建预算 Key，先观察，不靠刷钱触发

仍然使用独立测试数据库。以下是创建一个一小时后过期、预算周期为一天的学习 Key，两种时间刻意不同

```powershell
$BudgetBody = @{
    key_alias = "study-budget"
    user_id = $StudyUserId
    models = @("study-chat")
    duration = "1h"
    max_budget = 1.0
    budget_duration = "1d"
} | ConvertTo-Json
$BudgetCreated = Invoke-RestMethod -Method Post `
    -Uri "$BaseUrl/key/generate" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $BudgetBody
$BudgetKey = $BudgetCreated.key
if ([string]::IsNullOrWhiteSpace($BudgetKey)) {
    throw "没有生成预算实验 Key"
}
$BudgetHeaders = @{ Authorization = "Bearer $BudgetKey" }
$Before = Invoke-RestMethod -Uri "$BaseUrl/key/info" -Headers $BudgetHeaders
$Before.info | Select-Object spend, max_budget, budget_duration
```

接受一次真实请求费用后，发第一章相同的短请求，再查 spend。异步写入可能有延迟，不能用立即查询的旧数值证明没有计费

```powershell
$BudgetCall = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $BudgetHeaders `
    -ContentType "application/json" -Body $ChatJson
$BudgetCall.Headers["x-litellm-response-cost"]
Start-Sleep -Seconds 5
$After = Invoke-RestMethod -Uri "$BaseUrl/key/info" -Headers $BudgetHeaders
$After.info | Select-Object spend, max_budget, budget_duration
```

预期在价格和用量正确识别、日志写入正常后看到对应的消耗变化。五秒只是首次观察间隔，不是写入 SLA。如果还是零，查用量、价格映射、缓存和异步日志，不要反复付费调用来试探

### 9.3 理解两个容易混淆的时间

`duration` 是 Key 的有效期，过期后凭据不可继续使用。`budget_duration` 是预算周期，不决定 Key 何时失效，也不决定 RPM 窗口

预算恢复还可能依赖后台重置任务。当前文档给出的默认扫描间隔是十分钟，因此设置 `"30s"` 不代表第 30 秒就会恢复。本文不修改扫描频率，也不执行全局 spend reset

> **容易误判：**“我把预算改大后请求成功了”只能说明改变了准入条件，不能说明之前的定价一定正确。先能对上一次请求的 usage 和费用，再讨论整日预算

### 9.4 怎样验证预算拒绝才算完整

上面的练习验证了配置与用量观察，**没有验证触顶拒绝**。完整验收还需要一个受控、价格已知、只有该预算在限制的测试对象

不要为了完成教程把真实额度故意耗尽。可以在独立测试系统中使用当前管理 API 支持的测试 spend 状态构造超额条件，但应先核对该版本的请求 Schema，并明确记录“人工状态，不是真实支出”。不能把它写回实际用户账本

在没有合适测试条件时，把“预算拒绝”列为待验收项。这比使用不明模型价格、不断增加请求直到报错更可靠

### 9.5 自测与答案

**问题：**Key 一小时后失效、预算一天重置，两者矛盾吗？未知价格时 spend 为零是否等于免费？预算阈值可以替代供应商侧账单告警吗？

**答案：**不矛盾，凭据寿命与预算周期是不同条件。零可能是未识别价格、未落库或其他状态，需要查证。不能替代，供应商侧仍应设置独立的配额、告警和账单核对

完成后撤销 `$BudgetKey`。不要重置整个数据库的消费记录

官方依据：[预算、预留与重置][S12]、[成本跟踪][S4]

---

## 第 10 章：缓存，同样叫 cache，缓存的东西可能完全不同

### 10.1 两种缓存先分开

假设多个用户反复问同一个公开 FAQ。网关可以保存一次完整回答，下次相同请求直接复用。这是 **响应缓存（response cache）**

如果用户问题不同，但都带着很长的相同系统提示词，供应商可能复用输入前缀的计算结果。这是 **提示词缓存（prompt cache）**。它通常仍然要调用模型并生成新的输出

| 对比 | LiteLLM 响应缓存 | 上游提示词缓存 |
|---|---|---|
| 复用对象 | 完整生成响应 | 输入前缀相关计算 |
| 命中后是否还调用上游 | 可不调用 | 通常仍调用 |
| 常见观察证据 | 网关缓存头、命中指标、上游请求计数 | usage 中供应商的缓存 token 字段 |
| 主要风险 | 回答过期、错误复用、数据隔离不当 | 计费规则与缓存生命周期误解 |

不能因为第二次更快，就推断哪一种缓存命中了

### 10.2 为完整响应缓存连接独立 Redis

本章要求一个独立、可丢弃测试数据的 Redis 实例。不要使用其他应用的缓存库，不执行 `FLUSHALL` 或清空共享缓存

在服务终端设置测试连接值，端口按实际服务填写。无密码的隔离环境应按对应版本配置省略密码字段，不要保留一个不存在的环境变量引用

```powershell
$env:REDIS_HOST = Read-Host "学习实例可达的 Redis 主机"
$env:REDIS_PORT = Read-Host "Redis 端口"
$env:REDIS_PASSWORD = Read-Host "测试 Redis 密码" -MaskInput
```

把以下字段合并到学习配置，保留健康 `study-chat` 模型。Docker 启动时增加 `-e REDIS_HOST -e REDIS_PORT -e REDIS_PASSWORD`

```yaml
litellm_settings:
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD
```

这是演示单实例响应缓存的配置。多 worker 的 Router 协调还需要按官方 Redis 要求配置 `router_settings` 的连接，两个用途不能只配一个就默认全部生效

重启学习实例，先检查缓存连接。下面接口用于验证缓存连接和操作，不调用 LLM

```powershell
$CacheHealth = Invoke-RestMethod -Uri "$BaseUrl/cache/ping" -Headers $AdminHeaders
$CacheHealth
```

预期是成功的缓存检查结果；具体结构看当前版本。如果没有这个路由或鉴权失败，先查看本地 OpenAPI 和日志，不要把业务调用更快当作替代证据

### 10.3 设计一个能排除误判的命中实验

第一步，用本次实验独有的随机标记构造请求，减少已经存在旧缓存条目的影响。**只生成一次标记，后两次复用完全相同的 JSON**

```powershell
$CacheMarker = [guid]::NewGuid().ToString("N")
$CacheJson = (@{
    model = "study-chat"
    messages = @(
        @{ role = "user"; content = "Reply with one greeting. Lab marker: $CacheMarker" }
    )
    cache = @{ ttl = 60 }
} + $OutputLimit) | ConvertTo-Json -Depth 12
$CacheFirst = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $CacheJson
Start-Sleep -Seconds 2
$CacheSecond = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $CacheJson
$CacheFirst.Headers["x-litellm-cache-key"]
$CacheSecond.Headers["x-litellm-cache-key"]
```

`ttl` 是缓存保留时间，这里按官方缓存控制接口设置为 60 秒。预期第二次出现当前版本文档定义的缓存命中证据。结合上游调用计数或第十一章命中指标更可靠

回答相同、耗时下降、成本头为零，都不要单独作为充分证据。当前文档说明请求通过 hash 匹配，但并非每种供应商扩展参数都默认进入缓存 key，不能概括为“所有 JSON 字段都会比较”

### 10.4 再做一个不读、不写缓存的对照

下列请求保持相同业务输入，通过请求体里的 `cache` 控制明确要求绕过读取并且不存储结果。这是 LiteLLM 的请求参数，不是假设普通 HTTP `Cache-Control` 在所有版本等价

```powershell
$BypassJson = (@{
    model = "study-chat"
    messages = @(
        @{ role = "user"; content = "Reply with one greeting. Lab marker: $CacheMarker" }
    )
    cache = @{
        "no-cache" = $true
        "no-store" = $true
    }
} + $OutputLimit) | ConvertTo-Json -Depth 12
$Bypass = Invoke-WebRequest -Method Post `
    -Uri "$BaseUrl/v1/chat/completions" -Headers $AdminHeaders `
    -ContentType "application/json" -Body $BypassJson
$Bypass.Headers["x-litellm-cache-key"]
```

预期触发新的上游调用，因此会有真实费用。结合日志、上游计数或指标，确认它没有走前一次缓存

### 10.5 什么时候不应直接开缓存

订单状态、实时价格、含个人身份的数据、依赖工具实时结果的请求，都需要先考虑新鲜度和隔离边界。即使文本相同，不同用户的授权数据也未必相同

先明确缓存 key 是否包含必要身份或隔离信息，是否允许不同 Key 复用，多久失效，失效后怎样重新获取。本文不宣称默认缓存配置满足多租户隔离要求

### 10.6 自测与答案

**问题：**为什么实验标记不能每次都变化？上游 prompt cache 命中是否表示完全没有模型调用？为什么“回答一样”不足以证明缓存命中？

**答案：**每次改标记会改变请求，无法验证重复匹配。提示词缓存仍通常需要完成新的生成。同一个模型可能本来就返回相同内容，必须观察缓存链路证据

完成后从 YAML 关闭本章的响应缓存并重启，让测试条目按 TTL 过期，不清空整个 Redis。后续普通调用重新使用第一章 `$ChatJson`

官方依据：[响应缓存][S18]、[缓存控制][S19]、[Redis 要求][S16]、[提示词缓存][S20]

---

## 第 11 章：从“看过日志”到能定位问题

### 11.1 日志、指标和账单，不是同一份信息

**日志**描述某次事件，适合回答“这个请求为什么失败”。**指标（metrics）**是持续累计或采样的数值，适合回答“过去一小时错误率有没有上升”。**用量与费用记录**用于归属和核算

如果请求慢，你需要先区分等待发生在哪：客户端到网关、网关排队、上游推理，还是返回传输。总时间慢不能直接证明 Router 策略不好

### 11.2 为一次请求制作证据卡

复用第一章的普通请求，对照日志填写下表。空值可以保留，但要写明“当前没有观测到”，不能填想象的数字

| 字段 | 从哪里取 | 为什么需要 |
|---|---|---|
| 请求时间和调用 ID | 客户端、响应头、日志 | 关联同一次调用 |
| 公开模型名与部署 ID | 请求体、响应头、日志 | 区分入口与实际选择 |
| HTTP 状态与错误类型 | 响应 | 找失败层 |
| 重试与 fallback 线索 | 响应头、日志 | 解释隐藏的多次调用 |
| 输入、输出 token | `usage` | 解释用量 |
| LiteLLM 费用 | 成本头、spend 记录 | 验证价格识别 |
| 缓存证据 | 缓存头、指标、上游计数 | 判断是否真的访问上游 |

数据库可用时，可以在 UI 的 Usage、Logs 等页面查对应请求，具体标签随版本变化。保存完整 prompt 会涉及数据保护，学习时只发送无敏感内容的短请求

`--detailed_debug` 适合对隔离实例临时诊断，不应长期打开后把日志全部上传。即使工具自动遮盖了一部分 Key，也不能假设所有业务内容都已脱敏

### 11.3 健康检查：活着、准备好、模型可用

**liveness** 表示进程存活，**readiness** 表示是否准备好接收流量。它们不应被理解成“所有模型都健康”

当前官方文档区分如下接口，旧版本请看自己的 OpenAPI

| 接口 | 检查对象 | 是否可以当无模型调用的探针 |
|---|---|---|
| `/health/liveliness` | 进程存活 | 可以 |
| `/health/readiness` | 就绪状态及已配置的部分依赖 | 可以，但不证明上游模型健康 |
| `/health/readiness/details` | 认证后的详细诊断 | 按当前版本使用 |
| `/health` | 模型实际健康调用 | 不能，可能发送收费模型请求 |

先用不调用模型的接口观察

```powershell
$Live = Invoke-WebRequest -Uri "$BaseUrl/health/liveliness" -SkipHttpErrorCheck
$Ready = Invoke-WebRequest -Uri "$BaseUrl/health/readiness" -SkipHttpErrorCheck
$Live.StatusCode
$Ready.StatusCode
$Ready.Content
```

预期健康实例返回正常状态。readiness 成功不代表供应商 Key 有效，也不代表某个特定模型支持工具调用。不要把 `/health` 每秒执行一次，却以为没有模型成本

### 11.4 第一个 Prometheus 指标页面

**Prometheus** 是采集时间序列指标的监控系统。LiteLLM 可以暴露指标端点；你不安装完整 Prometheus，也可以先读原始指标文本

在学习配置合并 callback。如果已经有其他 callback，加入现有列表，不覆盖掉其他配置

```yaml
litellm_settings:
  callbacks: ["prometheus"]
```

重启学习实例。若缺少 Python 依赖，按对应 LiteLLM 版本的官方安装要求补齐，不在原服务环境里盲目降级依赖。读取指标端点时使用学习管理凭据

```powershell
$Metrics = Invoke-WebRequest -Uri "$BaseUrl/metrics" -Headers $AdminHeaders
$Metrics.Content -split "`n" |
    Where-Object { $_ -match "^litellm_" } |
    Select-Object -First 20
```

预期是文本指标，不是 JSON。当前文档说明自 v1.85.0 起 proxy 端口上的 `/metrics` 默认需要 API Key 认证。Prometheus metrics 当前属于 OSS，但某些具体功能和集成仍需看对应授权

做一次普通请求，再读取指标，寻找与请求数、失败数或延迟有关的变化。若要验证响应缓存，可以比较文档列出的 `litellm_cache_hits_metric`；不能把它和供应商提示词缓存 token 指标混在一起

多 worker 监控还涉及 `PROMETHEUS_MULTIPROC_DIR` 等设置，单 worker 观察成功不等于已经正确聚合全部 worker

### 11.5 四个排错分支

| 现象 | 先做什么 | 暂时不要做什么 |
|---|---|---|
| 401 或 403 | 区分网关凭据、上游凭据和模型权限 | 不停重试 |
| 429 | 查限制发生在网关哪层或上游 | 一口气调大所有限额 |
| 超时或 5xx | 查上游连接、部署状态、重试与 fallback | 只看最终状态码 |
| 返回文本但没有费用 | 查 usage、价格识别、异步写入 | 把缺失记成免费 |

### 11.6 自测与答案

**问题：**readiness 200 能否证明模型正常？指标端点 401 是否代表 Prometheus 不支持？成本头与供应商账单不同，应该先查什么？

**答案：**不能，它没有证明具体推理调用。先检查端点认证与配置。先核对模型价格映射、token 用量、缓存语义、供应商计费规则以及记录时间

完成后可保留本章监控配置用于个人学习；如果要恢复最小基线，移除本次 callback 并重启学习实例

官方依据：[日志][S21]、[健康检查][S22]、[Prometheus][S23]、[成本跟踪][S4]、[授权边界][S24]

---

## 第 12 章：为什么单机能跑，不代表可以直接上生产

### 12.1 多副本不是复制进程那么简单

假设一台网关每分钟允许一个 Key 调用 100 次。你启动三台，却让每台独立计数，实际可能放行远超过预期的总请求数

多副本要共享的不只是模型列表，还包括鉴权状态、限流计数、预算状态、冷却与撤销信息。PostgreSQL 保存持久数据，Redis 常用于短期共享协调，它们不能简单互相替代

| 组件 | 主要责任 | 故障后应该问什么 |
|---|---|---|
| Proxy 进程 | 接收、治理与转发请求 | 是否应该继续接收流量 |
| PostgreSQL | Key、配置、账本等持久数据 | 能否正确鉴权、预算与恢复 |
| Redis | 共享计数、短期状态与缓存 | 是否会失去一致限制 |
| 上游模型 | 实际推理 | 是否有独立备用与足够配额 |
| 反向代理或负载均衡器 | 外部入口与转发 | 超时、流式缓冲、TLS 是否正确 |

**TLS** 用来保护传输中的连接。把监听地址从 `127.0.0.1` 改成公网可达，不会自动获得 TLS、访问控制或安全运维能力

### 12.2 失败时继续还是拒绝，需要明确选择

**Fail-open** 表示某项检查不可用时仍继续业务，优先可用性。**Fail-closed** 表示无法确认满足条件时拒绝，优先边界

例如预算状态读不到，如果继续请求，就可能超出限制；如果拒绝，就可能因为数据库短暂问题影响可用性。当前文档提供预算相关的 fail-closed 配置，但这是需要结合版本和业务明确选择的行为，不能假设所有路径默认如此

### 12.3 不做破坏性操作，也能完成的桌面演练

在纸上分别假设数据库不可达、Redis 不可达、一个 worker 重启、一个上游区域不可用。对每个场景写下预期：新请求是否允许、旧流式请求是否能完成、Key 撤销多久生效、费用是否可能延迟

然后找出哪些结论已有文档与实验支持，哪些只是猜测。当前只验证单 worker 的地方，明确标记“未验证分布式行为”

这一步的产物是验收清单，不是生产可用证明。真正演练应在专门测试环境安排，不在你正在使用的实例上断数据库

### 12.4 自测与答案

**问题：**同一区域的两个部署是否一定独立？数据库备份为什么还不够？为了让 readiness 变绿而绕过依赖检查是否修好了服务？

**答案：**它们可能共享网络、凭据、配额或区域故障。还需要恢复配置、密钥和连接条件。探针只是报告状态，绕过检查可能掩盖故障

官方依据：[生产配置][S13]、[Redis 要求][S16]、[预算行为][S12]

---

## 第 13 章：其余功能怎么理解，什么阶段再学

### 13.1 Guardrails：在请求链路上执行检查

**Guardrail** 是在输入、输出或调用过程中执行的校验与处理。例如你希望公开问答应用拒绝某类输入，或在输出中检测敏感信息

检查阶段决定能看到什么。输入检查可以在模型调用前拒绝，输出检查必须等有输出后才能判断。流式情况下，如果数据已经发给客户端，再发现问题时不能假设能够收回已发送内容

先用纸面设计一个规则：“输入包含专门的测试标记时拒绝”。写出拒绝发生在模型调用前还是后、是否仍然产生模型费用、拒绝结果如何让客户端识别，再考虑具体集成。不要把“有一个安全模型”当作整条链路已安全

Guardrails 并非全部是企业版功能。具体 provider、执行模式、Key 或团队级绑定等条件需分别查授权，某个第三方检查服务还可能单独收费

### 13.2 MCP：给工具服务建立统一入口

**MCP（Model Context Protocol）** 是连接工具和上下文服务的一种协议。LiteLLM 的 MCP Gateway 可以聚合工具服务器并做访问控制

这和第三章的工具调用相关，但不是同一层：模型产生工具请求，应用或 Agent 执行工具；MCP 描述的是如何发现和调用工具服务。单纯把模型请求转发给 LiteLLM，不代表所有工具都会自动执行

在没有 MCP 服务器时，先画出“客户端、模型、工具执行器、MCP 网关、工具服务器”的关系。标出谁持有数据库查询权限，谁负责用户授权，哪个动作需要用户确认

只有当你确实需要多个客户端共享工具访问治理，再接入一个无副作用的只读工具练习。不要第一步就连可删除文件或修改生产数据的工具

### 13.3 Embeddings、图片、音频与批处理

**Embedding** 把输入转换成向量，常用于搜索相似内容。它不是聊天回复，维度、模型和索引构建要保持一致。更换 embedding 模型后，不能假设已有索引还能直接混用

图片、音频、实时交互和批处理有各自的请求结构、响应形式和模型要求。一个 chat 部署不会因为换 URL 就获得这些能力

学习时采用同一个顺序：确认当前模型支持该能力，做最小直接调用，经过网关重做，再核对协议、用量和日志。暂时没有对应模型时，理解能力边界就够，不必为了“学全”购买全部服务

### 13.4 自动路由，不等于普通负载均衡

第六章的常规策略主要依据部署负载、延迟或配额。根据问题内容判断“用便宜模型还是更强模型”是另一类选择，可能依赖分类器、语义规则或额外路由模型

这种选择本身有成本、延迟和误判，需要有真实评测集。先有稳定的模型调用与成本记录，再考虑自动路由，否则无法判断节省的钱是否来自质量下降

### 13.5 给自己选择下一个专题

| 你开始遇到的需求 | 下一步优先学习 |
|---|---|
| 多个脚本共享网关 | Virtual Key、归属、预算、撤销 |
| 并发上升、单部署配额不够 | Router、部署限额、共享状态 |
| 上游偶发失败 | 超时、重试、fallback 的语义验收 |
| 重复请求成本明显 | 响应缓存与数据隔离 |
| 需要查资料或执行工具 | 工具往返，再学 MCP |
| 要公开给团队使用 | 授权、日志保护、可观测性、恢复演练 |
| 想按问题自动选模型 | 带质量指标的自动路由评测 |

本章是能力入口，不是这些功能的完整实验认证。你不需要一次学完所有集成，先完成与实际使用场景有关的主线

官方依据：[Guardrails][S25]、[MCP][S26]、[授权边界][S24]、[配置中的不同模型类型][S1]

---

## 第 14 章：毕业实验，让自己能独立解释一条请求

### 14.1 基础版，一个模型就能完成

恢复干净的 `study-chat` 学习实例。不用照抄正文，完成一次非流式请求，指出客户端地址、公开别名、上游地址与三种凭据的区别

接着做一个已经确认模型支持的流式或工具实验。解释返回的是完整对象还是事件序列，工具结果由谁生成，为什么普通文本成功不足以证明工具往返成功

最后为一个失败制作证据卡。可使用第四章已验证模型的权限拒绝；没有数据库时，用一个明确不存在的模型名观察模型解析错误，并准确标记“不是权限实验”

**基础验收：**你能解释成功发生在哪一层，也能解释失败尚未证明哪一层有问题。你没有为了获得 200 而随意丢参数或关闭检查

### 14.2 进阶版，按已经具备的资源选择

| 实验 | 必须保留的正向证据 | 必须保留的反向对照 |
|---|---|---|
| 模型权限 | 管理员能调用，受限 Key 只能访问允许模型 | 已存在但不允许的模型被拒绝 |
| Key 撤销 | 撤销前可以调用 | 撤销后新请求被拒绝 |
| fallback | 人为主组故障，健康备用实际完成 | 移除 fallback 后同请求失败 |
| RPM | 专用非管理员 Key 正常调用 | 有界测试中观察到对应限流拒绝 |
| 响应缓存 | 相同请求有明确命中证据 | 绕过读写后重新调用上游 |
| 路由 | 记录到可区分的部署选择 | 不靠回答自报型号判断 |

预算触顶、真实跨区域容灾、多 worker 一致性和故障恢复，如果没有完成专门实验就保留为待验收项。**不把未验证项目写成已掌握的运行保证**

### 14.3 用五个问题检查理解

**问题一：**用户说“网页能打开，但模型用不了”，你先查什么？

答案：先区分 UI 管理链路与模型数据链路，检查请求的网关凭据、模型别名、错误类型和上游日志，不从 UI 正常推断推理正常

**问题二：**第二次请求快很多，能说 Redis 缓存生效了吗？

答案：不能，还可能是连接复用、上游 prompt cache 或负载变化，需要网关缓存头、命中指标或上游计数等证据

**问题三：**给同一个上游加两条配置，吞吐一定翻倍吗？

答案：不一定，可能共享同一配额与资源，还会共享故障。配置候选数量不等于独立容量

**问题四：**设置 daily budget 后，还要关心供应商账单吗？

答案：要，LiteLLM 依赖用量、价格和状态来准入，供应商侧仍需独立限制与对账

**问题五：**你能在不影响已有应用的前提下停止学习实验吗？

答案：应该能。实验使用独立入口、配置、数据库与测试 Key，只停止明确的学习进程或容器，不批量结束所有 LiteLLM 服务

### 14.4 收尾与复习

先在学习实例仍运行时撤销本次创建且仍有效的测试 Key。若不再需要，可在学习 UI 的用户管理中按准确的 `$StudyUserId` 移除本次普通学习用户，不能批量删除其他用户。然后停掉独立学习实例，清理终端里的临时凭据变量。只有确实不再需要时才删除明确的实验对象，不删除共享数据库或 Redis 数据

如果你后续要用 Cornell Notes，把**自己完成过的章节和真实结果**交给它，整理成“知识点、短问答、总结”。不要让复习笔记把“未验证”“需要第二个部署”这些限制删掉

### 14.5 学习反馈

合上文档，尝试从记忆解释一次请求的身份、协议、路由和费用归属。卡住时记录章节号、具体命令或动作、预期结果、实际状态码、运行版本和已遮盖敏感内容的错误摘要

把“我不懂缓存”改写成“第 10.3 节第二次请求没有缓存头，Redis ping 成功，上游调用数增加了两次”。这样的记录能直接进入下一轮排错，也能让教程下一版针对真正的障碍改进

---

## 官方来源与版本核对表

以下为本次直接查阅或通过官方文档研究核对的入口，查阅日期均为 2026-09-11。正文是面向当前学习起点的重新编排，不是对官方页面的逐段复制

在线页面会更新。配置与 API 实验应同时检查你的运行版本及学习实例的 `/openapi.json`。该 Schema 能确认接口和字段形状，但不能独自证明所有运行语义

| 编号 | 官方来源 | 本文使用范围 |
|---|---|---|
| S1 | [Proxy configuration][S1] | 模型别名、配置区块、环境变量、数据库覆盖 |
| S2 | [Gateway Quickstart][S2] | 启动、UI、持久化与凭据提示 |
| S3 | [Response headers][S3] | call ID、部署 ID、成本、重试与回退观察 |
| S4 | [Cost tracking][S4] | usage、spend、数据库记录 |
| S5 | [Configuration reference][S5] | Router 与模块配置字段 |
| S6 | [Streaming][S6] | 分块响应与流式处理 |
| S7 | [Responses API][S7] | 输入输出结构、桥接与能力边界 |
| S8 | [Function calling][S8] | 工具声明、执行、结果回传 |
| S9 | [Virtual keys][S9] | PostgreSQL、管理凭据、Key 使用 |
| S10 | [Official API schema][S10] | 普通用户创建与 Key generate、info、delete 请求形状 |
| S11 | [Reliability][S11] | fallback、废弃模拟参数、备用模型权限 |
| S12 | [Users, budgets and limits][S12] | 预算预留、重置、RPM/TPM、管理员例外 |
| S13 | [Production deployment][S13] | Salt Key、连接与生产边界 |
| S14 | [Model management][S14] | 模型的文件与数据库来源 |
| S15 | [Routing][S15] | 模型组、部署、策略与冷却 |
| S16 | [Redis requirements][S16] | 单进程与分布式状态 |
| S17 | [Timeouts][S17] | 网关与部署超时 |
| S18 | [Caching][S18] | Redis 响应缓存与连接检查 |
| S19 | [Caching controls][S19] | TTL、绕过、缓存命中头 |
| S20 | [Prompt caching][S20] | 上游输入前缀缓存与用量 |
| S21 | [Logging][S21] | 请求日志与诊断 |
| S22 | [Health checks][S22] | liveness、readiness、真实模型检查 |
| S23 | [Prometheus][S23] | callback、指标认证、多 worker |
| S24 | [Enterprise feature comparison][S24] | 不把整个功能类别误标成企业专属 |
| S25 | [Guardrails quickstart][S25] | 输入输出检查与执行阶段 |
| S26 | [MCP Gateway][S26] | 工具聚合与访问管理 |

[S1]: https://docs.litellm.ai/docs/proxy/configs
[S2]: https://docs.litellm.ai/docs/proxy/docker_quick_start
[S3]: https://docs.litellm.ai/docs/proxy/response_headers
[S4]: https://docs.litellm.ai/docs/proxy/cost_tracking
[S5]: https://docs.litellm.ai/docs/proxy/config_settings
[S6]: https://docs.litellm.ai/docs/completion/stream
[S7]: https://docs.litellm.ai/docs/response_api
[S8]: https://docs.litellm.ai/docs/completion/function_call
[S9]: https://docs.litellm.ai/docs/proxy/virtual_keys
[S10]: https://litellm-api.up.railway.app/openapi.json
[S11]: https://docs.litellm.ai/docs/proxy/reliability
[S12]: https://docs.litellm.ai/docs/proxy/users
[S13]: https://docs.litellm.ai/docs/proxy/prod
[S14]: https://docs.litellm.ai/docs/proxy/model_management
[S15]: https://docs.litellm.ai/docs/routing
[S16]: https://docs.litellm.ai/docs/proxy/redis_requirements
[S17]: https://docs.litellm.ai/docs/proxy/timeout
[S18]: https://docs.litellm.ai/docs/proxy/caching
[S19]: https://docs.litellm.ai/docs/proxy/caching_controls
[S20]: https://docs.litellm.ai/docs/completion/prompt_caching
[S21]: https://docs.litellm.ai/docs/proxy/logging
[S22]: https://docs.litellm.ai/docs/proxy/health
[S23]: https://docs.litellm.ai/docs/proxy/prometheus
[S24]: https://docs.litellm.ai/docs/enterprise
[S25]: https://docs.litellm.ai/docs/proxy/guardrails/quick_start
[S26]: https://docs.litellm.ai/docs/mcp
