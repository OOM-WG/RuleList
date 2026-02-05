# MRS 规则集生成器

一个自动化工具，用于下载、处理和转换各种网络规则列表，并生成 Mihomo Rule Set (MRS) 格式的规则文件。

## 项目结构

```
.
|-- LICENSE
|-- README.md
|-- config.yaml   # 配置文件
`-- start.sh      # 主脚本
```

## 输出文件

每个任务会在 **`release`分支** 里生成 纯文本 和 mrs (mihomo)格式的文件  

## 当前配置的规则集

| 规则集 | 类型  | 说明                               |
| ------ | ----- | ---------------------------------- |
| `ad`   | 域名  | 广告过滤规则，整合多个广告拦截列表 |
| `cn`   | 域名  | 中国大陆域名规则                   |
| `cnIP` | IP 段 | 中国大陆 IP 地址段                 |

## 依赖
`yq jq curl wget gunzip sha256sum python`  

## GitHub Actions

项目配置了自动化工作流 [`.github/workflows/mrs.yml`](.github/workflows/mrs.yml)：

- 每天北京时间 3 点 45 分自动运行，可通过 GitHub 界面手动触发，可配置保留历史数量


## 许可证

本项目使用 GPL-3.0 许可证。详见 [LICENSE](LICENSE) 文件。

### 🔴 强制要求

- **必须开源**：任何使用本项目代码的软件都必须开源
- **相同许可证**：衍生作品必须使用 GPL-3.0 或兼容许可证
- **提供源码**：分发二进制文件时必须同时提供源代码
- **保留版权**：必须保留原始版权声明和许可证文本

### 🚫 禁止行为

- ❌ 将本项目代码用于闭源商业软件
- ❌ 删除或修改许可证声明
- ❌ 声称拥有本项目的专有权利
- ❌ 在专有软件中静态链接本项目代码

### ✅ 允许行为

- ✅ 自由使用、修改、分发
- ✅ 用于开源项目
- ✅ 商业使用（但必须开源）
- ✅ 通过网络 API 调用（无需开源调用方）

## 规则源说明

本项目目前聚合的规则来源于以下开源项目：

- [anti-AD](https://github.com/privacy-protection-tools/anti-AD)
- [AdRules](https://github.com/Cats-Team/AdRules)
- [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)
- [a-dove-is-dumb](https://github.com/ignaciocastro/a-dove-is-dumb)

各规则源保持其原有许可证，本项目仅提供聚合和转换服务。
