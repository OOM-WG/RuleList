#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
简单的代码风格检查脚本
"""

import ast
import sys
from pathlib import Path
from typing import List, Tuple


class CodeStyleChecker:
    """代码风格检查器"""
    
    def __init__(self, file_path: Path):
        self.file_path = file_path
        self.issues = []
    
    def check_line_length(self, max_length: int = 88) -> List[Tuple[int, str]]:
        """检查行长度"""
        issues = []
        with open(self.file_path, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                if len(line.rstrip()) > max_length:
                    issues.append((line_num, f"行长度超过 {max_length} 字符: {len(line.rstrip())}"))
        return issues
    
    def check_imports(self) -> List[Tuple[int, str]]:
        """检查导入顺序"""
        issues = []
        with open(self.file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        try:
            tree = ast.parse(content)
            imports = []
            
            for node in ast.walk(tree):
                if isinstance(node, (ast.Import, ast.ImportFrom)):
                    imports.append((node.lineno, node))
            
            # 简单检查：标准库导入应该在第三方库之前
            stdlib_imports = ['sys', 'os', 'pathlib', 'subprocess', 'gzip', 'shutil', 
                            'datetime', 'concurrent', 'typing', 'dataclasses', 'zoneinfo']
            
            found_third_party = False
            for line_num, node in imports:
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        if alias.name not in stdlib_imports and not found_third_party:
                            found_third_party = True
                        elif alias.name in stdlib_imports and found_third_party:
                            issues.append((line_num, f"标准库导入 {alias.name} 应该在第三方库之前"))
                            
        except SyntaxError:
            issues.append((1, "语法错误，无法检查导入"))
            
        return issues
    
    def run_all_checks(self) -> List[Tuple[int, str]]:
        """运行所有检查"""
        all_issues = []
        all_issues.extend(self.check_line_length())
        all_issues.extend(self.check_imports())
        return sorted(all_issues)


def main():
    """主函数"""
    checker = CodeStyleChecker(Path("start.py"))
    issues = checker.run_all_checks()
    
    if issues:
        print("发现以下代码风格问题：")
        for line_num, issue in issues:
            print(f"行 {line_num}: {issue}")
    else:
        print("✅ 代码风格检查通过！")
    
    return len(issues)


if __name__ == "__main__":
    sys.exit(main())