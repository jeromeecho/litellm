# Codex、LiteLLM 与 Foundry：模型目录、接口地址及实测排错

记录日期：2026-09-10

本文整理本地实际配置和调用结果。环境为 Windows、LiteLLM UI 显示版本 `1.100.0`、Codex CLI 从 `0.143.0` 升级到 `0.153.4`。结论只覆盖记录时的版本、Azure 部署和已测试功能，不代表所有模型、区域或客户端版本都相同

本文使用 `RESOURCE`、`PROJECT` 代替实际资源名称，不保存任何真实 Key。Model Router 原理、计费及不同网关的研究见 [原理与网关指南](azure-model-router-codex-gateways.md)

## 1. 最终接入方式

Codex 向 LiteLLM 发送 Responses 请求，LiteLLM 使用 OpenAI 协议适配器调用 Foundry 的原生 Responses 接口。本次成功方案没有经过 Chat Completions 桥接

```text
Codex CLI
  请求 model-router 或 gpt-5.6-sol
  使用 LiteLLM Virtual Key
        |
        v
LiteLLM http://localhost:4000/v1
  将 Public Model Name 映射到 Azure 部署
  使用 Foundry 资源 Key
        |
        v
Foundry OpenAI-compatible Responses
  指定 GPT 部署，或由 Model Router 选择底层模型
```

Provider 决定协议处理方式，API Base 决定目的地址，Key 决定认证身份。LiteLLM 中选择 OpenAI Provider 不代表请求发往 OpenAI 公网，实际请求仍发送到 API Base 指定的 Azure 资源

## 2. 为什么 GPT 和 Router 曾经填写不同的 API Base

Foundry 是统一平台，但资源级和项目级 API 入口的支持范围不完全相同。不能仅凭模型在同一个门户部署，就认为所有接口路径都能互换

资源级 Base：

```text
https://RESOURCE.services.ai.azure.com/openai/v1
```

项目级 Base：

```text
https://RESOURCE.services.ai.azure.com/api/projects/PROJECT/openai/v1
```

客户端在 Base 后追加 `/responses`。项目名必须使用实际 Foundry 项目名称，不是模型部署名

### 本地实际调用结果

| 模型与接口 | 资源级入口 | 项目级入口 |
|---|---|---|
| `gpt-5.6-sol`，Responses | 成功 | 成功 |
| `model-router`，Responses | HTTP 400，`The requested operation is unsupported.` | 成功 |
| `model-router`，Chat Completions | 成功 | 本轮未测试 |

资源级 Responses 的对比请求仅包含 `model` 和 `input`，相同地址、相同 Key，只更换模型名。直接调用 Azure 和经过 LiteLLM 的结果一致，因此这次 Router 的 400 不能归因于 Codex 工具请求复杂或 LiteLLM 转发错误

**两个模型并非必须使用不同 Base。GPT 和 Router 都已在项目级 Responses 上成功调用**。最终只调整了原先失败的 Router，GPT 保留已经可用的资源级配置

微软 [Responses 模型路由文档](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses-model-routing)使用 `AIProjectClient` 获取 OpenAI-compatible client，并用同一个 `responses.create()` 调用 Router 或指定模型。SDK 在项目端点之后追加 `/openai/v1`

### Key 与 Entra ID 的实测区别

官方示例使用 Entra ID，但本次测试也确认项目级 Responses 接受现有 Foundry 资源 Key，通过 OpenAI SDK 的 `api_key` 传入

本地 Azure CLI 登录身份调用项目级 Responses 返回 403，项目部署查询明确提示缺少数据权限。改用已有资源 Key 后，同一项目端点的 GPT 和 Router 都成功。因此，不能把官方示例的认证方式解释成“项目级 Responses 一定只能使用 Entra ID”

这个结果限定于本次模型调用，不表示 Foundry 的 Agents、评估或所有项目 API 都支持 Key。正式部署仍应按对应功能的认证文档和组织要求选择身份方案

## 3. LiteLLM 中的配置

| 字段 | GPT 部署 | Model Router |
|---|---|---|
| Provider | OpenAI | OpenAI |
| 自定义模型标识 | `openai/gpt-5.6-sol` | `openai/model-router` |
| Public Model Name | `gpt-5.6-sol` | `model-router` |
| API Base | 资源级或项目级 Base | 本次测通的项目级 Base |
| API Key | Foundry 资源 Key | Foundry 资源 Key |
| `use_chat_completions_api` | 不开启 | 不开启 |

这里假设 Azure 部署名与示例相同。如果部署使用其他名称，需要替换模型标识中的部署名。Public Model Name 则可以自由命名，Codex 使用的是这个公开别名

本次使用的 `azure_ai` Chat 适配器会对 `services.ai.azure.com` 追加 `/models/chat/completions`。将 `/openai/v1` 地址原样填入它，会产生不匹配的路径。曾出现的 `%20` 则来自输入框末尾空格，是另一个问题

Azure、Azure AI Foundry (Studio)、OpenAI 这些选项对应不同适配器，并非按部署门户机械分类。Azure 适配器仍有部署级 API、Azure 认证等用途，不能因此认为它没有存在意义

UI 的 Mode 主要用于健康检查接口选择，不是 Azure Router 的 Balanced、Cost、Quality 模式，也不是 Responses 到 Chat 的转换开关。Chat Playground 成功不能证明 Responses 接口成功

## 4. Virtual Key、Provider 与模型的关系

一个 LiteLLM Virtual Key 可以访问多个模型。`All Proxy Models` 是权限范围，不会自动给 Codex 生成模型菜单，也不会替 Codex选择模型

同一个 Provider 可以连接同一个 LiteLLM 地址，使用同一个 Key，并通过请求中的 `model` 选择不同模型。只有需要分别管理预算、权限或使用记录时，才有必要拆成多个 Key

```toml
model = "gpt-5.6-sol"
model_provider = "litellm"
model_reasoning_effort = "medium"
model_catalog_json = 'C:\Users\YOUR_USER\.codex\litellm-models.json'

[model_providers.litellm]
name = "Local LiteLLM"
base_url = "http://localhost:4000/v1"
env_key = "LITELLM_API_KEY"
wire_api = "responses"
```

这里的 `LITELLM_API_KEY` 是环境变量名称，保存的是 LiteLLM Virtual Key，不是 Azure Key。真实 Key 不应写入文档、仓库或聊天记录

顶层 `model` 只能指定一个默认模型，但这不等于客户端永久只能使用一个模型。CLI 启动时可以覆盖默认值：

```powershell
codex --model gpt-5.6-sol
codex --model model-router
codex -c 'model_provider="litellm"' --model model-router
```

## 5. `litellm-models.json` 是什么

**它是 Codex 的模型目录，不是 LiteLLM 的服务端配置**。文件名是本地自定义名称，官方配置项是 `model_catalog_json`

Codex `0.153.4` 的 [官方配置 Schema](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/config.schema.json)说明：

> Optional path to a JSON model catalog (applied on startup only)

即指定可选 JSON 模型目录，只在启动时应用。修改文件后要重新启动 Codex，不能期待已经运行的会话自动重新加载

| 文件 | 职责 |
|---|---|
| `config.toml` | 默认模型、Provider、地址、认证环境变量、模型目录路径等 |
| `litellm-models.json` | 模型菜单条目、默认推理强度、支持的推理选项、上下文预算、工具及模态能力等 |
| LiteLLM 模型配置 | 将公开模型别名映射到实际部署、上游地址和 Azure 凭据 |

JSON 顶层是 `models` 数组，每条是 Codex 模型元数据，不是 LiteLLM `/v1/models` 返回的 `data` 数组。模型条目的 `slug` 应匹配网关公开别名

在本次版本中，自定义目录**替换内置目录，不是追加**。想在菜单里保留两个模型，就必须在文件里保留两条完整元数据。这个文件不含 Key，不会创建 Azure 部署，也不增加调用权限

本地目录保留两个条目：`gpt-5.6-sol` 和 `model-router`。实际通过 Codex app-server 的 `model/list` 查询确认，两条都可见；用户随后也确认 CLI 菜单切换成功

### 为什么不能只写两个模型名

Codex 需要知道如何组织请求及工具。元数据会影响推理强度、上下文处理、指令、工具格式和运行方式，因此不只是菜单标签

GPT 条目以 `0.153.4` 官方目录为基础，并针对标准 Responses 接入关闭 Responses Lite、改用 direct 工具模式、移除未验证的服务速度档位。它不是未经调整的官方默认配置，也不意味着 Azure 支持所有 OpenAI 专有功能

Router 使用保守的文本和函数工具配置，不冒充某一个 GPT 型号。当前 32K 上下文及 24K 自动压缩阈值是本地客户端预算，不是 Azure 官方最大上下文。随着路由模型池变化，应重新确认共同能力和有效上下文限制

目录结构随 Codex 版本变化，不建议直接复制其他版本的完整条目。特别是部分旧字段在新版本中可能被忽略，不能仅凭 JSON 中写了某个开关就认定运行行为已改变

## 6. CLI 菜单、Desktop 与升级

CLI 的 `/model` 菜单来自 Codex 模型目录。通过环境变量 Key 连接自定义 Provider 时，本次版本没有自动把 LiteLLM 的模型别名同步到目录中

旧 CLI `0.143.0` 能请求 `gpt-5.6-sol`，但找不到元数据，出现 fallback metadata 警告，菜单只显示内置旧模型。升级并配置目录后，CLI 能在同一个 Provider、同一个 Key 下通过 `/model` 选择两个模型

本次升级目标是官方 GitHub Release `0.153.4`。当时 npm 镜像和公共 registry 均没有该版本，因此使用官方 Release 的 npm launcher 和 Windows runtime 包，校验 GitHub 资产 SHA-256 后安装。升级只针对 npm CLI，没有替换 Desktop 或 VS Code 扩展的内置运行时

Desktop 读取用户配置文件有 [LiteLLM 官方教程](https://docs.litellm.ai/docs/tutorials/openai_codex#6-using-the-codex-desktop-app)依据，但不要把 CLI 菜单行为直接等同于 Desktop。本文没有确认该 Desktop 版本能够通过自定义目录提供同样的模型切换体验

用户已有会话曾保留 `model-router`，即使默认模型已经改为 GPT，继续旧会话仍调用 Router。改默认模型后应新建会话，不能只重启再打开旧会话判断切换结果

## 7. `reasoning.effort=none` 错误的根因

最初 Router 目录的 `supported_reasoning_levels` 为空，`default_reasoning_level` 为 null。通过菜单选择 Router 时，Codex 使用并保存了 `none`，但 Azure 明确拒绝：

```text
Unsupported value: 'none' is not supported with the 'model-router-2025-11-18' model.
Supported values are: 'low', 'medium', and 'high'.
```

此前命令行测试沿用了 `medium`，所以通过了，却没有覆盖菜单切换后变为 `none` 的情况。这是本地目录配置问题，不是 Key、API Base 或模型无法对话

修复后的 Router 条目包含以下字段片段。它仅展示修复部分，不是可单独使用的完整目录：

```json
{
  "supported_reasoning_levels": [
    {"effort": "low", "description": "Lower reasoning effort"},
    {"effort": "medium", "description": "Medium reasoning effort"},
    {"effort": "high", "description": "Higher reasoning effort"}
  ],
  "default_reasoning_level": "medium"
}
```

同时将 `config.toml` 中已保存的 `model_reasoning_effort = "none"` 改为 `"medium"`。`model_reasoning_summary = "none"` 是另一个字段，不能因为名称相似就一起改掉

修复后通过实际运行时 `model/list` 确认菜单默认值为 medium、选项为 low/medium/high，并通过真实 Codex Router 请求收到 `OK`

`Skill descriptions were shortened...` 是技能描述因上下文预算被压缩的提示，与 Azure 400 错误不同。它不阻止本次简单对话，但说明保守上下文预算会影响技能描述长度

## 8. 验证范围与尚未保证的行为

| 验证项目 | 结果 |
|---|---|
| 项目级 Responses，资源 Key，Router 简单文本 | 成功 |
| 项目级 Responses，Router SSE | 收到输出和 `response.completed` |
| 原生 Responses 函数调用及结果回传 | 成功 |
| LiteLLM 保存 Router 项目级地址后，真实 Codex 简单对话 | 成功 |
| 真实 Codex 调用 PowerShell 计算 `2+2`，再处理工具结果 | 返回 `4` |
| CLI 自定义目录显示两个模型 | 成功 |
| Router 菜单切换后的 reasoning 选项 | 修复后运行时返回 low/medium/high，默认 medium |
| 任意长任务、所有路由目标、所有 Desktop 自动化功能 | 未完整验证 |

额外测试发现，Chat 桥接虽然非流式对话和函数回传成功，但流式路径遇到 Azure `choices=[]` 的事件时，当前 LiteLLM 抛出 `IndexError`。本次采用原生项目级 Responses 绕开这条路径，没有修复该桥接代码

模型自己的“我是哪个模型”回答不是可靠身份依据。应结合请求中的公开别名、网关记录和 Azure 返回的 `response.model` 判断实际路由。调用成功也不代表 Router 附加费已被当前 OpenAI 适配路径准确计入

## 9. 参考资料

| 来源 | 用途 |
|---|---|
| [Microsoft：Responses 模型路由](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses-model-routing) | 同一项目客户端调用 Router 和指定模型 |
| [Microsoft：Model Router 使用指南](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/model-router) | 部署、模型池及调用示例 |
| [Microsoft：Foundry 认证与授权](https://learn.microsoft.com/en-us/azure/foundry/concepts/authentication-authorization-foundry) | Key、Entra ID、控制面及数据面的区别 |
| [Codex 0.153.4 配置 Schema](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/config.schema.json) | `model_catalog_json` 的正式配置定义 |
| [Codex 0.153.4 模型元数据类型](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/protocol/src/openai_models.rs) | 模型目录结构及版本相关字段 |
| [Codex 0.153.4 官方模型目录](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/models-manager/models.json) | GPT 模型元数据基础 |
| [LiteLLM：Codex 接入教程](https://docs.litellm.ai/docs/tutorials/openai_codex) | CLI、Desktop、自定义 Provider 和环境变量 |
