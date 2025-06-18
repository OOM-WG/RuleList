# MRS 规则集生成器

一个自动化工具，用于下载、处理和转换各种网络规则列表，并生成 Mihomo Rule Set (MRS) 格式的规则文件。

## 项目结构

```
.
├── config.yaml              # 主配置文件
├── start.py                 # 主脚本
├── requirements.txt         # Python依赖
├── .github/
│   └── workflows/
│       └── mrs.yml          # GitHub Actions工作流
└── out/                     # 输出目录（自动创建）
    ├── *.txt               # 原始文本格式规则
    └── *.mrs               # MRS格式规则
```

## 安装依赖

```bash
pip install -r requirements.txt
```

## 配置说明

### 基础配置

在 [`config.yaml`](config.yaml) 中配置基本参数：

```yaml
base:
  work_dir: "../tmp" # 工作目录
  output_dir: "./out" # 输出目录
  max_concurrent_downloads: 10 # 最大并发下载数
  max_concurrent_tasks: 3 # 最大并发任务数
  request_timeout: 30 # 请求超时时间（秒）
```

### 任务配置

每个任务支持以下配置：

```yaml
tasks:
  task_name:
    type: "domain" # 规则类型：domain/ipcidr
    format: "yaml" # 输出格式：yaml/text
    sources: # 规则源列表
      - url: "规则源URL"
        format_override: "text" # 覆盖源格式
        processors: ["remove_comments_and_empty"] # 处理器列表
```

### 支持的处理器

- `remove_comments_and_empty`: 移除注释和空行
- `format_pihole`: 转换为 Pihole 格式
- `format_yaml_list`: 转换为 YAML 列表格式

### GitHub Actions

项目配置了自动化工作流 [`.github/workflows/mrs.yml`](.github/workflows/mrs.yml)：

- **定时执行**: 每天北京时间 3 点 45 分自动运行
- **手动触发**: 支持在 GitHub 界面手动触发
- **代码更新**: 当相关文件更新时自动运行

工作流会：

1. 检出代码
2. 安装依赖
3. 运行脚本生成规则
4. 推送更新到仓库
5. 清理旧的工作流运行记录

## 输出文件

每个任务会生成两种格式的文件：

- `任务名.txt/yaml`: 原始格式的规则文件
- `任务名.mrs`: Mihomo Rule Set 格式的二进制文件

例如，`ad` 任务会生成：

- `out/ad.yaml`: YAML 格式的广告过滤规则
- `out/ad.mrs`: MRS 格式的广告过滤规则

## 当前配置的规则集

| 规则集 | 类型  | 说明                               |
| ------ | ----- | ---------------------------------- |
| `ad`   | 域名  | 广告过滤规则，整合多个广告拦截列表 |
| `cn`   | 域名  | 中国大陆域名规则                   |
| `cnIP` | IP 段 | 中国大陆 IP 地址段                 |

### 添加新任务

在 [`config.yaml`](config.yaml) 的 `tasks` 部分添加新任务配置即可。

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
