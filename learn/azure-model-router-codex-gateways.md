# Codex 接入 Azure Model Router：原理、API、计费与网关配置

## 2026-09-10 实测更新

本文主体保留 2026-09-08 的研究背景和候选方案。后续已用本地部署确认：Model Router 在资源级 Responses 返回操作不支持，但通过项目级 `/api/projects/PROJECT/openai/v1/responses` 和现有资源 Key 可以完成原生文本、流式和函数工具调用，经 LiteLLM 的真实 Codex CLI 请求也已成功，不需要 Chat 桥接

GPT-5.6-sol 在资源级和项目级 Responses 都已调用成功，因此两种模型不是必须使用不同 API Base。项目级 Entra 测试曾被当前账号的数据权限拒绝，不代表该接口必须使用 Entra 或不接受资源 Key

最新配置、Codex 自定义模型目录、CLI 菜单切换及 `reasoning.effort=none` 的修复见 [实测配置与排错笔记](codex-litellm-foundry-practice.md)。下文“未验证”的描述属于当时研究阶段，实际验证范围以这篇更新为准，仍不保证所有 Desktop 自动化和长期编码任务兼容

## 1. 先回答：是不是必须转换 API

**不能直接认定必须转换，也不能认定已经可以无损直连 Codex**

截至 2026-09-08，Microsoft 官方 Model Router 使用指南明确写道：

> You can use the Microsoft Foundry SDK with the Responses API or the OpenAI SDK with the Chat Completions API

同一页的示例调用 `project_client.get_openai_client()`，随后执行 `openai_client.responses.create(...)`。这说明 Foundry Responses 提供 OpenAI 兼容客户端接口，不能仅凭“Microsoft Foundry”这个名称，就判断它与 Codex 要求的 Responses 协议必然不兼容 [1]

需要把原说法拆成三个问题：

| 判断 | 当前结论 |
|---|---|
| 当前 Codex 自定义 Provider 要求 Responses 协议 | 是，当前配置 schema/source 只接受 `wire_api = "responses"`，不要照旧教程使用 `"chat"` [7] |
| Model Router 支持 Chat Completions，但完全没有 Responses 接口 | 不成立，官方已有 Foundry 项目 Responses 示例 [1][4] |
| Model Router 的所有 Responses 功能都兼容 Codex | 未确认，简单 `responses.create()` 成功不能证明 SSE、工具调用、推理内容和上下文压缩都兼容 |
| Foundry Responses 与 Azure OpenAI 资源级 Responses 是同一个 URL | 不是，两种端点的路径、认证和支持矩阵不能混用 [4][5][6] |
| 目标部署只提供可用的 Chat 接口时，需要转换 | 是，需要一个对 Codex 暴露 Responses、对上游调用 Chat 的协议桥接层 |

**建议顺序：先确认项目级原生 Responses 路径能否满足客户的 Codex 工作流，再考虑 Responses 与 Chat 的桥接**

本文的网关配置基于官方文档和实际开源实现整理。没有使用客户的 Azure 部署执行真实 Codex 任务，因此以下会明确区分“官方支持的 API”“源码存在的转换能力”和“仍需端到端验证的接入组合”

## 2. Model Router 是什么

### 2.1 一个部署，按请求选择底层模型

Azure Model Router 是 Microsoft Foundry 中可以部署的模型选择服务。应用始终请求同一个 Router deployment，由它分析输入并选择合适的底层模型回答 [1][2][3]

```text
应用发送一条请求
        |
        v
Model Router deployment
分析任务、上下文、工具定义和路由偏好
        |
        +-- 简单任务：可能选择成本较低的模型
        |
        +-- 复杂任务：可能选择推理或高能力模型
        |
        v
被选择的模型生成回答
        |
        v
返回回答、usage 和实际 model
```

例如，同一个编码 Agent 可能先让模型分类日志，再分析复杂并发错误，最后写一段总结。这三次请求可以选择不同模型，不是“一个 Codex 任务从头到尾只能使用一个模型”

这些例子说明路由目的，不是固定规则。官方将 Router 描述为经过训练的轻量机器学习模型，它预测适合的模型，而不是简单按关键词写 `if/else`，也不是默认同时调用所有候选模型，再投票选择答案 [3]

### 2.2 它和客户自建 AI 网关的分工

| 层级 | 主要解决的问题 |
|---|---|
| Codex | 理解用户任务、组织模型请求、执行本地工具、修改文件和运行测试 |
| 自建 AI 网关 | 客户端认证、配额、审计、网络入口、协议转换和后端路由 |
| Azure Model Router | 在允许的底层模型集合中，为当前推理请求选择模型 |
| 被选中的模型 | 生成文本、推理或工具调用 |

自建网关可以把别名 `azure-router` 路由到 Azure Router deployment，但这一步只是选择后端。Router 再选择底层模型，是另一层决策

LiteLLM 中名为 Router 的组件，也不能与 Azure Model Router 当作同一个产品。客户可以同时使用它们，但应避免两层都做复杂重试或 fallback，导致重复请求和费用难以解释

### 2.3 三种路由模式

| 模式 | 含义 | 编码场景中的考虑 |
|---|---|---|
| Balanced | 默认，在预测质量和成本之间权衡 | 适合作为初始评估方案 |
| Cost | 更偏向成本低的候选模型 | 适合分类、简单总结，但复杂修复可能增加返工 |
| Quality | 优先预测质量，而非最低价格 | 适合复杂排错或审查，但不能保证每次答案正确 |

路由依据包括 system message、user message、工具定义和历史上下文。不是只读取最后一句用户问题，也不是只看输入长度 [2][3]

### 2.4 模型池、版本和上下文限制

官方当前列出的活跃 Router 版本为 `2025-11-18`，它会原位增加模型和能力，版本号不一定变化。`2025-08-07` 和 `2025-05-19` 是冻结版本。因此，日期看起来较旧不等于不是当前版本 [2]

模型池已经不只包含 OpenAI 模型，还包括其他受支持 Provider。默认部署会使用符合权限和部署条件的候选集合。可以通过 model subset 只允许指定模型，新模型不会自动加入已明确配置的 subset [1][2]

通常不需要单独部署底层模型，Claude 是官方明确指出的例外，需要先在同一 Foundry 资源中完成相应部署 [1]

**编码任务建议先配置经过评估的模型子集**。有效上下文窗口受最小候选模型限制，不要把某个大模型的上下文窗口直接当成整个 Router 的窗口。工具格式、推理参数、多模态输入也必须在实际候选模型范围内验证 [2]

改变模式或模型子集可能需要最多约 5 分钟生效。Router 有自动 failover，指定 subset 也是允许的 fallback 集合，单模型 subset 无法提供跨模型备选 [1][2]

## 3. 计费：Router 不是免费转发

### 3.1 两部分费用

费用包括 Router 的输入处理费用，以及实际选中模型的输入、输出费用。Microsoft 官方评估工具给出的成本方法明确将 Router input markup 加到模型费用上 [8]

忽略缓存、特殊模态和其他计费项时：

```text
单次调用成本 =
  输入 Token / 1,000,000 × Router 输入单价
+ 输入 Token / 1,000,000 × 被选模型输入单价
+ 输出 Token / 1,000,000 × 被选模型输出单价
```

Router 官方价格页本次读取到的公开区域价格数据为约 USD 0.14 / 百万输入 Token。这是读取时的参考价格，不是合同报价，应按区域、币种、部署类型和客户协议重新确认 [9]

假设 Router 输入单价为 0.14，某底层模型输入单价为 2、输出单价为 8，单位都是 USD / 百万 Token。后两个数字只是算术示例：

```text
输入 20000 Token，输出 2000 Token

Router：20000 / 1000000 × 0.14 = 0.0028 USD
模型输入：20000 / 1000000 × 2 = 0.0400 USD
模型输出：2000 / 1000000 × 8 = 0.0160 USD
合计：0.0588 USD
```

有缓存时要按实际账单区分缓存读写，不应假设 Router 输入费也享受模型缓存折扣。推理 Token、工具服务和模型特殊计费项以对应价格与 usage 为准

### 3.2 Codex 任务为什么要按整个任务算

一次排错可能包含十几次模型调用和多次工具执行。模型切换还可能影响缓存命中和后续工具调用成功率

因此应比较“完成一个合格任务的总成本”，而不只是某一次请求的 Token 单价。便宜模型若增加了几轮失败修复，总成本可能反而上升

自建网关和 APIM 的资源成本需另外计算。网关日志应同时记录客户端别名、Router deployment、响应中的实际底层 `model` 和 usage，不能长期只给 `azure-router` 配一个固定价格就当成准确账单

## 4. 几个 API 到底有什么不同

### 4.1 Chat Completions 和 Responses

| 项目 | Chat Completions | Responses |
|---|---|---|
| 常见路径 | `/v1/chat/completions` | `/v1/responses` |
| 输入结构 | `messages` | `input`，可含消息、工具结果等 item |
| 普通文本输出 | `choices[].message.content` | `output[]` 中的消息与内容项 |
| 工具调用 | `tool_calls` 和 tool 消息 | function/custom 等 output item，以及对应工具结果 item |
| 流式输出 | Chat chunk，常见为 `choices[].delta` | 有类型的 Responses SSE 事件 |
| 会话与其他能力 | 通常由调用者组织历史 | 可涉及 response ID、推理 item、compaction 等额外语义 |

`response.output_text` 是 SDK 提供的便利属性，不能假设 HTTP JSON 顶层一定包含同名字段

这两种协议不只差 URL 和 `messages/input` 字段名。Codex 需要理解模型何时开始输出、何时完成工具参数、工具调用 ID 是什么、何时回传工具结果。只改两个字段不足以完成转换

### 4.2 不要把三种 Azure 入口混为一谈

| 入口 | 典型 URL | Model Router 证据 |
|---|---|---|
| Azure OpenAI 部署级 Chat | `https://RESOURCE.openai.azure.com/openai/deployments/DEPLOYMENT/chat/completions?api-version=2024-10-21` | 官方 Router Python 示例明确支持 [1][4] |
| Azure OpenAI 资源级 v1 Responses | `https://RESOURCE.openai.azure.com/openai/v1/responses` | 独立 Responses 支持列表没有列出 `model-router`，不能据此宣称支持，也不能把缺席直接当成所有部署都必然失败 [5] |
| Foundry 项目级 Responses | `https://RESOURCE.services.ai.azure.com/api/projects/PROJECT/openai/v1/responses` | 官方 Router 示例使用项目 OpenAI client；路径由 SDK 在 project endpoint 后追加 `/openai/v1` [4][6] |

Foundry 项目示例使用 Entra ID，token audience 对应 `https://ai.azure.com`，SDK scope 为 `https://ai.azure.com/.default`。不要把 Azure OpenAI 资源 API Key、管理平面 token 和项目推理 token 互换 [4][6]

所以“Foundry Responses 不是 OpenAI Responses，Codex 必然不能用”过于绝对。它是不同服务入口上的 OpenAI 兼容 API，但具体功能集合仍可能不同

### 4.3 如果转换，方向应该怎么说

按请求方向，正确描述是：

```text
Codex 发出 Responses 请求
        |
        v
网关：Responses 请求 -> Chat Completions 请求
        |
        v
Azure Router Chat 接口
        |
        v
网关：Chat 响应/SSE -> Responses 响应/SSE
        |
        v
Codex
```

“把 Chat 接口包装成 Responses 接口”是在描述对外能力；“Responses 转 Chat”是在描述发给上游的请求方向。两种说法可以指同一条链路，但文档必须写清请求和响应都需要处理

## 5. 如何创建和使用 Model Router

### 5.1 部署流程

在 Foundry model catalog 中选择 `model-router`，确认目标资源、区域、Global Standard 或 Data Zone Standard、配额和可用模型。创建时选当前 Router 版本，先使用 Balanced，或者指定符合工具调用、上下文及合规要求的模型子集 [1]

为 deployment 起明确名称，例如 `router-coding`。调用时的 `model` 填这个部署名，不是底层模型名。客户端也可以使用网关别名，由网关映射到 deployment

不要混淆 Router 模型版本、Azure 资源部署管理 API version、推理 API version。下面 Chat 示例沿用官方 Python 示例中的 `2024-10-21`，不是从 Router 的 `2025-11-18` 版本推导出来的

### 5.2 先独立调用 Chat

以下是供本地执行的 PowerShell 示例。先在当前终端通过安全方式设置 `AZURE_OPENAI_ENDPOINT`、`AZURE_OPENAI_API_KEY`、`MODEL_ROUTER_DEPLOYMENT_NAME`，不要把真实值写入文档：

```powershell
$body = @{
    model = $env:MODEL_ROUTER_DEPLOYMENT_NAME
    messages = @(
        @{ role = "user"; content = "Explain a race condition in two sentences." }
    )
} | ConvertTo-Json -Depth 8

$uri = "$($env:AZURE_OPENAI_ENDPOINT.TrimEnd('/'))/openai/deployments/$($env:MODEL_ROUTER_DEPLOYMENT_NAME)/chat/completions?api-version=2024-10-21"
$body | curl.exe --silent --show-error --fail-with-body $uri `
    -H "api-key: $env:AZURE_OPENAI_API_KEY" `
    -H "Content-Type: application/json" `
    --data-binary "@-"
```

查看响应中的 `model` 和 `usage`，明确到底由哪个底层模型处理请求。先让后端独立成功，再加入网关和 Codex，避免三个环节一起排错

### 5.3 项目级 Responses 的原生路径

官方示例通过以下客户端链路调用，示意省略认证初始化：

```text
AIProjectClient(project_endpoint, Entra credential)
  .get_openai_client()
  .responses.create(model=router_deployment, input=...)
```

下面用 PowerShell 直接请求 SDK 对应的 HTTP 入口，避免误把 project endpoint 当成资源 endpoint：

```powershell
az login
$token = az account get-access-token --resource https://ai.azure.com --query accessToken --output tsv
if ($LASTEXITCODE -ne 0) { throw "Failed to acquire the Foundry token" }

$uri = "$($env:FOUNDRY_PROJECT_ENDPOINT.TrimEnd('/'))/openai/v1/responses"
$body = @{
    model = $env:MODEL_ROUTER_DEPLOYMENT_NAME
    input = "Explain a race condition in two sentences."
    stream = $true
} | ConvertTo-Json

$body | curl.exe --no-buffer --silent --show-error --fail-with-body $uri `
    -H "Authorization: Bearer $token" `
    -H "Content-Type: application/json" `
    --data-binary "@-"
Remove-Variable token
```

其中 `FOUNDRY_PROJECT_ENDPOINT` 应类似 `https://RESOURCE.services.ai.azure.com/api/projects/PROJECT`。需要项目权限，`az login` 成功本身不代表有推理权限

这是原生流式路径的验证命令，不是本次已成功运行的记录。若失败，应区分 token audience、权限、路径、deployment、API 参数和流式能力，不要直接归因于“Responses 协议不兼容”

## 6. Codex 原生接入：优先验证的候选方案

### 6.1 配置位置与凭据

当前 Codex 自定义 Provider 配置在用户级 `%USERPROFILE%\.codex\config.toml`。配置前保留原有内容，只合并所需字段，不要覆盖用户的其他 Provider

以下是基于官方 Codex 配置和 Azure SDK 路径组合出的候选配置，尚未证明整个 Codex 工作流可用：

```toml
model = "router-coding"
model_provider = "foundry_router"

[model_providers.foundry_router]
name = "Foundry project Router"
base_url = "https://RESOURCE.services.ai.azure.com/api/projects/PROJECT/openai/v1"
wire_api = "responses"
supports_websockets = false

[model_providers.foundry_router.auth]
command = "az"
args = ["account", "get-access-token", "--resource", "https://ai.azure.com", "--query", "accessToken", "--output", "tsv"]
timeout_ms = 10000
refresh_interval_ms = 300000
```

Codex 支持 command-backed auth，由命令输出 bearer token，并按间隔刷新。Windows 上需确认该版本 Codex 可以解析并启动本机 Azure CLI 的入口，必要时使用实际可执行路径或受控凭据 helper。不要同时配置该 `auth` block 与 `env_key`、`requires_openai_auth` [7]

先关闭 WebSocket 支持以验证 HTTP SSE 路径，并不意味着后端一定不支持 WebSocket。不能只改变 `base_url` 就假设压缩接口、内置工具和推理状态也都兼容

### 6.2 客户坚持使用自建网关时

可以保留网关而不转换协议：

```text
Codex Responses
  -> 客户网关：认证、审计、别名映射、Entra token 获取
  -> Foundry 项目 Responses
  -> Router
```

网关客户端凭据和网关访问 Azure 的凭据应分离。项目侧鉴权和 SSE 透传需要正确实现，但不必预先引入 Chat 转换

## 7. 确实需要转换时：LiteLLM

### 7.1 已确认的配置开关

在 LiteLLM `v1.100.0` 中，存在明确的逐 deployment 参数：

```yaml
model_list:
  - model_name: azure-router
    litellm_params:
      model: azure/router-coding
      api_base: os.environ/AZURE_OPENAI_ENDPOINT
      api_key: os.environ/AZURE_OPENAI_API_KEY
      api_version: "2024-10-21"
      use_chat_completions_api: true
```

`azure-router` 是 Codex 看到的别名，`router-coding` 是真实 Azure Router deployment。`api_base` 填资源根端点，例如 `https://RESOURCE.openai.azure.com`，而不是 Foundry project endpoint

`use_chat_completions_api: true` 的含义是：即使客户端请求 `/v1/responses`，这个 deployment 也走 Chat Completions bridge。仅写 `model_info.mode: chat` 不能替代它。当前 Azure provider 有原生 Responses config，不能指望模型名不被识别就自动 fallback 到 Chat [10]

### 7.2 Codex 连接 LiteLLM

```toml
model = "azure-router"
model_provider = "router_gateway"

[model_providers.router_gateway]
name = "Router gateway"
base_url = "http://localhost:4000/v1"
env_key = "ROUTER_GATEWAY_API_KEY"
wire_api = "responses"
supports_websockets = false
```

在运行 Codex 的终端中设置 `ROUTER_GATEWAY_API_KEY`，值为网关颁发且授权访问 `azure-router` 的 key，不是 Azure API Key。企业部署使用 HTTPS，本例的 HTTP 仅用于本机

对当前仓库，不能只在磁盘新增 YAML 就认为正在运行的容器会读取它。需要把配置文件挂载进容器，并在已有 Compose service 中指定 `--config`：

```yaml
services:
  litellm:
    volumes:
      - .\router-config.yaml:/app/router-config.yaml:ro
    command:
      - "--config=/app/router-config.yaml"
      - "--port=4000"
```

这是合并到现有 Compose 的片段，不是完整替代文件。Azure 环境变量也必须注入容器。本文没有修改当前服务配置、没有启动新的网关实例

### 7.3 能转换，不等于所有工具无损

LiteLLM 有 Responses 请求转换、Chat 调用、返回 Responses JSON/SSE 的完整处理路径。当前版本也会把 `custom` 工具包装成 function，把 namespace 工具展开 [10][11]

但 custom grammar 放进 function 描述不等于底层模型原生执行 grammar 约束。所检查实现对部分 Responses 原生工具类型会丢弃并警告，例如 `shell`、`computer_use`、`image_generation`。这不等于所有“执行 shell 命令”都不可用，因为 Codex 可能通过不同 function/custom 工具表达同一行为，需要查看真实请求

`previous_response_id` 可能由 LiteLLM 的 session handler 重建历史，它不是 Azure Chat 的原生能力。多副本部署、重启后的历史恢复、加密 reasoning 和 `/responses/compact` 需要单独验收

## 8. 确实需要转换时：New API

### 8.1 普通 Azure 渠道不代表自动转换

本文的 New API 指 `QuantumNous/new-api`，不是泛指任意 OpenAI-compatible 网关。本次核对版本为 `v1.0.0-rc.35`，它是 RC 版本，不能假设所有既有部署都具备下面功能

普通 Azure 渠道对 Responses 请求通常直接构造 Azure Responses URL；配置 model mapping 只是改模型名，不会把 Responses 改为 Chat。不要把“支持两种 API”理解为“可以自动双向转换” [12]

### 8.2 使用 Advanced Custom 渠道

当前版本的 Advanced Custom 渠道支持真实转换器 `openai_responses_to_openai_chat_completions`，包括请求、非流式响应和流式响应转换 [13]

| 渠道字段 | 设置 |
|---|---|
| 类型 | Advanced Custom，当前类型编号 58 |
| Base URL | `https://RESOURCE.openai.azure.com` |
| Key | Azure 资源 API Key，在管理界面安全录入 |
| 对外模型 | `azure-router` |
| 模型映射 | `{"azure-router":"router-coding"}` |

Advanced Custom 编辑器中配置：

```json
{
  "advanced_routes": [
    {
      "incoming_path": "/v1/responses",
      "upstream_path": "/openai/deployments/{model}/chat/completions?api-version=2024-10-21",
      "converter": "openai_responses_to_openai_chat_completions",
      "auth": {
        "type": "header",
        "name": "api-key",
        "value": "{api_key}"
      }
    }
  ]
}
```

`{model}` 替换为模型映射后的部署名，`{api_key}` 来自渠道凭据。上面是编辑器中的配置对象；如果使用渠道管理 API，UI 实现将该对象保存进 `settings.advanced_custom`，然后将整个 settings 序列化为字符串，不能直接当成渠道顶层请求体 [13]

Codex 使用第 7.2 节相同的 Provider 结构，把 `base_url` 改为 New API 服务的 `/v1` 地址，环境变量的值换成 New API 为客户端颁发的 token

### 8.3 当前限制

当前 Responses-to-Chat 转换明确拒绝 `conversation`、`previous_response_id`、`prompt`、`context_management` 等有状态字段。若 Codex 实际发送这些字段，不能通过改模型别名解决 [14]

标准 function 工具有转换实现，但不能据此推断 custom grammar、namespace 和全部 Codex 特有交互都完整兼容。相比 LiteLLM，本次看到的工具适配范围更有限

因此这个配置可以作为协议桥接的功能验证起点，不能写成“New API 已无条件兼容 Codex + Router”

## 9. Azure APIM：区分治理代理和协议桥接

### 9.1 APIM 现成能力的边界

APIM 适合提供认证、限流、日志、后端选择和 SSE 转发。官方 Unified model API 文档本次确认的客户端入口是 Chat Completions，可连接 Chat 或 Anthropic Messages 后端，并没有给出 Codex Responses-to-Chat 完整转换承诺 [15]

`rewrite-uri`、`set-body`、Liquid 能改路径和 JSON，但一条 `set-body` 不会自动生成 Responses 流式事件、工具调用状态、response ID 和上下文管理能力

本次没有找到官方提供的完整 Responses-to-Chat APIM policy。这个结论不代表技术上不可能开发自定义转换器，而是不能把通用 policy 当作现成产品能力

### 9.2 推荐架构

```text
原生 Responses 满足需求：
Codex -> APIM / 自建网关 -> Foundry 项目 Responses -> Router

后端只能使用 Chat：
Codex -> APIM -> LiteLLM 协议桥接 -> Azure Router Chat
```

也可以将经过工作流验证的 New API 放在桥接位置。APIM 保留企业入口，不需要为了转换功能整体替换现有网关

### 9.3 APIM 转发到 LiteLLM 的最小示例

下面只为 `POST /responses` operation 配置。假设 APIM API suffix 是 `v1`，公共地址为 `https://GATEWAY.azure-api.net/v1/responses`，后端 LiteLLM 提供 `/v1/responses`

先启用 APIM API 的 subscription required，创建客户端 subscription key，并建立两个 Named Value：`litellm-backend-origin` 为仅含 scheme/host/port 的后端根地址，`litellm-backend-key` 为安全存储的 LiteLLM key，可关联 Key Vault

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service base-url="{{litellm-backend-origin}}" />
    <rewrite-uri template="/v1/responses" copy-unmatched-params="false" />
    <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
    <set-header name="Authorization" exists-action="override">
      <value>Bearer {{litellm-backend-key}}</value>
    </set-header>
  </inbound>
  <backend>
    <forward-request timeout="120" buffer-response="false" />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

这里故意不转换 body，因为协议转换由 LiteLLM 完成。后端必须能从 APIM 网络访问，不能把客户端电脑的 `localhost:4000` 填给云端 APIM

对应 Codex 配置：

```toml
model = "azure-router"
model_provider = "apim_router"

[model_providers.apim_router]
name = "APIM Router gateway"
base_url = "https://GATEWAY.azure-api.net/v1"
wire_api = "responses"
supports_websockets = false
env_http_headers = { "Ocp-Apim-Subscription-Key" = "APIM_SUBSCRIPTION_KEY" }
```

该示例用 APIM subscription key 做客户端认证，因此不要额外填 Azure API Key。客户若采用 OAuth/JWT，应沿用其认证规范，并调整 APIM inbound 验证，不能直接删除认证策略

`buffer-response="false"` 是 SSE 透传设置，不是 SSE 格式转换器。还应检查继承的 outbound policy 和诊断日志是否缓冲响应。官方 SSE 指南不建议 Consumption tier，并提示空闲连接超时、响应缓存和 body logging 的影响 [16]

本例没有添加 `/responses/compact`、WebSocket 等 operation。客户 Codex 若调用其他路径，需要独立验证后端支持并增加对应 operation，不能把未知路径全部重写成 `/v1/responses`

## 10. 三个网关如何选择

| 产品 | 本次确认的桥接入口 | 当前判断 |
|---|---|---|
| LiteLLM v1.100.0 | `use_chat_completions_api: true` | 有专门的 Responses bridge 和较多工具适配，可优先用于本地验证 |
| New API v1.0.0-rc.35 | Advanced Custom converter | 有双向响应处理，但有状态字段和工具类型限制要先核对 |
| Azure APIM | 未找到完整官方 Responses-to-Chat policy | 适合保留为治理入口，后接协议适配服务 |

已有自建网关的客户不一定需要迁移到这三个产品之一。如果网关可以原样转发项目 Responses 并处理 Entra 认证，优先验证原生链路。如果确实要桥接，可以新增专门适配后端，而不是在所有入口重写协议

## 11. 验证清单：怎样才算 Codex 真正可用

不要把“返回一段 Hello”作为最终结果。建议按下面顺序定位问题：

| 阶段 | 要验证什么 | 失败时先看哪里 |
|---|---|---|
| Azure 独立请求 | 正确 endpoint、认证、deployment，返回 model 和 usage | Azure 权限、区域、部署和 API |
| 原生 Responses SSE | 文本增量和结束事件完整 | 项目 API 流式支持、网络缓冲 |
| 网关 Responses SSE | 请求转换、返回事件类型、usage 正确 | 网关 converter、路径、鉴权 |
| Codex 只读任务 | 读取一个小文件并解释，能完成工具回合 | function/custom 工具与 call ID |
| Codex 修改任务 | 修改测试文件、运行测试、根据输出继续处理 | 多轮历史、工具结果回传 |
| 推理和长上下文 | reasoning 字段、上下文限制、可能的 compaction | 模型子集、API feature gap |
| 生命周期 | 取消、超时、断流、重试、token 续期 | SSE、网关重试和 Entra helper |
| 费用 | 同一任务累计费用、实际选中模型和重试次数 | Router meter、模型 usage、网关日志 |

可以在已运行的本机 LiteLLM 上先执行下面的流式请求，凭据由终端环境变量提供：

```powershell
@'
{
  "model": "azure-router",
  "input": "Explain why a mutex can prevent a race condition.",
  "stream": true
}
'@ | curl.exe --no-buffer --silent --show-error --fail-with-body `
    http://localhost:4000/v1/responses `
    -H "Authorization: Bearer $env:ROUTER_GATEWAY_API_KEY" `
    -H "Content-Type: application/json" `
    --data-binary "@-"
```

这只是协议入口验证，后面仍要执行 Codex 工具任务。日志中保留必要的 model、耗时、usage 和 request ID，避免记录真实凭据或客户代码正文

对于成本比较，使用同一组真实任务，分别对比固定模型、Router Balanced 和 Router 自定义 subset。记录完整任务成功率、修改正确性、工具失败率、总费用和任务耗时，不能仅比较单次请求 p95

## 12. 官方资料与实现依据

以下资料在 2026-09-08 核对。产品页面会继续更新，开源网关链接尽量固定到本次检查的版本

| 编号 | 资料 | 用途 |
|---|---|---|
| [1] | [Microsoft Learn：使用 Model Router](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/model-router) | 部署、模式、子集、两种官方调用示例 |
| [2] | [Model Router concepts](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/model-router) | 版本、上下文限制、模型池、区域和 failover |
| [3] | [How Model Router works](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/model-router-how-it-works) | 训练式选择、完整请求分析和选模流程 |
| [4] | [Microsoft 官方 Router 示例目录](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/foundry-models/model-router) | Foundry Responses 和 Azure Chat 调用、认证 |
| [5] | [Azure OpenAI Responses](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses) | 资源级 Responses 端点与独立支持列表 |
| [6] | [Azure AI Projects SDK 实现](https://github.com/Azure/azure-sdk-for-python/blob/main/sdk/ai/azure-ai-projects/azure/ai/projects/_patch.py) | project endpoint 拼接 `/openai/v1`，Entra scope |
| [7] | [Codex advanced config](https://developers.openai.com/codex/config-advanced/)；[Provider 实现](https://github.com/openai/codex/blob/main/codex-rs/model-provider-info/src/lib.rs) | 自定义 base URL、Responses、command-backed auth |
| [8] | [Microsoft Model Router 评估方法](https://github.com/microsoft-foundry/Model-Router-Auto-Evaluation/blob/main/docs/methodology.md#cost-calculation) | Router input markup 加底层模型费用 |
| [9] | [Azure Model Router pricing](https://azure.microsoft.com/en-us/pricing/details/ai-foundry-models/model-router/) | 当前价格查询入口 |
| [10] | [LiteLLM v1.100.0 Responses 分发](https://github.com/BerriAI/litellm/blob/v1.100.0/litellm/responses/main.py) | 强制 Chat bridge 开关 |
| [11] | [LiteLLM bridge handler](https://github.com/BerriAI/litellm/blob/v1.100.0/litellm/responses/litellm_completion_transformation/handler.py)；[工具转换](https://github.com/BerriAI/litellm/blob/v1.100.0/litellm/responses/litellm_completion_transformation/transformation.py) | SSE、session、工具兼容边界 |
| [12] | [New API 普通 Azure/OpenAI adaptor](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.35/relay/channel/openai/adaptor.go) | 原生 Responses forwarding 与 Chat 路径区别 |
| [13] | [New API Advanced Custom adaptor](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.35/relay/channel/advancedcustom/adaptor.go)；[配置 DTO](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.35/relaykit/dto/channel_settings.go) | 转换器、模板字段、自定义认证 |
| [14] | [New API Responses-to-Chat converter](https://github.com/QuantumNous/new-api/blob/v1.0.0-rc.35/relaykit/relayconvert/internal/oai_responses/to_oai_chat_req.go) | stateful 字段限制、工具转换范围 |
| [15] | [APIM Unified model API](https://learn.microsoft.com/en-us/azure/api-management/unified-model-api) | Chat 客户端入口的转换范围 |
| [16] | [APIM Server-sent events](https://learn.microsoft.com/en-us/azure/api-management/how-to-server-sent-events) | SSE 透传、缓冲和超时注意事项 |

**本次结论：Codex 要求 Responses，但 Model Router 已有官方 Foundry Responses 路径。是否必须转换，应由目标端点和真实 Codex 工具工作流决定，不能由 API 的产品名称直接决定**
