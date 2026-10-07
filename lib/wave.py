#!/usr/bin/env python3
"""
MacWave
A package manager for macOS/Linux jailbreak developers.
Version: 2.0.0-beta2(240E1644)
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
from pathlib import Path
from typing import Optional, Dict, Any, Union

# 绝对路径
CONFIG_FILE = Path("/opt/macwave_config/config.json")
VERSION_FILE = Path("/opt/macwave_config/VERSION.json")

# 引入分离的模块
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pkg"))
from versionparser import safe_parse_version, sort_versions, get_max_version
from help import print_custom_help

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

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
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install requests{RESET}")
    sys.exit(1)

try:
    from packaging.version import parse as parse_version, InvalidVersion
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'packaging' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install packaging{RESET}")
    sys.exit(1)

try:
    from rich.console import Console
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False


# ==========================================
# 配置加载
# ==========================================

def load_config():
    """强制加载 /opt/macwave_config/config.json，解决无限循环问题"""
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)
                base_dir = config.get("base_dir")
                if base_dir:
                    return Path(base_dir)
        except Exception:
            pass
    # 如果配置文件缺失或损坏，直接报错退出，绝不写死 ~/.local
    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall MacWave.{RESET}")
    sys.exit(1)

BASE_DIR = load_config()
# 根据新目录结构定义路径
INSTALL_DIR = BASE_DIR / "bin"                    # 存放第三方包
DOWNLOAD_TMP = BASE_DIR / "downloads" / "tmp"     # 临时下载目录
REPO_DIR = BASE_DIR / "pkg"                       # 存放解析器和包信息
REPO_CACHE = BASE_DIR / "pkg" / "repo_cache.json" # 缓存
INSTALLED_DB = BASE_DIR / "pkg" / "installed.json" # 安装记录
LIB_DIR = BASE_DIR / "lib"                        # 存放 wave 主程序
PROTECTED_PACKAGES = ["wave"]


# ==========================================
# 版本号获取（统一从 VERSION.json 读取）
# ==========================================

def get_version():
    """从 /opt/macwave_config/VERSION.json 获取主程序版本号"""
    if VERSION_FILE.exists():
        try:
            with open(VERSION_FILE, 'r') as f:
                data = json.load(f)
                return data.get("version", "unknown")
        except Exception:
            pass
    return "unknown"


# ==========================================
# 核心类
# ==========================================

class MacWaveCLI:
    def __init__(self):
        self.version = get_version()
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
            description=f"MacWave {self.version}\nA package manager for macOS/Linux jailbreak developers.",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            usage="wave <command> [package] [flags]",
            epilog="For more details, visit: https://macwave.org",
            add_help=False
        )

        parser.add_argument('-h', '--help', action='store_true', help='show this help message and exit')
        parser.add_argument('-V', '--version', action='version', version=f'MacWave {self.version} 🌊')
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
        response = input(f"{RED_BOLD}🌊 {message} [Y/n] {RESET}").strip()
        return response == 'Y' or response == 'y'

    def _confirm_skip_ssl(self, args) -> bool:
        skip_ssl = getattr(args, 'skip_ssl', False)
        if not skip_ssl:
            return True

        console = Console()
        console.print(f"{RED_BOLD}🌊 --skip-ssl parameter will skip SSL certificate verification, it is insecure. Are you sure to continue?{RESET}", style="bold red")
        if self._confirm_action(""):
            console.print(f"{GREEN}🌊 Install continue{RESET}", style="bold green")
            return True
        else:
            console.print(f"{RED_BOLD}🌊 Install stopped{RESET}", style="bold red")
            return False

    def _get_arch(self) -> str:
        """检测当前系统架构"""
        machine = platform.machine().lower()
        if machine in ['arm64', 'aarch64']:
            return 'arm64'
        elif machine in ['x86_64', 'amd64']:
            return 'amd64'
        else:
            return 'unknown'

    def fetch_repo_data(self, args=None):
        """获取仓库数据：调用 pkgparser.rb 解析 pkginfo_*.txt"""
        arch = self._get_arch()
        if arch == 'unknown':
            raise RuntimeError(f"Unsupported architecture: {platform.machine()}")

        # 确定对应的 pkginfo 文件（现在在 BASE_DIR/pkg 下）
        pkginfo_file = REPO_DIR / f"pkginfo_{arch}.txt"
        parser_file = REPO_DIR / "pkgparser.rb"

        # 检查文件是否存在
        if not pkginfo_file.exists():
            raise RuntimeError(f"Package info file not found: {pkginfo_file}")
        if not parser_file.exists():
            raise RuntimeError(f"Parser not found: {parser_file}")

        # 调用 Ruby 解析器
        try:
            result = subprocess.run(
                ['ruby', str(parser_file), str(pkginfo_file)],
                capture_output=True,
                text=True,
                timeout=30
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("Parser timed out")
        except FileNotFoundError:
            raise RuntimeError("Ruby is not installed or not found in PATH")

        # 检查解析错误
        if result.returncode != 0:
            error_msg = result.stderr.strip()
            if 'Parser error, error code' in error_msg:
                raise RuntimeError(error_msg)
            raise RuntimeError(f"Parser failed: {error_msg or result.stdout.strip() or 'unknown error'}")

        # 解析 JSON
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Invalid JSON from parser: {e}")

        # 缓存到本地
        try:
            with open(REPO_CACHE, 'w') as f:
                json.dump(data, f, indent=2)
        except Exception:
            pass

        return data

    def find_package(self, repo_data, package_name, args=None):
        self.log_verbose(f"Searching for package: {package_name}")
        all_releases = []

        # 直接从字典里读
        packages = repo_data.get("packages", {})

        if isinstance(packages, dict):
            if package_name in packages:
                pkg = packages[package_name]
                for release in pkg.get("releases", []):
                    all_releases.append({
                        "version": release.get("version"),
                        "sha256": release.get("sha256", ""),
                        # 核心：优先使用 release 自带的 url，如果没有则用包级 binary_url
                        "binary_url": release.get("url", "") or pkg.get("binary_url", ""),
                        "arch": release.get("arch", "any"),
                        "description": pkg.get("description", ""),
                        "homepage": pkg.get("homepage", ""),
                        "license": pkg.get("license", ""),
                        "author": pkg.get("author", ""),
                        "binary_name": pkg.get("binary_name", package_name)
                    })

            if not all_releases:
                print(f"{RED_BOLD}🌊 Error: Package '{package_name}' not found in repository{RESET}")
                sys.exit(1)

        if args and getattr(args, 'ver', None):
            requested_version = args.ver
            arch = self._get_arch()
            for release in all_releases:
                if release.get("version") == requested_version:
                    if release.get("arch") == arch or release.get("arch") == "any":
                        return release
            print(f"{RED_BOLD}🌊 Error: Could not find version '{requested_version}' for package '{package_name}'.{RESET}")
            sys.exit(1)

        if args and getattr(args, 'beta_version', False):
            for release in all_releases:
                if release.get("arch") == "beta":
                    return release
            print(f"{RED_BOLD}🌊 No beta version found for '{package_name}'.{RESET}")
            return None

        current_arch = self._get_arch()
        matching_releases = []

        for release in all_releases:
            arch = release.get("arch")
            if arch == current_arch or arch == "any":
                matching_releases.append(release)

        if not matching_releases:
            print(f"{RED_BOLD}🌊 Error: No release found for architecture '{current_arch}' or 'any' for package '{package_name}'{RESET}")
            sys.exit(1)

        # 使用 versionparser 排序
        matching_releases.sort(key=lambda r: safe_parse_version(r.get("version", "0.0.0")), reverse=True)
        return matching_releases[0]

    def _replace_version_placeholder(self, url_template: str, version: str) -> str:
        """替换 URL 中的 {parse_download_version} 占位符"""
        if not url_template:
            return url_template
        return url_template.replace('{parse_download_version}', version)

    def _call_installer(self, command, package_name, args, release, version, install_dir, final_path, skip_db_update=False):
        # 指向新的 pkg/ 目录下的 pkginstaller.py
        installer_path = Path(__file__).resolve().parent.parent / 'pkg' / 'pkginstaller.py'

        if not installer_path.exists():
            print(f"{RED_BOLD}🌊 Error: pkginstaller.py not found at {installer_path}{RESET}")
            sys.exit(1)

        # 核心：使用 release 里自带的 URL（此时已经是完整 URL，不需要替换占位符）
        binary_url = release.get('binary_url', '') if release else ''
        if binary_url:
            # 仅当 URL 里还残留占位符时才替换，正常情况下它已经是完整的
            binary_url = self._replace_version_placeholder(binary_url, version)

        cmd = [
            'python3', str(installer_path),
            '--command', command,
            '--package', package_name,
        ]
        if version:
            cmd.extend(['--ver', version])
        if binary_url:
            cmd.extend(['--url', binary_url])
        if release and release.get('sha256'):
            cmd.extend(['--sha256', release.get('sha256')])
        if install_dir:
            cmd.extend(['--dir', str(install_dir)])
        if final_path:
            cmd.extend(['--final-path', str(final_path)])

        if args.get('verbose'):
            cmd.append('--verbose')
        if args.get('proxy'):
            cmd.extend(['--proxy', args.get('proxy')])
        if args.get('skip_ssl'):
            cmd.append('--skip-ssl')
        if args.get('limit_rate'):
            cmd.extend(['--limit-rate', args.get('limit_rate')])
        if args.get('resume'):
            cmd.append('--resume')
        if args.get('dry_run'):
            cmd.append('--dry-run')
        if skip_db_update:
            cmd.append('--skip-db-update')

        # 核心修复：不捕获子进程输出，让进度条和颜色实时流向终端！
        result = subprocess.run(cmd)

        # 如果返回码非零，则返回错误码
        if result.returncode != 0:
            sys.exit(result.returncode)

    def handle_install(self, args):
        if args.json:
            print(json.dumps({"command": "install", "package": args.package_name}))
            return

        package_name = args.package_name
        if '@' in package_name:
            pkg_name, ver = package_name.split('@', 1)
            args.package_name = pkg_name
            args.ver = ver

        try:
            raw_data = self.fetch_repo_data(args)
        except RuntimeError as e:
            print(f"{RED_BOLD}🌊 {e}{RESET}")
            sys.exit(1)

        safe_name = args.package_name.lower()
        install_dir = INSTALL_DIR
        if args.dir:
            install_dir = Path(args.dir).expanduser().resolve()

        if args.ver:
            release = self.find_package(raw_data, safe_name, args)
            version = release.get("version")
        elif args.beta_version:
            beta_release = self.find_package(raw_data, safe_name, args)
            if not beta_release:
                print(f"{RED_BOLD}🌊 No beta version found for '{safe_name}'.{RESET}")
                if self._confirm_action("Do you want to install the latest stable version instead?"):
                    release = self.find_package(raw_data, safe_name, args)
                    version = release.get("version")
                else:
                    print("🌊 Installation cancelled.")
                    return
            else:
                release = beta_release
                version = release.get("version")
        else:
            release = self.find_package(raw_data, safe_name, args)
            version = release.get("version")

        if not version:
            final_path = install_dir / safe_name
        else:
            final_path = install_dir / f"{safe_name}@{version}"

        existing_versions = []
        for f in install_dir.glob(f"{safe_name}@*"):
            if f.name.endswith('.bak'):
                continue
            ver = f.name.split('@', 1)[1]
            existing_versions.append(ver)

        if existing_versions:
            if version in existing_versions:
                print(f"🌊 {RED_BOLD}Version {version} of '{safe_name}' is already installed.{RESET}")
                print(f"{RED_BOLD}Do you want to reinstall it? [Y/n]: {RESET}")
                if not self._confirm_action(""):
                    print(f"🌊 Installation cancelled. Existing '{safe_name}@{version}' preserved.")
                    return
            else:
                print(f"🌊 Existing version(s) of '{safe_name}' found:")
                for v in existing_versions:
                    print(f"🌊   - {safe_name}@{v}")
                print(f"🌊 Do you want to install the latest version ({version})?")
                print(f"🌊 Continue installation will NOT delete existing versions [Y/n]:")
                if not self._confirm_action(""):
                    print(f"🌊 Installation cancelled.")
                    return

        self._call_installer(
            command='install',
            package_name=safe_name,
            args=vars(args),
            release=release,
            version=version,
            install_dir=install_dir,
            final_path=final_path
        )

    def handle_uninstall(self, args):
        package_spec = args.package_name

        safe_args = {
            'verbose': args.verbose,
            'dry_run': args.dry_run,
        }

        self._call_installer(
            command='uninstall',
            package_name=package_spec,
            args=safe_args,
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
            if not installed:
                print("🌊 No packages installed yet.")
                return
            print("🌊 Installed packages:")
            for pkg_name, info in installed.items():
                version = info.get('version', 'unknown')
                binary_path = info.get('binary_path', 'unknown')
                print(f"🌊   - {pkg_name} (v{version}) -> {binary_path}")
        except Exception as e:
            print(f"{RED_BOLD}🌊 Error: Could not read installed packages: {e}{RESET}")

    def handle_search(self, args):
        query = args.query.lower()
        try:
            raw_data = self.fetch_repo_data(args)
        except RuntimeError as e:
            print(f"{RED_BOLD}🌊 {e}{RESET}")
            sys.exit(1)

        repo_data = raw_data
        matches = []

        if "packages" in repo_data:
            for pkg_name, pkg in repo_data["packages"].items():
                name = pkg.get("name", pkg_name).lower()
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
            raw_data = self.fetch_repo_data(args)
        except RuntimeError as e:
            print(f"{RED_BOLD}🌊 {e}{RESET}")
            sys.exit(1)

        safe_name = args.package_name.lower()
        repo_data = raw_data

        versions = []
        package_info = None
        for pkg_name, pkg in repo_data.get("packages", {}).items():
            if pkg_name == safe_name:
                if package_info is None:
                    package_info = pkg.copy()
                for release in pkg.get("releases", []):
                    ver = release.get("version")
                    if ver and ver not in versions:
                        versions.append(ver)

        if not package_info:
            print(f"{RED_BOLD}🌊 Error: Package '{safe_name}' not found in repository{RESET}")
            sys.exit(1)

        try:
            versions.sort(key=parse_version, reverse=True)
        except:
            versions.sort(reverse=True)

        print(f"🌊 Name:               {package_info.get('name', safe_name)}")
        print(f"🌊 Author:             {package_info.get('author', 'Unknown')}")
        print(f"🌊 Description:        {package_info.get('description', 'No description')}")
        homepage = package_info.get('homepage')
        if homepage:
            print(f"🌊 Homepage:           {homepage}")

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

        if versions:
            print(f"🌊 Available versions: {versions[0]}")
            for ver in versions[1:]:
                print(f"                       {ver}")

    def handle_update(self, args):
        print("🌊 Forcing update: parsing fresh package info...")
        try:
            if REPO_CACHE.exists():
                REPO_CACHE.unlink()
            raw_data = self.fetch_repo_data(args)
            if "packages" in raw_data:
                print(f"🌊 Package index updated successfully. Found {len(raw_data['packages'])} packages.")
            else:
                print(f"🌊 Package index updated successfully.")
        except RuntimeError as e:
            print(f"{RED_BOLD}🌊 {e}{RESET}")
            sys.exit(1)
        except Exception as e:
            print(f"{RED_BOLD}🌊 Error: Failed to update package index: {e}{RESET}")

    def handle_upgrade(self, args):
        safe_name = args.package_name.lower()

        if self._is_protected(safe_name):
            print(f"{RED_BOLD}🌊 ERROR: Cannot upgrade protected package: {safe_name}{RESET}")
            print(f"{YELLOW}🌊 To update MacWave, download the new version manually:{RESET}")
            print(f"{YELLOW}🌊   curl -fsSL -o {INSTALL_DIR}/wave https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/wave.py{RESET}")
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
                raw_data = self.fetch_repo_data(args)
            except RuntimeError as e:
                print(f"{RED_BOLD}🌊 {e}{RESET}")
                sys.exit(1)

            release = self.find_package(raw_data, safe_name, args)
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

            binary_path = Path(installed[safe_name].get('binary_path', str(INSTALL_DIR / safe_name)))

            if binary_path.exists():
                self._call_installer(
                    command='uninstall',
                    package_name=safe_name,
                    args={'verbose': args.verbose, 'dry_run': args.dry_run},
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

            with open(INSTALLED_DB, 'r+') as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)

                self._call_installer(
                    command='install',
                    package_name=safe_name,
                    args=vars(args),
                    release=release,
                    version=version,
                    install_dir=INSTALL_DIR,
                    final_path=final_path,
                    skip_db_update=True
                )

                f.seek(0)
                try:
                    installed = json.load(f)
                except json.JSONDecodeError:
                    installed = {}
                installed[safe_name] = {
                    'version': version,
                    'binary_path': str(final_path),
                    'installed_at': time.time()
                }
                f.seek(0)
                f.truncate()
                json.dump(installed, f, indent=2)

            print(f"🌊 Successfully upgraded '{safe_name}' to v{version}")

        except Exception as e:
            print(f"{RED_BOLD}🌊 Error: Failed to upgrade package: {e}{RESET}")

    def handle_doctor(self, args):
        print("🌊 Running system diagnostics...")
        missing = []
        for cmd in ['curl', 'wget', 'git', 'python3', 'ruby']:
            if shutil.which(cmd) is None:
                missing.append(cmd)

        if missing:
            print(f"{RED_BOLD}🌊 Missing dependencies: {', '.join(missing)}{RESET}")
            print("🌊 Please install the missing software packages manually.")
            sys.exit(1)
        else:
            print("🌊 All required dependencies are present.")
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
            print_custom_help()  # 调用分离后的 help.py
            return

        if '--skip-ssl' in unknown:
            args.skip_ssl = True

        self.verbose = args.verbose if hasattr(args, 'verbose') else False

        try:
            if not self._confirm_skip_ssl(args):
                sys.exit(0)

            if not args.command:
                print_custom_help()  # 调用分离后的 help.py
                return

            if args.command == "install" and hasattr(args, 'package_name'):
                safe_name = args.package_name.lower()
                if self._is_protected(safe_name):
                    print(f"{RED_BOLD}🌊 ERROR: Cannot install protected package: {safe_name}{RESET}")
                    sys.exit(1)

                binary_path = INSTALL_DIR / safe_name
                if binary_path.exists():
                    print(f"🌊 Warning: Package '{safe_name}' is already installed.")
                    print(f"🌊 Do you want to overwrite it?")
                    if self._confirm_action(""):
                        try:
                            backup_path = binary_path.with_suffix(binary_path.suffix + ".bak")
                            if backup_path.exists():
                                backup_path.unlink()
                            binary_path.rename(backup_path)
                            print(f"🌊 Removed old version of {safe_name}")
                        except Exception as e:
                            print(f"{RED_BOLD}🌊 Error: Failed to remove old version: {e}{RESET}")
                            sys.exit(1)
                    else:
                        print(f"🌊 Installation cancelled. Existing '{safe_name}' preserved.")
                        sys.exit(0)

            DOWNLOAD_TMP.mkdir(parents=True, exist_ok=True)
            INSTALLED_DB.parent.mkdir(parents=True, exist_ok=True)
            REPO_CACHE.parent.mkdir(parents=True, exist_ok=True)
            REPO_DIR.mkdir(parents=True, exist_ok=True)

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
                print(f"{RED_BOLD}🌊 Error: Unknown command '{args.command}'{RESET}")
                sys.exit(1)

        except KeyboardInterrupt:
            print("\n🌊 Operation cancelled by user.")
            sys.exit(130)
        except SystemExit:
            raise
        except Exception as e:
            if self.verbose:
                traceback.print_exc()
            print(f"{RED_BOLD}\n🌊 Fatal error: {e}{RESET}")
            sys.exit(1)


def main():
    cli = MacWaveCLI()
    cli.run()


if __name__ == "__main__":
    main()
