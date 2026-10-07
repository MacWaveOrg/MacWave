#!/usr/bin/env python3
"""
MacWave
A package manager for macOS/Linux jailbreak developers.
Version: 1.1.0
"""

import argparse
import json
import os
import sys
import platform
import time
import fcntl
import logging
import traceback
import shutil
import subprocess
import re
from pathlib import Path
from typing import Optional, Dict, Any, Union

# ==========================================
# 依赖库检查
# ==========================================

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
    from urllib3.exceptions import InsecureRequestWarning
    import urllib3
except ImportError:
    print("🌊 Error: 'requests' library is not installed.")
    print("🌊 Please install it using: pip3 install requests")
    sys.exit(1)

try:
    from packaging.version import parse as parse_version, InvalidVersion
except ImportError:
    print("🌊 Error: 'packaging' library is not installed.")
    print("🌊 Please install it using: pip3 install packaging")
    sys.exit(1)

try:
    from rich.console import Console
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False


# ==========================================
# 全局常量
# ==========================================

VERSION = "1.1.0"
REPO_URL = "https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/repo/repo.json"
INSTALL_DIR = Path.home() / ".local" / "macwave" / "bin"
DOWNLOAD_TMP = Path.home() / ".local" / "macwave" / "downloads" / "tmp"
INSTALLED_DB = Path.home() / ".local" / "macwave" / "installed.json"
REPO_CACHE = Path.home() / ".local" / "macwave" / "repo_cache.json"
PROTECTED_PACKAGES = ["wave"]


# ==========================================
# 核心类
# ==========================================

class MacWaveCLI:
    def __init__(self):
        self.parser = self._create_parser()
        self.verbose = False
        self._logger = logging.getLogger("MacWave")
        if not self._logger.handlers:
            handler = logging.StreamHandler()
            handler.setFormatter(logging.Formatter('%(message)s'))
            self._logger.addHandler(handler)
            self._logger.setLevel(logging.INFO)

    def _create_parser(self):
        parser = argparse.ArgumentParser(
            prog="wave",
            description="MacWave 1.1.0\nA package manager for macOS/Linux jailbreak developers.",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            usage="wave <command> [package] [flags]",
            epilog="For more details, visit: https://macwave.org",
            add_help=False
        )

        parser.add_argument('-h', '--help', action='store_true', help='show this help message and exit')
        parser.add_argument('-V', '--version', action='version', version=f'MacWave {VERSION} 🌊')
        parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
        parser.add_argument('-B', '--beta-version', action='store_true', help='Install the latest beta version')
        parser.add_argument('--proxy', type=str, metavar='string', help='Specify an HTTP/HTTPS proxy')
        parser.add_argument('--skip-ssl', action='store_true', help='Skip SSL certificate verification')
        parser.add_argument('--limit-rate', type=str, metavar='string', help='Limit download speed (e.g., 200K, 1M, 5M)')
        parser.add_argument('--dry-run', action='store_true', help='Simulate the installation')
        parser.add_argument('--json', action='store_true', help='Output in JSON format')

        subparsers = parser.add_subparsers(dest="command", metavar="{install,uninstall,list,search,info,update,upgrade,doctor,clean}", help="Commands")

        install_parser = subparsers.add_parser("install", help="Install a package", usage="wave install <package_name> [flags]")
        install_parser.add_argument("package_name", help="Name of the package to install")
        self._add_install_flags(install_parser)

        uninstall_parser = subparsers.add_parser("uninstall", help="Uninstall a package", usage="wave uninstall <package_name>")
        uninstall_parser.add_argument("package_name", help="Name of the package to uninstall")

        subparsers.add_parser("list", help="List installed packages")

        search_parser = subparsers.add_parser("search", help="Search for a package", usage="wave search <query> [flags]")
        search_parser.add_argument("query", help="Search query")
        search_parser.add_argument('-f', '--fuzzy', action='store_true', help='Enable fuzzy search')

        info_parser = subparsers.add_parser("info", help="Display detailed information", usage="wave info <package_name>")
        info_parser.add_argument("package_name", help="Name of the package")

        subparsers.add_parser("update", help="Update the package index")

        upgrade_parser = subparsers.add_parser("upgrade", help="Upgrade an installed package", usage="wave upgrade <package_name>")
        upgrade_parser.add_argument("package_name", help="Name of the package to upgrade")

        subparsers.add_parser("doctor", help="Check your system for missing dependencies")
        subparsers.add_parser("clean", help="Clean up temporary download files")

        return parser

    def _add_install_flags(self, parser):
        parser.add_argument('-D', '--dir', type=str, metavar='string', help='Specify an output directory')
        parser.add_argument('--ver', type=str, metavar='string', help='Install a specific version')
        parser.add_argument('-C', '--continue', dest='resume', action='store_true', help='Resume interrupted downloads')

    def _print_custom_help(self):
        print("\033[35musage: \033[38;5;197mwave <command> [package] [flags]\033[0m")
        print()
        print("MacWave 1.1.0 🌊")
        print("A package manager for macOS/Linux jailbreak developers.")
        print()
        print("\033[35mpositional arguments:\033[0m")
        print("  \033[32m{install, uninstall, list, search, info, update, upgrade, doctor, clean}\033[0m")
        print("                          \033[0mCommands\033[0m")
        print("    \033[32minstall\033[0m               Install a package")
        print("    \033[32muninstall\033[0m             Uninstall a package")
        print("    \033[32mlist\033[0m                  List installed packages")
        print("    \033[32msearch\033[0m                Search for a package in the index")
        print("    \033[32minfo\033[0m                  Display detailed information about a package")
        print("    \033[32mupdate\033[0m                Update the package index")
        print("    \033[32mupgrade\033[0m               Upgrade an installed package to the latest version")
        print("    \033[32mdoctor\033[0m                Check your system for missing dependencies")
        print("    \033[32mclean\033[0m                 Clean up temporary download files")
        print()
        print("\033[35mparameters:\033[0m")
        print("  \033[32m-h, --help\033[0m              show this help message and exit")
        print("  \033[32m-V, --version\033[0m           show program's version number and exit")
        print("  \033[32m-v, --verbose\033[0m           Enable verbose output")
        print("  \033[32m-B, --beta-version\033[0m      Install the latest beta version")
        print("  \033[36m--proxy\033[0m \033[33mstring\033[0m          Specify an HTTP/HTTPS proxy")
        print("  \033[36m--skip-ssl\033[0m              Skip SSL certificate verification")
        print("  \033[36m--limit-rate\033[0m \033[33mstring\033[0m     Limit download speed")
        print("  \033[36m--dry-run\033[0m               Simulate the installation")
        print("  \033[36m--json\033[0m                  Output in JSON format")
        print()
        print("Global Flags:")
        print("  \033[32m-B, --beta-version\033[0m      Install the latest beta version")
        print("  \033[32m-D, --dir\033[0m \033[33mstring\033[0m        Specify an output directory")
        print("  \033[32m-C, --continue\033[0m          Resume interrupted downloads")
        print("  \033[36m--proxy\033[0m \033[33mstring\033[0m          Specify an HTTP/HTTPS proxy")
        print("  \033[36m--skip-ssl\033[0m              Skip SSL certificate verification")
        print("  \033[36m--limit-rate\033[0m \033[33mstring\033[0m     Limit download speed")
        print("  \033[36m--dry-run\033[0m               Simulate the installation")
        print("  \033[36m--json\033[0m                  Output in JSON format")
        print("  \033[36m--ver\033[0m \033[33mstring\033[0m            Install a specific version")
        print()
        print("For more details, visit: https://macwave.org")

    def _log(self, message: str, level: str = "info", force: bool = False):
        if self.verbose or force or level == "error":
            log_level = getattr(logging, level.upper(), logging.INFO)
            self._logger.log(log_level, f"🌊 {message}")

    def log(self, message, force=False):
        self._log(message, "info", force)

    def log_verbose(self, message):
        if self.verbose:
            self._log(message, "debug")

    def _is_protected(self, package_name: str) -> bool:
        return package_name.lower() in PROTECTED_PACKAGES

    def _confirm_action(self, message: str) -> bool:
        response = input(f"🌊 {message} [Y/n] ").strip()
        return response == 'Y' or response == 'y'

    def _confirm_skip_ssl(self, args) -> bool:
        skip_ssl = getattr(args, 'skip_ssl', False)
        if not skip_ssl:
            return True

        console = Console()
        console.print("🌊 --skip-ssl parameter will skip SSL certificate verification, it is insecure. Are you sure to continue?", style="bold red")
        if self._confirm_action(""):
            console.print("🌊 Install continue", style="bold red")
            return True
        else:
            console.print("🌊 Install stopped", style="bold green")
            return False

    def fetch_repo_data(self, args=None):
        REPO_CACHE.parent.mkdir(parents=True, exist_ok=True)
        cache_data = None
        cache_age = None

        if REPO_CACHE.exists():
            try:
                with open(REPO_CACHE, 'r') as f:
                    cache_data = json.load(f)
                cache_age = time.time() - REPO_CACHE.stat().st_mtime
            except (json.JSONDecodeError, OSError):
                cache_data = None

        if cache_data is not None and cache_age is not None and cache_age < 300:
            return cache_data

        session = requests.Session()
        session.headers.update({'User-Agent': 'MacWave/1.1.0'})
        retries = Retry(total=3, backoff_factor=0.5, status_forcelist=[429, 500, 502, 503, 504], allowed_methods=["GET"])
        session.mount('https://', HTTPAdapter(max_retries=retries))

        request_kwargs = {'timeout': 30}

        if args and getattr(args, 'proxy', None):
            proxy = args.proxy
            if proxy.startswith(('http://', 'https://')):
                request_kwargs['proxies'] = {'http': proxy, 'https': proxy}

        if args and getattr(args, 'skip_ssl', False):
            request_kwargs['verify'] = False
            urllib3.disable_warnings(InsecureRequestWarning)

        try:
            response = session.get(REPO_URL, **request_kwargs)
            response.raise_for_status()
            data = response.json()
            with open(REPO_CACHE, 'w') as f:
                json.dump(data, f, indent=2)
            return data
        except requests.exceptions.RequestException as e:
            if cache_data is not None and cache_age is not None and cache_age < 3600:
                return cache_data
            raise RuntimeError(f"Failed to fetch repository data after retries: {e}") from e
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Invalid JSON data received from repository: {e}") from e

    def find_package(self, repo_data, package_name, args=None):
        self.log_verbose(f"Searching for package: {package_name}")
        all_releases = []

        if "packages" in repo_data:
            for pkg in repo_data["packages"]:
                if pkg.get("name") == package_name:
                    releases = pkg.get("releases", [])
                    for release in releases:
                        release = release.copy()
                        if "version" not in release and "version" in pkg:
                            release["version"] = pkg["version"]
                        if "binary_url" not in release:
                            continue
                        all_releases.append(release)

        if not all_releases:
            print(f"🌊 Error: Package '{package_name}' not found in repository")
            sys.exit(1)

        if args and getattr(args, 'ver', None):
            requested_version = args.ver
            for release in all_releases:
                if release.get("version") == requested_version:
                    arch = platform.machine().lower()
                    if release.get("arch") == arch or release.get("arch") == "any":
                        return release
            print(f"🌊 Error: Could not find version '{requested_version}' for package '{package_name}'.")
            sys.exit(1)

        if args and getattr(args, 'beta_version', False):
            for release in all_releases:
                if release.get("arch") == "beta":
                    return release
            print(f"🌊 No beta version found for '{package_name}'.")
            return None

        current_arch = platform.machine().lower()
        matching_releases = []

        for release in all_releases:
            arch = release.get("arch")
            if arch == current_arch or arch == "any":
                matching_releases.append(release)

        if not matching_releases:
            print(f"🌊 Error: No release found for architecture '{current_arch}' or 'any' for package '{package_name}'")
            sys.exit(1)


        def safe_parse_version(v):
            v = str(v)
            # 标准版本号解析
            try:
                return parse_version(v)
            except InvalidVersion:
                pass

              
        # ============================== 临时补丁开始 ==============================
            
        # 临时补丁，为避免packaging解析非标准版本号崩溃
        # 作者在2026年8月14日添加此补丁，旨在解决ldid版本号2.1.5-procursus7可能带来的问题
        # 作者在2026年8月15日修改此补丁，旨在解决加入ldid版本2.1.5-procursus、2.1.5-procursus1、…、2.1.5-procursus6带来的问题
        # 额外补充：支持procursus数字后缀排序

        # ---------- 废弃版本（2026年8月14日第一版）开始 ----------
        # 注：在2026年8月5日，v1.0.0-beta3（8月5日）开始引入并支持ldid软件包，此时还没有下方补丁，且仅有2.1.5-procursus7一个版本
        # 但直到v1.0.0-rc（8月14日）发现由于不符合PEP 440标准，有时会崩溃
        # 所以在v1.0.0-rc2（8月14日）引入下方补丁，最后一个采用此代码的版本为v1.0.0-rc3
        # 1.0.0-rc4起，由于下方代码会把2.1.5-procursusX统一视为2.1.5，但后来需要引入2.1.5-procursus、2.1.5-procursus1、…、2.1.5-procursus7
        # 所以作者废弃下列补丁，修改了正则表达式，以正确识别和排列2.1.5-procursus、2.1.5-procursus1、…、2.1.5-procursus7版本
        # 修改后的补丁详见对应位置注释
        # ！！！⚠️⚠️⚠️ 禁止删除此段注释 ⚠️⚠️⚠️！！！
        # def safe_parse_version(v):
        #     v = str(v)
        #     match = re.search(r'(\d+\.\d+\.\d+)', v)
        #     if match:
        #         try:
        #             return parse_version(match.group(1))
        #         except InvalidVersion:
        #             pass
        #     logging.warning(f"Invalid version string '{v}', falling back to 0.0.0")
        #     return parse_version("0.0.0")
        # ---------- 废弃版本（2026年8月14日第一版）结束 ----------
            
            # 非标准版本号解析（新版补丁）
            base_match = re.search(r'(\d+\.\d+\.\d+)', v)
            if base_match:
                base_version = base_match.group(1)
                proc_match = re.search(r'procursus(\d+)', v)
                suffix_num = int(proc_match.group(1)) if proc_match else 0
                # 把版本号转为 (主版本, 次版本, 补丁, 后缀编号) 的元组进行比较
                # 由于 parse_version 没法直接比较元组，作者使用"基础版本号"+"后缀编号"拼接为一个新的版本号字符串，以保证排序正确
                # 策略：拼接成 "基础版本号.后缀编号"，例如 2.1.5.7 表示 2.1.5-procursus7，2.1.5.0表示2.1.5-procursus
                return parse_version(f"{base_version}.{suffix_num}")

            logging.warning(f"Invalid version string '{v}', falling back to 0.0.0")
            return parse_version("0.0.0")
            
        # ============================== 临时补丁结束 ==============================
        
        matching_releases.sort(key=lambda r: safe_parse_version(r.get("version", "0.0.0")), reverse=True)
        return matching_releases[0]

    def _call_installer(self, command, package_name, args, release, version, install_dir, final_path):
        cmd = [
            'python3', 'packageinstaller.py',
            '--command', command,
            '--package', package_name,
            '--version', version,
            '--url', release.get('binary_url', ''),
            '--sha256', release.get('sha256', ''),
            '--dir', str(install_dir),
            '--final-path', str(final_path)
        ]
        if args.verbose:
            cmd.append('--verbose')
        if args.proxy:
            cmd.extend(['--proxy', args.proxy])
        if args.skip_ssl:
            cmd.append('--skip-ssl')
        if args.limit_rate:
            cmd.extend(['--limit-rate', args.limit_rate])
        if args.resume:
            cmd.append('--resume')
        if args.dry_run:
            cmd.append('--dry-run')

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stderr)
            sys.exit(result.returncode)
        print(result.stdout.strip())

    def handle_install(self, args):
        if args.json:
            print(json.dumps({"command": "install", "package": args.package_name}))
            return

        # ========== 多版本语法支持 ==========
        # 支持 ldid@2.1.5-procursus7 格式
        # 如果用户使用 @ 语法，自动拆分为包名和版本号
        package_name = args.package_name
        if '@' in package_name:
            pkg_name, ver = package_name.split('@', 1)
            args.package_name = pkg_name
            args.ver = ver
        # ======================================

        try:
            repo_data = self.fetch_repo_data(args)
        except RuntimeError as e:
            print(f"🌊 {e}")
            sys.exit(1)

        safe_name = args.package_name.lower()
        install_dir = INSTALL_DIR
        if args.dir:
            install_dir = Path(args.dir).expanduser().resolve()

        # 获取要安装的版本
        if args.ver:
            release = self.find_package(repo_data, safe_name, args)
            version = release.get("version")
        elif args.beta_version:
            beta_release = self.find_package(repo_data, safe_name, args)
            if not beta_release:
                print(f"🌊 No beta version found for '{safe_name}'.")
                if self._confirm_action("Do you want to install the latest stable version instead?"):
                    release = self.find_package(repo_data, safe_name, args)
                    version = release.get("version")
                else:
                    print("🌊 Installation cancelled.")
                    return
            else:
                release = beta_release
                version = release.get("version")
        else:
            release = self.find_package(repo_data, safe_name, args)
            version = release.get("version")

        if not version:
            final_path = install_dir / safe_name
        else:
            final_path = install_dir / f"{safe_name}@{version}"

        # ========== 智能已安装检查 ==========
        # 扫描 bin 目录下所有该包的文件（排除 .bak）
        existing_versions = []
        for f in install_dir.glob(f"{safe_name}@*"):
            if f.name.endswith('.bak'):
                continue
            ver = f.name.split('@', 1)[1]
            existing_versions.append(ver)

        if existing_versions:
            if version in existing_versions:
                # 要安装的版本已存在
                print(f"🌊 \033[93mVersion {version} of '{safe_name}' is already installed.\033[0m")
                print(f"🌊 \033[93mDo you want to reinstall it? [Y/n]:\033[0m")
                if not self._confirm_action(""):
                    print(f"🌊 \033[32mInstallation cancelled. Existing '{safe_name}@{version}' preserved.\033[0m")
                    return
            else:
                # 已有其他版本，安装的是新版本
                print(f"🌊 \033[93mExisting version(s) of '{safe_name}' found:\033[0m")
                for v in existing_versions:
                    print(f"🌊 \033[93m  - {safe_name}@{v}\033[0m")
                print(f"🌊 \033[93mDo you want to install the latest version ({version})?\033[0m")
                print(f"🌊 \033[93mContinue installation will NOT delete existing versions [Y/n]:\033[0m")
                if not self._confirm_action(""):
                    print(f"🌊 \033[32mInstallation cancelled.\033[0m")
                    return
        # ======================================

        self._call_installer(
            command='install',
            package_name=safe_name,
            args=args,
            release=release,
            version=version,
            install_dir=install_dir,
            final_path=final_path
        )

    def handle_uninstall(self, args):
        package_spec = args.package_name

        self._call_installer(
            command='uninstall',
            package_name=package_spec,
            args=args,
            release=None,
            version=None,
            install_dir=INSTALL_DIR,
            final_path=None
        )

    def handle_list(self, args):
        INSTALLED_DB.parent.mkdir(parents=True, exist_ok=True)
        if not INSTALLED_DB.exists():
            print("🌊 No packages installed yet.")
            return
        try:
            with open(INSTALLED_DB, 'r') as f:
                installed = json.load(f)
            print("🌊 Installed packages:")
            for pkg_name, info in installed.items():
                version = info.get('version', 'unknown')
                binary_path = info.get('binary_path', 'unknown')
                print(f"🌊   - {pkg_name} (v{version}) -> {binary_path}")
        except Exception as e:
            print(f"🌊 Error: Could not read installed packages: {e}")

    def handle_search(self, args):
        query = args.query.lower()
        try:
            repo_data = self.fetch_repo_data(args)
        except RuntimeError as e:
            print(f"🌊 {e}")
            sys.exit(1)

        matches = []
        if "packages" in repo_data:
            for pkg in repo_data["packages"]:
                name = pkg.get("name", "").lower()
                desc = pkg.get("description", "").lower()
                if args.fuzzy:
                    if query in name or query in desc:
                        matches.append(pkg)
                else:
                    if name.startswith(query) or desc.startswith(query):
                        matches.append(pkg)

        if not matches:
            print(f"🌊 No packages found matching '{args.query}'")
            return

        print(f"🌊 Found {len(matches)} package(s) matching '{args.query}':")
        for pkg in matches:
            name = pkg.get("name", "Unknown")
            desc = pkg.get("description", "No description")
            print(f"🌊   - {name}: {desc}")

    def handle_info(self, args):
        try:
            repo_data = self.fetch_repo_data(args)
        except RuntimeError as e:
            print(f"🌊 {e}")
            sys.exit(1)

        safe_name = args.package_name.lower()
        versions = []
        package_info = None
        homepage = None

        if "packages" in repo_data:
            for pkg in repo_data["packages"]:
                if pkg.get("name") == safe_name:
                    if package_info is None:
                        package_info = pkg.copy()
                    # 改为从 releases 数组里收集版本号
                    for release in pkg.get("releases", []):
                        ver = release.get("version")
                        if ver and ver not in versions:
                            versions.append(ver)
                    if "homepage" in pkg and homepage is None:
                        homepage = pkg["homepage"]

        if not package_info:
            print(f"🌊 Error: Package '{safe_name}' not found in repository")
            sys.exit(1)

        try:
            versions.sort(key=parse_version, reverse=True)
        except:
            versions.sort(reverse=True)

        # ========== 多版本垂直对齐 ==========
        # 把所有的常规字段用统一格式打印（手动补齐15个空格保证冒号对齐）
        print(f"🌊 Name:               {package_info.get('name', 'Unknown')}")
        print(f"🌊 Author:             {package_info.get('author', 'Unknown')}")
        print(f"🌊 Description:        {package_info.get('description', 'No description')}")
        if homepage:
            print(f"🌊 Homepage:           {homepage}")

        # ========== 扫描已安装版本 ==========
        installed_versions = []
        install_dir = INSTALL_DIR
        for f in install_dir.glob(f"{safe_name}@*"):
            if f.name.endswith('.bak'):
                continue
            ver = f.name.split('@', 1)[1]
            installed_versions.append(ver)

        if installed_versions:
            try:
                installed_versions.sort(key=parse_version, reverse=True)
            except:
                installed_versions.sort(reverse=True)
            print(f"🌊 Installed versions:")
            for ver in installed_versions:
                print(f"🌊   - {ver}")
        else:
            print(f"🌊 Installed versions: None")
        # ====================================

        # ========== 多版本垂直对齐（仅第一行带 🌊） ==========
        if versions:
            print(f"🌊 Available versions: {versions[0]}")
            for ver in versions[1:]:
                print(f"                       {ver}")
        # ====================================================
    
    def handle_update(self, args):
        print("🌊 Forcing update: fetching fresh package index...")
        try:
            if REPO_CACHE.exists():
                REPO_CACHE.unlink()
            repo_data = self.fetch_repo_data(args)
            print(f"🌊 Package index updated successfully. Found {len(repo_data.get('packages', []))} packages.")
        except RuntimeError as e:
            print(f"🌊 {e}")
            sys.exit(1)
        except Exception as e:
            print(f"🌊 Error: Failed to update package index: {e}")

    def handle_upgrade(self, args):
        safe_name = args.package_name.lower()

        if self._is_protected(safe_name):
            print(f"🌊 \033[31mERROR: Cannot upgrade protected package: {safe_name}\033[0m")
            print(f"🌊 \033[93mTo update MacWave, download the new version manually:\033[0m")
            print(f"🌊 \033[93m  curl -fsSL -o ~/.local/macwave/bin/wave https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/wave.py\033[0m")
            return

        INSTALLED_DB.parent.mkdir(parents=True, exist_ok=True)
        if not INSTALLED_DB.exists():
            print(f"🌊 Package '{safe_name}' is not installed. Nothing to upgrade.")
            return

        try:
            with open(INSTALLED_DB, 'r') as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_SH)
                installed = json.load(f)

            if safe_name not in installed:
                print(f"🌊 Package '{safe_name}' is not installed. Nothing to upgrade.")
                return

            local_version = installed[safe_name].get('version', '0.0.0')
            if local_version is None:
                local_version = '0.0.0'

            try:
                repo_data = self.fetch_repo_data(args)
            except RuntimeError as e:
                print(f"🌊 {e}")
                sys.exit(1)

            release = self.find_package(repo_data, safe_name, args)
            remote_version = release.get("version", "unknown")

            try:
                local_v = parse_version(local_version)
                remote_v = parse_version(remote_version)
                if local_v >= remote_v:
                    print(f"🌊 Package '{safe_name}' is already up to date (v{local_version}).")
                    return
            except InvalidVersion:
                if local_version >= remote_version:
                    print(f"🌊 Package '{safe_name}' is already up to date (v{local_version}).")
                    return

            print(f"🌊 Upgrading '{safe_name}' from v{local_version} to v{remote_version}...")

            # 调用 packageinstaller 执行升级（删除旧版本后安装新版本）
            binary_path = Path(installed[safe_name].get('binary_path', str(INSTALL_DIR / safe_name)))
            if binary_path.exists():
                # 调用 uninstall 删除旧版本
                self._call_installer(
                    command='uninstall',
                    package_name=safe_name,
                    args=args,
                    release=None,
                    version=None,
                    install_dir=INSTALL_DIR,
                    final_path=None
                )

            version = release.get("version")
            if version:
                final_path = INSTALL_DIR / f"{safe_name}@{version}"
            else:
                final_path = INSTALL_DIR / safe_name

            self._call_installer(
                command='install',
                package_name=safe_name,
                args=args,
                release=release,
                version=version,
                install_dir=INSTALL_DIR,
                final_path=final_path
            )

        except Exception as e:
            print(f"🌊 Error: Failed to upgrade package: {e}")

    def handle_doctor(self, args):
        print("🌊 Running system diagnostics...")
        missing = []
        for cmd in ['curl', 'wget', 'git', 'python3']:
            if shutil.which(cmd) is None:
                missing.append(cmd)

        if missing:
            print(f"🌊 \033[31mMissing dependencies: {', '.join(missing)}\033[0m")
            print("🌊 Please install the missing software packages manually.")
            sys.exit(1)
        else:
            print("🌊 \033[32mAll required dependencies are present.\033[0m")
            print("🌊 System is healthy.")

    def handle_clean(self, args):
        if DOWNLOAD_TMP.exists():
            shutil.rmtree(DOWNLOAD_TMP)
            print("🌊 Cleaned up temporary download directory.")
        else:
            print("🌊 No temporary files to clean.")

    def run(self):
        args, unknown = self.parser.parse_known_args()

        if args.help:
            self._print_custom_help()
            return

        if '--skip-ssl' in unknown:
            args.skip_ssl = True

        self.verbose = args.verbose if hasattr(args, 'verbose') else False

        try:
            if not self._confirm_skip_ssl(args):
                sys.exit(0)

            if not args.command:
                self._print_custom_help()
                return

            if args.command == "install" and hasattr(args, 'package_name'):
                safe_name = args.package_name.lower()
                if self._is_protected(safe_name):
                    print(f"🌊 \033[31mERROR: Cannot install protected package: {safe_name}\033[0m")
                    sys.exit(1)

                binary_path = INSTALL_DIR / safe_name
                if binary_path.exists():
                    print(f"🌊 \033[93mWarning: Package '{safe_name}' is already installed.\033[0m")
                    print(f"🌊 \033[93mDo you want to overwrite it?\033[0m")
                    if self._confirm_action(""):
                        if not self._safe_delete_binary(binary_path):
                            sys.exit(1)
                        print(f"🌊 \033[31mRemoved old version of {safe_name}\033[0m")
                    else:
                        print(f"🌊 \033[32mInstallation cancelled. Existing '{safe_name}' preserved.\033[0m")
                        sys.exit(0)

            DOWNLOAD_TMP.mkdir(parents=True, exist_ok=True)
            INSTALLED_DB.parent.mkdir(parents=True, exist_ok=True)
            REPO_CACHE.parent.mkdir(parents=True, exist_ok=True)

            command_handlers = {
                "install": self.handle_install,
                "uninstall": self.handle_uninstall,
                "list": self.handle_list,
                "search": self.handle_search,
                "info": self.handle_info,
                "update": self.handle_update,
                "upgrade": self.handle_upgrade,
                "doctor": self.handle_doctor,
                "clean": self.handle_clean,
            }
            handler = command_handlers.get(args.command)
            if handler:
                handler(args)
            else:
                print(f"🌊 Error: Unknown command '{args.command}'")
                sys.exit(1)

        except KeyboardInterrupt:
            print("\n🌊 Operation cancelled by user.")
            sys.exit(130)
        except SystemExit:
            raise
        except Exception as e:
            if self.verbose:
                traceback.print_exc()
            print(f"\n🌊 Fatal error: {e}")
            sys.exit(1)


def main():
    cli = MacWaveCLI()
    cli.run()


if __name__ == "__main__":
    main()
