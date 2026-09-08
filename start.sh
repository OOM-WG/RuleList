#!/bin/bash
set -e 

config_file="config.yaml"
if [ ! -f "$config_file" ]; then
    echo "错误: 找不到配置文件 $config_file"
    exit 1
fi

# 检查必要命令是否存在
for cmd in yq jq curl wget gunzip sha256sum; do
    if ! command -v $cmd &> /dev/null; then
        echo "错误: 系统未安装 $cmd，请先安装。"
        exit 1
    fi
done

work_dir=$(yq -r '.work_dir' "$config_file")
rm -rf "$work_dir" || true
mkdir -p "$work_dir"

api_url=$(yq -r '.mihomo.api_url' "$config_file")
start_with=$(yq -r '.mihomo.start_with' "$config_file")
end_with=$(yq -r '.mihomo.end_with' "$config_file")

if [ -z "$api_url" ] || [ "$api_url" == "null" ]; then
    echo "错误: 无法从 YAML 中解析配置，请检查配置文件格式。"
    exit 1
fi

echo "正在获取 API 信息..."
# 增加 -L 以跟随重定向，-f 以在 HTTP 错误时失败
if [ -n "$GITHUB_TOKEN" ]; then
  AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
else
  AUTH_HEADER="User-Agent: curl"
fi
api_response=$(curl -sL -f -H "$AUTH_HEADER" "$api_url")
if [ $? -ne 0 ]; then
    echo "错误: 无法连接到 API 地址 (可能是速率限制或网络问题)。"
    exit 1
fi

# 使用 jq -c 强制单行输出，确保 head -n 1 截取的是完整的一行 JSON 对象
asset_info=$(echo "$api_response" | jq -c ".[] | .assets[] | select(.name | startswith(\"$start_with\") and endswith(\"$end_with\"))" | head -n 1)
if [ -z "$asset_info" ] || [ "$asset_info" == "null" ]; then
    echo "错误: 未找到符合条件 ($start_with ... $end_with) 的资源。"
    exit 1
fi
echo "解析到的资源信息: $asset_info"

download_url=$(echo "$asset_info" | jq -r '.browser_download_url')
echo "下载链接: $download_url"

# 处理 digest，兼容带 sha256: 前缀或不带的情况
expected_digest=$(echo "$asset_info" | jq -r '.digest' | cut -d ':' -f 2)
echo "预期校验和: $expected_digest"

if [ -z "$download_url" ] || [ "$download_url" == "null" ]; then
    echo "错误: JSON 中未找到下载链接。"
    exit 1
fi

echo "开始下载: $download_url"
wget -q -O "$work_dir/mihomo.gz" "$download_url"
if [ $? -ne 0 ]; then
    echo "错误: 下载文件失败。"
    exit 1
fi

echo "验证下载的文件"
# sha256sum 输出格式为 "hash  filename"，awk '{print $1}' 取第一列
actual_digest=$(sha256sum "$work_dir/mihomo.gz" | awk '{print $1}')

if [ "$actual_digest" != "$expected_digest" ]; then
    echo "错误: 文件校验失败！"
    echo "预期: $expected_digest"
    echo "实际: $actual_digest"
    exit 1
fi
echo "文件校验成功。"

echo "正在解压..."
gunzip -f "$work_dir/mihomo.gz"
if [ $? -ne 0 ]; then
    echo "错误: 解压文件失败。"
    exit 1
fi

chmod +x "$work_dir/mihomo"
echo "Mihomo 已就绪: $work_dir/mihomo"

# ---------- 准备 sing-box（用于生成 .srs 格式，仅当有任务需要时）----------
SING_BOX_BIN=""
if yq -r '.tasks[].format' "$config_file" | grep -q "srs"; then
    if [ -n "$SING_BOX_PATH" ] && [ -x "$SING_BOX_PATH" ]; then
        # 本地测试可直接指定 SING_BOX_PATH=/path/to/sing-box 跳过下载
        SING_BOX_BIN="$SING_BOX_PATH"
        echo "使用本地 sing-box: $SING_BOX_BIN"
    else
        sb_api_url=$(yq -r '.singbox.api_url' "$config_file")
        sb_start=$(yq -r '.singbox.start_with' "$config_file")
        sb_end=$(yq -r '.singbox.end_with' "$config_file")
        echo "正在获取 sing-box API 信息..."
        sb_api_response=$(curl -sL -f -H "$AUTH_HEADER" "$sb_api_url")
        if [ $? -ne 0 ] || [ -z "$sb_api_response" ]; then
            echo "错误: 无法连接 sing-box API ($sb_api_url)。"
            exit 1
        fi
        sb_asset=$(echo "$sb_api_response" | jq -c ".[] | .assets[] | select(.name | startswith(\"$sb_start\") and endswith(\"$sb_end\"))" | head -n 1)
        if [ -z "$sb_asset" ] || [ "$sb_asset" == "null" ]; then
            echo "错误: 未找到符合条件的 sing-box 资源 ($sb_start ... $sb_end)。"
            exit 1
        fi
        sb_url=$(echo "$sb_asset" | jq -r '.browser_download_url')
        echo "下载 sing-box: $sb_url"
        wget -q -O "$work_dir/singbox.tar.gz" "$sb_url"

        # digest 可能为 null（旧 release），为空则跳过校验
        sb_digest=$(echo "$sb_asset" | jq -r '.digest // ""' | cut -d ':' -f 2)
        if [ -n "$sb_digest" ]; then
            sb_actual=$(sha256sum "$work_dir/singbox.tar.gz" | awk '{print $1}')
            if [ "$sb_actual" != "$sb_digest" ]; then
                echo "错误: sing-box 文件校验失败！"
                echo "预期: $sb_digest"
                echo "实际: $sb_actual"
                exit 1
            fi
            echo "sing-box 文件校验成功。"
        fi

        tar -xzf "$work_dir/singbox.tar.gz" -C "$work_dir"
        SING_BOX_BIN=$(find "$work_dir" -type f -name "sing-box" | head -n 1)
        if [ -z "$SING_BOX_BIN" ]; then
            echo "错误: 解压后未找到 sing-box 二进制。"
            exit 1
        fi
        chmod +x "$SING_BOX_BIN"
        echo "sing-box 已就绪: $SING_BOX_BIN ($("$SING_BOX_BIN" version | head -n 1))"
    fi
fi

output_dir=$(yq -r '.output_dir' "$config_file")
rm -rf "$output_dir" || true
mkdir -p "$output_dir"


echo "开始处理任务..."
# 遍历 tasks 下的所有键名
task_names=$(yq -r '.tasks | keys | .[]' "$config_file")

for task in $task_names; do
    echo "---------------------------------------"
    echo "正在处理任务: $task"

    # 获取该 task 的所有下载链接
    urls=$(yq -r ".tasks.$task.src[]" "$config_file")

    # 如果 YAML 中没有 custom_script，yq 可能会返回 null，这里做处理
    custom_script_content=$(yq -r ".tasks.$task.custom_script" "$config_file")
    
    # 在 Bash 中判断：如果是 null 则视为空字符串
    if [ "$custom_script_content" == "null" ]; then
        custom_script_content=""
    fi
    
    export CUSTOM_SCRIPT="$custom_script_content"

    for url in $urls; do
        echo "正在下载: $url"
        filename=$(basename "$url")
        download_path="$work_dir/$filename"
        
        if ! wget -q -O "$download_path" "$url"; then
            echo "错误: 下载失败 $url，退出..."
            exit 1
        fi

        # 处理不同格式
        sed -i -e '$a\' "$download_path"  # 确保文件以换行符结尾

        if [[ "$filename" == "pihole.txt" ]]; then
            echo "   -> 检测到 pihole.txt，正在添加 (+.) 前缀..."
            # 逻辑说明：
            # s/^/+./  : 将行首 (^) 替换为 (+.)
            # 仅对不以 # 开头的行操作，防止破坏注释
            sed -i '/^[a-zA-Z0-9]/ s/^/+./' "$download_path"
        fi

        if [[ "$filename" == *.yaml ]]; then
            sed -n '/^payload:/,$ { /^[[:space:]]*-[[:space:]]*/ { s/^[[:space:]]*-[[:space:]]*//; s/['\'']//g; p } }' "$download_path" >> "$work_dir/tmp.txt"
        else
            cat "$download_path" >> "$work_dir/tmp.txt"
        fi
    done

    output_file="$output_dir/${task}.txt"
    echo "字典序排序、去重 (智能语义过滤)"
    sed -i -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "$work_dir/tmp.txt"

    # 读取第一行用于判断类型
    first_line=$(head -n 1 "$work_dir/tmp.txt")

    # 判断逻辑：如果包含 冒号(:) 或者 斜杠(/)，认为是 IP段
    if [[ "$first_line" =~ [:/] ]]; then
        echo "类型：IP/CIDR 网段 (启用语义合并)"
        behavior="ipcidr"
        # 使用 Python ipaddress 模块进行 CIDR 合并
        python3 - "$work_dir/tmp.txt" "$output_file" <<-'EOF'
import sys
import ipaddress

input_path = sys.argv[1]
output_path = sys.argv[2]
print(f"Python (IP模式) 正在读取: {input_path}")

ipv4_nets = []
ipv6_nets = []

try:
    with open(input_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                # strict=False 允许非规范写法，例如 192.168.1.5/24 会自动修正为网段地址 192.168.1.0/24
                net = ipaddress.ip_network(line, strict=False)
                if net.version == 4:
                    ipv4_nets.append(net)
                else:
                    ipv6_nets.append(net)
            except ValueError:
                # 遇到非 IP 格式的行（可能是误判的域名），静默跳过或打印警告
                # print(f"忽略无效 IP: {line}")
                pass

    # 核心逻辑：collapse_addresses 会自动去除包含关系并合并相邻网段
    # 例如：1.1.1.1/32 被包含在 1.1.1.0/24 中，前者会被移除
    # 例如：1.0.0.0/25 和 1.0.0.128/25 会被合并为 1.0.0.0/24
    merged_v4 = list(ipaddress.collapse_addresses(ipv4_nets))
    merged_v6 = list(ipaddress.collapse_addresses(ipv6_nets))

    # 排序
    merged_v4.sort()
    merged_v6.sort()

    print(f"Python (IP模式) 正在写入: {output_path}")
    with open(output_path, 'w', encoding='utf-8', newline='\n') as f:
        for net in merged_v4:
            f.write(str(net) + '\n')
        for net in merged_v6:
            f.write(str(net) + '\n')

except FileNotFoundError:
    print(f"错误: 找不到文件 {input_path}")
    sys.exit(1)
except Exception as e:
    print(f"发生未知错误: {e}")
    sys.exit(1)
EOF
        # 检查 Python 退出代码
        if [ $? -eq 0 ]; then
            echo "生成文件: $output_file (总行数: $(wc -l < "$output_file"))"
        else
            echo "错误：IP 处理脚本执行失败"
            exit 1
        fi

    else
        echo "类型：域名列表"
        behavior="domain"

        # 让 Python 全权负责：读取 -> 清洗 -> 逻辑去重 -> 写入
        python3 - "$work_dir/tmp.txt" "$output_file" <<-'EOF'
import sys
import re
import os
from collections import defaultdict
input_path = sys.argv[1]
output_path = sys.argv[2]
print(f"Python (域名模式) 正在读取: {input_path}")
def get_clean_domain(domain_str):
    # 去除 +. *. . 等前缀，只保留纯域名用于逻辑判断
    return re.sub(r'^[\+\*\.]+', '', domain_str)
try:
    # 1. 读取文件
    raw_lines = []
    with open(input_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                raw_lines.append(line)
    
    # 2. 基础去重与排序 (父子域名逻辑)
    # 先按长度排序
    raw_lines.sort()
    raw_lines.sort(key=lambda x: len(get_clean_domain(x)))

    # 4. 智能去重逻辑    
    roots = set()
    domains = [] # 这个变量将暴露给自定义脚本使用
    
    for line in raw_lines:
        clean_domain = get_clean_domain(line)
        parts = clean_domain.split('.')
        is_redundant = False
        
        # 自身查重
        if clean_domain in roots:
            is_redundant = True
        else:
            # 父级查重
            for i in range(1, len(parts)):
                parent = ".".join(parts[i:])
                if parent in roots:
                    is_redundant = True
                    break
        
        if not is_redundant:
            domains.append(line)
            roots.add(clean_domain)
    # 执行 YAML 中的自定义脚本
    custom_code = os.environ.get('CUSTOM_SCRIPT', '')
    if custom_code and custom_code.strip() != "":
        try:
            # 使用 exec 执行字符串代码，传入 domains 变量
            # 用户在 YAML 中可以直接操作 domains 列表
            exec_globals = {}
            exec_locals = {'domains': domains, 're': re}
            exec(custom_code, exec_globals, exec_locals)
            
            #以此取回修改后的列表
            domains = exec_locals['domains']
            print(f"  -> 自定义脚本执行完毕")
        except Exception as e:
            print(f"  -> [警告] 自定义脚本执行失败: {e}")
            # 即使脚本失败，也继续往下走，不要中断整个流程
    # 泛滥子域检测警告
    # 逻辑：取域名的后缀（去掉第一段），统计出现次数
    suffix_counter = defaultdict(int)
    for line in domains:
        clean = get_clean_domain(line)
        parts = clean.split('.')

        # 如果域名层级少于 4，跳过检查
        if len(parts) < 4:
            continue
        # 获取父级域名（去掉最左边的一段）
        suffix = ".".join(parts[1:])
        suffix_counter[suffix] += 1
    
    warned = False
    sorted_suffixes = sorted(suffix_counter.items(), key=lambda x: x[1], reverse=True)
    for suffix, count in sorted_suffixes:
        if count >= 17: # 阈值可调整
            if not warned:
                print("  -> [注意] 检测到以下后缀包含大量子域名:")
                warned = True
            print(f"     Suffix: .{suffix} (包含 {count} 个条目)")
    # 5. 写入文件
    print(f"Python (域名模式) 正在写入: {output_path}")
    with open(output_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write("\n".join(domains))
        f.write("\n")
except FileNotFoundError:
    print(f"错误: 找不到文件 {input_path}")
    sys.exit(1)
except Exception as e:
    print(f"发生未知错误: {e}")
    sys.exit(1)
EOF
        if [ $? -eq 0 ]; then
            echo "生成文件: $output_file (总行数: $(wc -l < "$output_file"))"
        else
            echo "错误：域名脚本执行失败"
            exit 1
        fi
    fi


    # 按任务配置的 format 列表（空格分隔，如 "mrs srs"）依次生成
    formats=$(yq -r ".tasks.$task.format // \"mrs\"" "$config_file" | tr ' ' '\n' | sed '/^$/d')

    for fmt in $formats; do
        if [ "$fmt" == "mrs" ]; then
            echo "转换为 mrs 格式"
            $work_dir/mihomo convert-ruleset $behavior text "$output_file" "$output_dir/${task}.mrs"
            echo "生成文件: ${task}.mrs (文件大小: $(du -h "$output_dir/${task}.mrs" | awk '{print $1}'))"
        elif [ "$fmt" == "srs" ]; then
            if [ -z "$SING_BOX_BIN" ]; then
                echo "错误: 任务 $task 需要 srs 格式，但 sing-box 未就绪。"
                exit 1
            fi
            echo "转换为 srs 格式"
            # 1. txt -> sing-box source JSON
            python3 - "$output_file" "$behavior" "$work_dir/${task}.srs.json" <<-'EOF'
import sys, json, re, ipaddress
input_path, behavior, output_path = sys.argv[1], sys.argv[2], sys.argv[3]

# 合法域名：多级域名，或单标签（如 geosite 中的 anquan/alipay 特殊条目，
# sing-box 的 domain_suffix 支持单标签匹配）
DOMAIN_RE = re.compile(r'^[a-zA-Z0-9_](?:[a-zA-Z0-9_-]*[a-zA-Z0-9_])?(?:\.[a-zA-Z0-9_](?:[a-zA-Z0-9_-]*[a-zA-Z0-9_])?)*$')

try:
    if behavior == 'domain':
        exact, suffix = [], []
        for line in open(input_path, encoding='utf-8'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            # 域名模式里跳过纯 IP 行（IP 走 ipcidr 任务）
            try:
                ipaddress.ip_address(line.lstrip('+.*'))
                continue
            except ValueError:
                pass
            # +.x / *.x -> domain_suffix（mihomo 的 *. 是单级通配，这里按
            # sing-box 语义放宽为任意层级后缀，与绝大多数列表的实际意图一致）
            if line.startswith(('+.', '*.')):
                d = line[2:]
                if DOMAIN_RE.match(d):
                    suffix.append(d)
                else:
                    print(f'  -> [srs] 跳过无效域名: {line}')
            else:
                if DOMAIN_RE.match(line):
                    exact.append(line)
                else:
                    print(f'  -> [srs] 跳过无效域名: {line}')
        rule = {}
        if exact:
            rule['domain'] = exact
        if suffix:
            rule['domain_suffix'] = suffix
        if not rule:
            print('错误: 没有任何有效域名，无法生成 srs')
            sys.exit(1)
        data = {'version': 3, 'rules': [rule]}
    elif behavior == 'ipcidr':
        nets = []
        for line in open(input_path, encoding='utf-8'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            try:
                # strict=False 自动规范化（如 1.2.3.4/24 -> 1.2.3.0/24）
                nets.append(str(ipaddress.ip_network(line, strict=False)))
            except ValueError:
                print(f'  -> [srs] 跳过无效网段: {line}')
        if not nets:
            print('错误: 没有任何有效网段，无法生成 srs')
            sys.exit(1)
        data = {'version': 3, 'rules': [{'ip_cidr': nets}]}
    else:
        print(f'错误: 未知 behavior: {behavior}')
        sys.exit(1)

    with open(output_path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    total = sum(len(r.get(k, [])) for r in data['rules'] for k in r)
    print(f'  -> source JSON 已生成: {output_path} ({total} 条目)')
except FileNotFoundError:
    print(f'错误: 找不到文件 {input_path}')
    sys.exit(1)
EOF
            if [ $? -ne 0 ]; then
                echo "错误：srs source JSON 生成失败"
                exit 1
            fi
            # 2. source JSON -> 二进制 srs
            "$SING_BOX_BIN" rule-set compile "$work_dir/${task}.srs.json" -o "$output_dir/${task}.srs"
            if [ $? -ne 0 ]; then
                echo "错误：srs 编译失败"
                exit 1
            fi
            echo "生成文件: ${task}.srs (文件大小: $(du -h "$output_dir/${task}.srs" | awk '{print $1}'))"
        else
            echo "警告: 未知格式 $fmt，跳过。"
        fi
    done
    rm -f "$work_dir/tmp.txt" "$work_dir/${task}.srs.json"
done

echo "---------------------------------------"
echo "所有任务处理完成！"
echo "---------------------------------------"

release_branch=$(yq -r '.git.release_branch' "$config_file")
max_history=$(yq -r '.git.max_history' "$config_file")
echo "开始部署到分支: $release_branch"
# 配置 Git 身份
if [ -n "$GITHUB_TOKEN" ]; then
    git config --global user.name "$(yq -r '.git.user_name' "$config_file")"
    git config --global user.email "$(yq -r '.git.user_email' "$config_file")"
fi
# 这里的逻辑是：不在当前目录下操作，而是克隆一个干净的 release 分支到 temp_repo 目录
temp_repo="$work_dir/temp_repo"
rm -rf "$temp_repo" || true
# 获取当前仓库的远程地址
remote_url=$(git config --get remote.origin.url)
# 克隆 release 分支 (如果不存在则创建空目录)
echo "正在克隆/初始化目标分支..."
if git clone -q --filter=blob:none --branch "$release_branch" "$remote_url" "$temp_repo" 2>/dev/null; then
    echo "成功拉取远程分支 $release_branch"
else
    echo "远程分支不存在，初始化新仓库"
    mkdir -p "$temp_repo"
    cd "$temp_repo"
    git init
    git checkout -b "$release_branch"
    git remote add origin "$remote_url"
    cd - > /dev/null
fi
# 复制生成的文件到 git 目录
# 先删除 git 目录里除了 .git 以外的所有文件，确保删除旧规则
find "$temp_repo" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
cp -r "$output_dir"/* "$temp_repo/"
# 进入 Git 目录进行操作
cd "$temp_repo"
# 检查是否有变化
git add .
if git diff --staged --quiet; then
    echo "规则无变化，跳过提交和推送。"
    exit 0
fi
# 提交
git commit -m "Auto Update: $(date '+%Y-%m-%d %H:%M:%S')"
# 核心逻辑：检查提交数量
commit_count=$(git rev-list --count HEAD)
echo "当前分支提交数量: $commit_count (上限: $max_history)"
if [ "$commit_count" -gt "$max_history" ]; then
    echo "触发历史清理机制..."
    # 逻辑：创建一个新的孤儿分支，包含当前文件的最新状态，然后强制覆盖 release
    # 1. 切换到临时孤儿分支
    git checkout --orphan temp_reset_branch
    # 2. 添加当前所有文件
    git add .
    # 3. 提交
    git commit -m "Reset History: $(date '+%Y-%m-%d') (Cleaned up old commits)"
    # 4. 删除旧的 release 指针
    git branch -D "$release_branch"
    # 5. 重命名当前分支为 release
    git branch -m "$release_branch"
    # 6. 标记需要强制推送
    push_args="--force"
    echo "历史已重置为 1 条提交。"
else
    push_args=""
    echo "历史数量在允许范围内，正常推送。"
fi
# 推送
# 在 GitHub Actions 中，需要使用 Token 进行身份验证
# 我们将 remote url 修改为带 Token 的格式
# 注意：$GITHUB_TOKEN 必须在 workflow 的 env 中传入
if [ -n "$GITHUB_TOKEN" ]; then
    # 替换 origin URL，加入 token
    # 格式: https://x-access-token:TOKEN@github.com/user/repo.git
    # 这里的 sed 会替换 https://github.com... 
    origin_url=$(git remote get-url origin)
    auth_url=$(echo "$origin_url" | sed "s/https:\/\//https:\/\/x-access-token:$GITHUB_TOKEN@/")
    git remote set-url origin "$auth_url"
else
    echo "警告: GITHUB_TOKEN 未设置，推送可能失败！"
fi
echo "正在推送到 GitHub..."
git push $push_args origin "$release_branch"
echo "完成！"