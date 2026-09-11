# 学习笔记

这个目录用于沉淀本地开发、部署、排错和产品验证过程中形成的可复用资料

## 文档目录

- [LiteLLM 中文介绍 PPT：从接入到治理](litellm-introduction-zh.pptx)，26 页，适合先建立整体认识，来源链接放在各页备注和末页
- [LiteLLM 中文学习手册：原理、配置与实验](litellm-learning-handbook.md)，深入学习路由策略、可靠性、权限预算、缓存、日志与部署
- [GitHub Copilot API Console：从 Fork 到本地部署](github-copilot-api-console-deployment.md)
- [LiteLLM：从 Fork 到本地源码部署](litellm-local-source-deployment.md)
- [Azure Context Cache 与 AI Agent 缓存机制学习笔记](azure-context-cache-and-agent-caching.md)
- [Codex 接入 Azure Model Router：原理、API、计费与网关配置](azure-model-router-codex-gateways.md)
- [Codex、LiteLLM 与 Foundry：模型目录、接口地址及实测排错](codex-litellm-foundry-practice.md)

## 建议阅读顺序

先看介绍 PPT 建立整体认识，再按照学习手册完成最小接入、负载均衡、故障切换和治理实验，遇到 Foundry 或 Codex 接入问题时查阅对应专题

材料中的官方功能说明与本地实验结论分别标注。在线文档、当前源码与实际运行镜像可能不是同一版本，使用配置前应核对目标版本，不把某一次模型兼容实验当成所有模型的共同限制
