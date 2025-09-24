#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import gzip
import shutil
import subprocess
import sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from zoneinfo import ZoneInfo
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
from pydantic import BaseModel, Field, ValidationError

import yaml
import requests
import click
from loguru import logger # type: ignore

# HTTP 重试依赖导入
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from tenacity import retry, stop_after_attempt, wait_exponential # type: ignore

@dataclass
class SourceConfig:
    """源配置数据类"""
    url: str
    format_override: Optional[str] = None
    processors: Optional[List[str]] = None

@dataclass
class TaskConfig:
    """任务配置数据类"""
    type: str
    format: str
    sources: List[SourceConfig]

# Pydantic 配置模型定义
class BaseConfigModel(BaseModel):
    work_dir: str
    repo_dir: str
    output_dir: str
    max_concurrent_downloads: int = Field(10)
    max_concurrent_tasks: int = Field(3)
    max_retries: int = Field(3)
    request_timeout: int = Field(30)

class MihomoConfigModel(BaseModel):
    api_url: str
    binary_pattern: str
    file_extension: str

class GitConfigModel(BaseModel):
    user_email: str
    user_name: str
    branch: str
    timezone: str

class ConfigModel(BaseModel):
    base: BaseConfigModel
    mihomo: MihomoConfigModel
    git: GitConfigModel
    tasks: Dict[str, TaskConfig]

class TextProcessor:
    """文本处理器类"""
    
    @staticmethod
    def remove_comments_and_empty(text: str) -> str:
        """移除注释和空行"""
        lines = [line for line in text.splitlines() 
                if line.strip() and not line.strip().startswith('#')]
        return "\n".join(lines)
    
    @staticmethod
    def add_prefix_suffix(text: str, prefix: str, suffix: str) -> str:
        """添加前缀和后缀"""
        lines = [f"{prefix}{line}{suffix}" for line in text.splitlines()]
        return "\n".join(lines)
    
    @staticmethod
    def format_pihole(text: str) -> str:
        """格式化为pihole格式"""
        return TextProcessor.add_prefix_suffix(text, "  - '+.", "'")
    
    @staticmethod
    def format_yaml_list(text: str) -> str:
        """格式化为YAML列表格式"""
        return TextProcessor.add_prefix_suffix(text, "  - '", "'")

class RulesetGenerator:
    """规则集生成器主类"""
    
    def __init__(self, config_path: Path):
        # 先加载原始配置
        raw_config = self._load_config(config_path)
        try:
            # 验证并转换配置为字典（使用 model_dump 避免弃用警告）
            self.config = ConfigModel(**raw_config).model_dump()
        except ValidationError as ve:
            logger.error(f"配置验证失败: {ve}")
            sys.exit(1)
        
        self.script_dir = Path(__file__).resolve().parent
        self._setup_paths()
        self._setup_processors()
        
        # 初始化带重试的 HTTP Session
        self.session = requests.Session()
        retry_strategy = Retry(
            total=self.config['base'].get('max_retries', 3),
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
    
    def _load_config(self, config_path: Path) -> dict:
        """加载配置文件"""
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                return yaml.safe_load(f)
        except FileNotFoundError:
            logger.error(f"配置文件不存在: {config_path}")
            sys.exit(1)
        except yaml.YAMLError as e:
            logger.error(f"配置文件格式错误: {e}")
            sys.exit(1)
        except PermissionError:
            logger.error(f"没有权限读取配置文件: {config_path}")
            sys.exit(1)
        except Exception as e:
            logger.error(f"加载配置文件失败: {e}")
            sys.exit(1)
    
    def _setup_paths(self):
        """设置路径"""
        base_config = self.config['base']
        self.work_dir = (self.script_dir / base_config['work_dir']).resolve()
        self.repo_dir = (self.script_dir / base_config['repo_dir']).resolve()
        self.output_dir = (self.script_dir / base_config['output_dir']).resolve()
        
        logger.info(f"工作目录: {self.work_dir}")
        logger.info(f"仓库目录: {self.repo_dir}")
        logger.info(f"输出目录: {self.output_dir}")
    
    def _setup_processors(self):
        """设置处理器映射"""
        self.processors = {
            "remove_comments_and_empty": TextProcessor.remove_comments_and_empty,
            "format_pihole": TextProcessor.format_pihole,
            "format_yaml_list": TextProcessor.format_yaml_list,
        }
    
    def init_env(self):
        """初始化环境"""
        logger.info("正在初始化环境...")
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.work_dir.mkdir(parents=True, exist_ok=True)
        
        mihomo_path = self.work_dir / "mihomo"
        if mihomo_path.exists():
            logger.info("Mihomo 工具已存在，跳过下载")
            return
        
        self._download_mihomo(mihomo_path)
        logger.info("环境初始化完成")
    
    def _download_mihomo(self, mihomo_path: Path):
        """下载Mihomo工具"""
        try:
            mihomo_config = self.config['mihomo']
            response = requests.get(mihomo_config['api_url'], 
                                  timeout=self.config['base']['request_timeout'])
            response.raise_for_status()
            
            releases = response.json()
            download_url = self._find_download_url(releases, mihomo_config)
            
            if not download_url:
                raise ValueError("无法找到Mihomo下载链接")
            
            logger.info(f"从 {download_url} 下载Mihomo...")
            gz_path = self.work_dir / "mihomo.gz"
            
            with requests.get(
                download_url, stream=True, 
                timeout=self.config['base']['request_timeout'] * 2
            ) as r:
                r.raise_for_status()
                with open(gz_path, 'wb') as f:
                    for chunk in r.iter_content(chunk_size=8192):
                        if chunk:  # 过滤保持连接的空块
                            f.write(chunk)
            
            with gzip.open(gz_path, 'rb') as f_in:
                with open(mihomo_path, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)
            
            gz_path.unlink()
            mihomo_path.chmod(0o755)
            
        except requests.exceptions.RequestException as e:
            logger.error(f"下载Mihomo失败，网络错误: {e}")
            sys.exit(1)
        except (OSError, IOError) as e:
            logger.error(f"下载Mihomo失败，文件操作错误: {e}")
            sys.exit(1)
        except Exception as e:
            logger.error(f"下载Mihomo失败: {e}")
            sys.exit(1)
    
    def _find_download_url(self, releases: list, mihomo_config: dict) -> Optional[str]:
        """查找下载链接"""
        for release in releases:
            tag_name = release.get("tag_name", "")
            if "Prerelease-Alpha" not in tag_name:
                continue
                
            for asset in release.get("assets", []):
                asset_name = asset.get("name", "")
                if (mihomo_config['binary_pattern'] in asset_name and 
                    asset_name.endswith(mihomo_config['file_extension'])):
                    return asset.get("browser_download_url")
        
        return None
    
    @retry(
        stop=stop_after_attempt(3), 
        wait=wait_exponential(multiplier=1, max=10)
    )
    def _download_and_process_source(
        self, source: SourceConfig, index: int
    ) -> Tuple[int, str]:
        """下载并处理单个源，失败时重试"""
        try:
            logger.info(f"下载源 #{index}: {source.url}")
            response = self.session.get(
                source.url,
                timeout=self.config['base']['request_timeout']
            )
            response.raise_for_status()
            content = response.text
            
            # 应用处理器
            processors = source.processors or ["remove_comments_and_empty"]
            for processor_name in processors:
                if processor_name in self.processors:
                    content = self.processors[processor_name](content)
                else:
                    logger.warning(f"未知的处理器: {processor_name}")
            
            # 确保以换行结束
            if content and not content.endswith('\n'):
                content += '\n'
            
            file_size = len(content.encode('utf-8'))
            logger.debug(f"处理后内容大小: {file_size} 字节")
            
            if file_size == 0:
                logger.warning(f"从 {source.url} 获取的内容为空")
            
            return index, content
            
        except requests.exceptions.Timeout:
            logger.warning(f"下载超时: {source.url}")
            raise
        except requests.exceptions.RequestException as e:
            logger.warning(f"下载失败: {source.url}, 网络错误: {e}")
            raise
        except Exception as e:
            logger.warning(f"处理源 {source.url} 时出错: {e}")
            return index, ""
    
    def process_task(self, name: str, task_config: TaskConfig) -> Optional[List[Path]]:
        """处理单个任务"""
        logger.info(f"处理 {name} 规则集...")
        
        # 并行下载和处理源
        sources = [SourceConfig(**src) if isinstance(src, dict) else src 
                  for src in task_config.sources]
        
        results = {}
        max_workers = self.config['base']['max_concurrent_downloads']
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(self._download_and_process_source, src, i): i 
                      for i, src in enumerate(sources)}
            
            for future in as_completed(futures):
                index, content = future.result()
                results[index] = content
        
        # 合并内容，过滤空内容
        combined_content = "".join(
            results[i] 
            for i in sorted(results.keys()) 
            if results[i].strip()
        )
        
        # 处理文件格式
        temp_source_path = self.work_dir / f"{name}.{task_config.format}"
        final_source_path = self.output_dir / f"{name}.{task_config.format}"
        final_mrs_path = self.output_dir / f"{name}.mrs"
        
        self._write_processed_content(
            combined_content, temp_source_path, task_config.format
        )
        
        # 转换为MRS格式
        if self._convert_to_mrs(
            name, task_config.type, task_config.format, 
            temp_source_path, final_source_path, final_mrs_path
        ):
            logger.info(f"{name} 规则集处理完成")
            return [final_source_path, final_mrs_path]
        
        return None
    
    def _write_processed_content(self, content: str, temp_path: Path, format_type: str):
        """写入处理后的内容"""
        if not content.strip():
            raise ValueError("内容为空")
        
        lines = content.splitlines()
        
        if format_type == "yaml":
            if not lines:
                raise ValueError("YAML内容不能为空")
            header = lines[0]
            unique_lines = sorted(
                set(line for line in lines[1:] if line.strip())
            )
            final_content = f"{header}\n" + "\n".join(unique_lines)
        else:
            unique_lines = sorted(
                set(line for line in lines if line.strip())
            )
            final_content = "\n".join(unique_lines)
        
        # 原子写入，避免写入过程中的文件损坏
        temp_file = temp_path.with_suffix(temp_path.suffix + '.tmp')
        try:
            temp_file.write_text(final_content, encoding='utf-8')
            temp_file.replace(temp_path)
        except Exception:
            if temp_file.exists():
                temp_file.unlink()
            raise
    
    def _convert_to_mrs(
        self, name: str, rule_type: str, format_type: str,
        temp_path: Path, final_source_path: Path, final_mrs_path: Path
    ) -> bool:
        """转换为MRS格式"""
        try:
            mihomo_executable = self.work_dir / "mihomo"
            if not mihomo_executable.exists():
                logger.error("Mihomo工具不存在")
                return False
                
            temp_mrs_path = self.work_dir / f"{name}.mrs"
            
            logger.debug(f"转换 {temp_path} 到MRS格式...")
            
            cmd = [
                str(mihomo_executable), "convert-ruleset", rule_type, 
                format_type, str(temp_path), str(temp_mrs_path)
            ]
            
            result = subprocess.run(cmd, check=True, capture_output=True, text=True)
            logger.debug(f"转换成功: {result.stdout}")
            
            # 验证输出文件
            if (not temp_mrs_path.exists() or 
                temp_mrs_path.stat().st_size == 0):
                logger.error("转换后的MRS文件不存在或为空")
                return False
            
            shutil.move(str(temp_path), str(final_source_path))
            shutil.move(str(temp_mrs_path), str(final_mrs_path))
            
            return True
            
        except subprocess.CalledProcessError as e:
            logger.error(f"Mihomo转换失败: {e.stderr}")
            return False
        except (OSError, IOError) as e:
            logger.error(f"文件操作错误: {e}")
            return False
        except Exception as e:
            logger.error(f"转换过程中发生错误: {e}")
            return False
    
    def commit_changes(self):
        """提交更改到Git"""
        if not shutil.which("git"):
            logger.error("未找到git命令")
            return
        
        try:
            git_config = self.config['git']
            base_config = self.config['base']
            tz = ZoneInfo(git_config['timezone'])
            commit_time = datetime.now(tz).strftime('%Y-%m-%d %H:%M:%S')
            commit_message = f"{commit_time} 更新mrs规则"
            
            commands = [
                ["git", "config", "--local", "user.email", 
                 git_config['user_email']],
                ["git", "config", "--local", "user.name", 
                 git_config['user_name']],
                ["git", "pull", "origin", git_config['branch']],
                ["git", "add", f"{base_config['output_dir']}/*"],
            ]
            
            for cmd in commands:
                result = subprocess.run(
                    cmd, cwd=self.repo_dir, check=True, 
                    capture_output=True, text=True
                )
                logger.debug(f"Git命令执行成功: {' '.join(cmd)}")
            
            result = subprocess.run(
                ["git", "commit", "-m", commit_message], 
                cwd=self.repo_dir, capture_output=True, text=True
            )
            
            if result.returncode != 0:
                if "nothing to commit" in result.stdout:
                    logger.info("没有需要提交的更改")
                else:
                    logger.error(f"Git commit失败: {result.stderr}")
            else:
                logger.info("提交完成")
                
        except subprocess.CalledProcessError as e:
            logger.error(f"Git命令执行失败: {e.stderr}")
        except Exception as e:
            logger.error(f"提交时发生错误: {e}")
    
    def run(self):
        """运行主流程"""
        self.init_env()
        
        tasks = self.config['tasks']
        all_generated_files = []
        max_workers = self.config['base']['max_concurrent_tasks']
        
        # 并行处理任务
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            task_configs = {
                name: TaskConfig(**config) 
                for name, config in tasks.items()
            }
            futures = {
                executor.submit(self.process_task, name, config): name 
                for name, config in task_configs.items()
            }
            
            for future in as_completed(futures):
                task_name = futures[future]
                generated_files = future.result()
                if generated_files:
                    all_generated_files.extend(generated_files)
                else:
                    logger.warning(
                        f"任务 {task_name} 未能成功生成文件"
                    )
        
        # 文件检查
        if self._validate_generated_files(all_generated_files):
            logger.info("所有文件均已正确生成")
            self.commit_changes()
        else:
            logger.error("文件检查失败，跳过Git提交")
            sys.exit(1)
        
        logger.info("所有操作已完成，喵~")
    
    def _validate_generated_files(self, files: List[Path]) -> bool:
        """验证生成的文件"""
        if not files:
            logger.error("没有任何文件被生成")
            return False
        
        all_ok = True
        for file_path in files:
            if file_path.exists() and file_path.stat().st_size > 0:
                file_size = file_path.stat().st_size
                logger.info(
                    f"✅ 文件检查成功: {file_path} (大小: {file_size} 字节)"
                )
            else:
                logger.error(
                    f"❌ 文件检查失败: {file_path} 不存在或为空"
                )
                all_ok = False
        
        return all_ok

@click.command()
@click.option('--config', '-c', 
              default='config.yaml',
              help='配置文件路径',
              type=click.Path())  # 移除exists=True检查，允许在运行时检查
@click.option('--log-level', '-l',
              default='INFO',
              help='日志级别',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR']))
def main(config, log_level):
    """MRS规则集生成器"""
    # 配置日志
    logger.remove()
    logger.add(
        sys.stdout, level=log_level, 
        format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | "
               "<level>{level: <8}</level> | <cyan>{name}</cyan>:"
               "<cyan>{function}</cyan>:<cyan>{line}</cyan> - "
               "<level>{message}</level>"
    )
    
    config_path = Path(config)
    if not config_path.is_absolute():
        config_path = Path(__file__).parent / config_path
    
    # 检查配置文件是否存在
    if not config_path.exists():
        logger.error(f"配置文件不存在: {config_path}")
        sys.exit(1)
    
    generator = RulesetGenerator(config_path)
    generator.run()

if __name__ == "__main__":
    main()