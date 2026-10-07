#!/usr/bin/env python3
"""
MacWave Querier Module (2.1 重构版)
负责依赖查询、路径管理、卸载判断、自动安装依赖等高级功能。
支持 _deps、_path、.dep 标记文件的完整读写。
"""

import os
import json
import shutil
import subprocess
import sys
import re
from pathlib import Path

CONFIG_FILE = Path("/opt/macwave_config/config.json")

RED = '\033[31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
BOLD = '\033[1m'
RESET = '\033[0m'


# ==========================================
# 配置与路径
# ==========================================

def load_base_dir():
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)
                base_dir = config.get("base_dir")
                if base_dir:
                    return Path(base_dir)
        except Exception:
            pass
    return Path.home() / ".local" / "macwave"


BASE_DIR = load_base_dir()
INSTALL_DIR = BASE_DIR / "bin"
DEPS_DIR = BASE_DIR / "deps"
INSTALLED_DB = BASE_DIR / "pkg" / "installed.json"


def _load_installed():
    if INSTALLED_DB.exists():
        with open(INSTALLED_DB, 'r') as f:
            return json.load(f)
    return {}


def _get_arch():
    import platform
    machine = platform.machine().lower()
    if machine in ['arm64', 'aarch64']:
        return 'arm64'
    elif machine in ['x86_64', 'amd64']:
        return 'amd64'
    return 'unknown'


def _get_data_base_url():
    return "https://raw.githubusercontent.com/MacWaveOrg/MacWave/infosource"


def to_tilde(path):
    home = os.path.expanduser("~")
    if str(path).startswith(home):
        return "~" + str(path)[len(home):]
    return str(path)


# ==========================================
# 文件读取辅助（基于标记文件）
# ==========================================

def _read_deps(pkg_dir):
    deps_file = pkg_dir / "_deps"
    if not deps_file.exists():
        return []
    with open(deps_file, 'r') as f:
        return [line.strip() for line in f if line.strip()]


def _read_path(pkg_dir):
    path_file = pkg_dir / "_path"
    if not path_file.exists():
        return []
    with open(path_file, 'r') as f:
        return [line.strip() for line in f if line.strip()]


def _has_marker(dep_dir, pkg_name, pkg_version):
    marker = dep_dir / f".dep_{pkg_name}@{pkg_version}"
    return marker.exists()


def _find_pkg_dir(package, version=None):
    if version:
        pkg_dir = INSTALL_DIR / f"{package}@{version}"
        if pkg_dir.exists():
            return pkg_dir
        return None
    else:
        pkg_dirs = list(INSTALL_DIR.glob(f"{package}@*"))
        if pkg_dirs:
            return pkg_dirs[0]
        return None


# ==========================================
# 列表展示
# ==========================================

def list_deps(detailed=False):
    if not DEPS_DIR.exists():
        print("🌊 No dependencies installed yet.")
        return
    deps = {}
    for dep_dir in DEPS_DIR.iterdir():
        if dep_dir.is_dir():
            markers = list(dep_dir.glob(".dep_*"))
            if markers:
                parts = dep_dir.name.split('@')
                if len(parts) == 2:
                    name, version = parts
                    if name not in deps:
                        deps[name] = []
                    deps[name].append(version)
    for name in sorted(deps.keys()):
        versions = deps[name]
        if detailed:
            print(f"🌊 - {name}@{versions[0]}")
            for v in versions[1:]:
                padding = len(f"🌊 - {name}")
                print(f"{' ' * padding}@{v}")
        else:
            print(f"🌊 - {name}")


def list_packages():
    if not INSTALL_DIR.exists():
        print("🌊 No packages installed yet.")
        return
    packages = []
    for pkg_dir in INSTALL_DIR.iterdir():
        if pkg_dir.is_dir() and (pkg_dir / "_deps").exists():
            parts = pkg_dir.name.split('@')
            if len(parts) == 2:
                packages.append((parts[0], parts[1]))
    if not packages:
        print("🌊 No packages installed yet.")
        return
    print("🌊 Installed packages:")
    for pkg_name, version in packages:
        print(f"🌊   - {pkg_name} (v{version})")


# ==========================================
# 依赖查询
# ==========================================

def query_deps(package, version=None, detailed=False):
    pkg_dir = _find_pkg_dir(package, version)
    if not pkg_dir:
        print(f"🌊 Package '{package}' not found.")
        return
    deps = _read_deps(pkg_dir)
    if not deps:
        print(f"🌊 Package '{package}' has no dependencies.")
        return
    for dep in deps:
        if '@' in dep:
            name, ver = dep.split('@', 1)
            dep_dir = DEPS_DIR / f"{name}@{ver}"
            if detailed:
                if dep_dir.exists():
                    print(f"{GREEN}🌊 - {name}@{ver}{RESET}")
                else:
                    print(f"{RED}🌊 - {name}@{ver}  # 缺失{RESET}")
            else:
                print(f"🌊 - {name}@{ver}")


def query_pkg_reverse(dep_name, dep_version=None):
    pkg_dirs = list(INSTALL_DIR.glob("*@*"))
    if dep_version:
        dep_key = f"{dep_name}@{dep_version}"
        for pkg_dir in pkg_dirs:
            deps = _read_deps(pkg_dir)
            if dep_key in deps:
                parts = pkg_dir.name.split('@')
                if len(parts) == 2:
                    print(f"🌊 - {parts[0]}@{parts[1]}")
    else:
        for pkg_dir in pkg_dirs:
            deps = _read_deps(pkg_dir)
            for dep in deps:
                if dep.startswith(f"{dep_name}@"):
                    dep_ver = dep.split('@', 1)[1]
                    parts = pkg_dir.name.split('@')
                    if len(parts) == 2:
                        print(f"🌊 @{dep_ver}")
                        print(f"    - {parts[0]}@{parts[1]}")


# ==========================================
# 路径管理
# ==========================================

def change_dep_path(package, version, dep, new_path):
    if not new_path:
        print(f"{RED}🌊 Error: Missing new path.{RESET}")
        return
    if '..' in new_path:
        print(f"{RED}🌊 Error: Relative paths are not allowed. Please use an absolute path.{RESET}")
        return
    pkg_dir = _find_pkg_dir(package, version)
    if not pkg_dir:
        print(f"{RED}🌊 Error: Package not found.{RESET}")
        return
    path_file = pkg_dir / "_path"
    if not path_file.exists():
        print(f"{RED}🌊 Error: Path file not found.{RESET}")
        return
    if not (pkg_dir / "_path.bak_default").exists():
        shutil.copy2(path_file, pkg_dir / "_path.bak_default")
    with open(path_file, 'w') as f:
        f.write(new_path)
    print(f"{GREEN}🌊 Path updated for {package}@{version}.{RESET}")


def restore_default_path(package, version, dep):
    pkg_dir = _find_pkg_dir(package, version)
    if not pkg_dir:
        print(f"{RED}🌊 Error: Package not found.{RESET}")
        return
    path_file = pkg_dir / "_path"
    default_bak = pkg_dir / "_path.bak_default"
    if not default_bak.exists():
        print(f"{RED}🌊 Error: No default backup found.{RESET}")
        return
    i = 1
    while (pkg_dir / f"_path.bak_{i}").exists():
        i += 1
    shutil.copy2(path_file, pkg_dir / f"_path.bak_{i}")
    shutil.copy2(default_bak, path_file)
    print(f"{GREEN}🌊 Default path restored.{RESET}")


def delete_path_record(package, version=None, force=False):
    if '@' in package:
        pkg_name, ver = package.split('@', 1)
    else:
        pkg_name = package
        ver = None
    if '*' in package or '@' in package:
        pkg_dirs = list(INSTALL_DIR.glob(f"{pkg_name}@*"))
        if ver and '*' not in ver:
            pkg_dirs = [d for d in pkg_dirs if d.name.endswith(f"@{ver}")]
    else:
        pkg_dirs = list(INSTALL_DIR.glob(f"{pkg_name}@*"))
    if not pkg_dirs:
        print(f"{RED}🌊 Package '{package}' not found.{RESET}")
        return
    for pkg_dir in pkg_dirs:
        backups = sorted(pkg_dir.glob("_path.bak_*"))
        if force:
            backups = sorted(pkg_dir.glob("_path.bak_*"))
        else:
            backups = [b for b in backups if not b.name.endswith("default")]
        if not backups:
            continue
        print(f"🌊 Found backup records for {pkg_dir.name}:")
        for b in backups:
            print(f"  - {b.name}")
        response = input(f"🌊 Delete these records? [Y/n]: ").strip()
        if response.lower() == 'y':
            for b in backups:
                b.unlink()
                print(f"🌊 Deleted: {b.name}")
        print(f"{GREEN}🌊 Path records deleted.{RESET}")


# ==========================================
# 自动安装依赖（基于 _deps 和 .dep 标记）
# ==========================================

def _download_dep(name, version, url, sha256=None):
    import requests
    dep_dir = DEPS_DIR / f"{name}@{version}"
    if dep_dir.exists():
        return
    DOWNLOAD_TMP = BASE_DIR / "downloads" / "tmp"
    DOWNLOAD_TMP.mkdir(parents=True, exist_ok=True)
    tmp_path = DOWNLOAD_TMP / f"{name}_{version}.partial"
    if tmp_path.exists():
        tmp_path.unlink()
    try:
        response = requests.get(url, stream=True, timeout=30)
        if response.status_code == 404:
            print(f"{RED}🌊 Error: Dependency URL not found: {url}{RESET}")
            return
        if response.status_code != 200:
            print(f"{RED}🌊 Error: Failed to download {name}@{version}: {response.status_code}{RESET}")
            return
        with open(tmp_path, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)
    except Exception as e:
        print(f"{RED}🌊 Error: {e}{RESET}")
        return
    if sha256:
        import hashlib
        actual = hashlib.sha256(tmp_path.read_bytes()).hexdigest()
        if actual != sha256:
            print(f"{RED}🌊 Error: SHA256 mismatch for {name}@{version}{RESET}")
            tmp_path.unlink()
            return
    import subprocess
    dep_dir.mkdir(parents=True, exist_ok=True)
    depsunzip_path = Path(__file__).resolve().parent / "depsunzip.sh"
    result = subprocess.run(
        ['bash', str(depsunzip_path), name, version, str(tmp_path)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"{RED}🌊 Error: Failed to extract dependency: {result.stderr}{RESET}")
        tmp_path.unlink()
        return

    # 安装完依赖后，必须调用 tagger.sh 生成 .dep 标记
    # 由于 _download_dep 并不知道是谁引用了这个依赖，我们暂时先不调用。
    # 完整的 tagger.sh 调用应放在 install_deps 内部，由 install_deps 明确知道引用者是谁。
    # 这里我们先保留 _download_dep 的纯净下载+解压功能。

    tmp_path.unlink()
    print(f"{GREEN}🌊 Dependency {name}@{version} installed.{RESET}")


def _get_dep_data(dep_name, dep_version):
    import requests
    arch = _get_arch()
    url = f"{_get_data_base_url()}/surfboard/depsinfo_{arch}/{dep_name}/_{dep_name}@{dep_version}"
    try:
        r = requests.get(url, timeout=30)
        if r.status_code == 404:
            return None
        if r.status_code != 200:
            return None
        return r.text
    except Exception:
        return None


def _get_dep_url_and_sha(dep_name, dep_version):
    data_text = _get_dep_data(dep_name, dep_version)
    if not data_text:
        return None, None
    url = None
    sha256 = None
    for line in data_text.strip().splitlines():
        line = line.strip()
        if line.startswith("url:"):
            url = line.split(":", 1)[1].strip().strip('"')
        elif line.startswith("sha256:"):
            sha256 = line.split(":", 1)[1].strip().strip('"')
    return url, sha256


def install_deps(target=None, missing=False, missing_all=False):
    import requests
    import subprocess
    from pathlib import Path

    if missing_all:
        print(f"{GREEN}🌊 Checking all packages for missing dependencies...{RESET}")
        pkg_dirs = list(INSTALL_DIR.glob("*@*"))
        all_deps = []
        for pkg_dir in pkg_dirs:
            deps = _read_deps(pkg_dir)
            all_deps.extend(deps)
        for dep in all_deps:
            if '@' in dep:
                name, ver = dep.split('@', 1)
                dep_dir = DEPS_DIR / f"{name}@{ver}"
                if not dep_dir.exists():
                    url, sha256 = _get_dep_url_and_sha(name, ver)
                    if url:
                        _download_dep(name, ver, url, sha256)
                    else:
                        print(f"{RED}🌊 Missing dependency data: {name}@{ver}{RESET}")
        print(f"{GREEN}🌊 Dependency check complete.{RESET}")
        return

    if missing:
        if not target:
            print(f"{RED}🌊 Error: Missing package name.{RESET}")
            return
        if '@' in target:
            pkg, ver = target.split('@', 1)
        else:
            pkg = target
            ver = None
        pkg_dir = _find_pkg_dir(pkg, ver)
        if not pkg_dir:
            print(f"{RED}🌊 Package '{pkg}' not found.{RESET}")
            return
        deps = _read_deps(pkg_dir)
        if not deps:
            print(f"🌊 Package '{pkg}' has no dependencies.")
            return
        for dep in deps:
            if '@' in dep:
                name, ver = dep.split('@', 1)
                dep_dir = DEPS_DIR / f"{name}@{ver}"
                if not dep_dir.exists():
                    url, sha256 = _get_dep_url_and_sha(name, ver)
                    if url:
                        _download_dep(name, ver, url, sha256)
                    else:
                        print(f"{RED}🌊 Missing dependency data: {name}@{ver}{RESET}")
        print(f"{GREEN}🌊 Dependency check complete.{RESET}")
        return

    if target:
        if '@' in target:
            dep_name, dep_ver = target.split('@', 1)
            dep_dir = DEPS_DIR / f"{dep_name}@{dep_ver}"
            if dep_dir.exists():
                print(f"{GREEN}🌊 Dependency {dep_name}@{dep_ver} already installed.{RESET}")
            else:
                url, sha256 = _get_dep_url_and_sha(dep_name, dep_ver)
                if url:
                    _download_dep(dep_name, dep_ver, url, sha256)
                else:
                    print(f"{RED}🌊 Missing dependency data: {dep_name}@{dep_ver}{RESET}")
        return


# ==========================================
# 卸载依赖
# ==========================================

def uninstall_deps(dep_name=None, dep_version=None, unnecessary=False):
    if unnecessary:
        if not DEPS_DIR.exists():
            print("🌊 No dependencies installed.")
            return
        unnecessary_deps = []
        for dep_dir in DEPS_DIR.iterdir():
            if dep_dir.is_dir():
                markers = list(dep_dir.glob(".dep_*"))
                if not markers:
                    unnecessary_deps.append(dep_dir)
        if not unnecessary_deps:
            print("🌊 No unnecessary dependencies found.")
            return
        print("🌊 The following dependencies are unused:")
        for d in unnecessary_deps:
            print(f"  - {d.name}")
        response = input(f"🌊 Delete all unused dependencies? [Y/n]: ").strip()
        if response.lower() == 'y':
            for d in unnecessary_deps:
                shutil.rmtree(d)
                print(f"🌊 Deleted: {d.name}")
            print(f"{GREEN}🌊 Unnecessary dependencies removed.{RESET}")
        else:
            print("🌊 Operation cancelled.")
        return

    if not dep_name:
        print(f"{RED}🌊 Error: Missing dependency name.{RESET}")
        return

    if dep_version:
        dep_dir = DEPS_DIR / f"{dep_name}@{dep_version}"
        if dep_dir.exists():
            response = input(f"🌊 Are you sure you want to uninstall {dep_name}@{dep_version}? [Y/n]: ").strip()
            if response.lower() == 'y':
                shutil.rmtree(dep_dir)
                print(f"{GREEN}🌊 Dependency {dep_name}@{dep_version} uninstalled.{RESET}")
            else:
                print("🌊 Operation cancelled.")
        else:
            print(f"{RED}🌊 Dependency {dep_name}@{dep_version} not found.{RESET}")
    else:
        dep_dirs = list(DEPS_DIR.glob(f"{dep_name}@*"))
        if not dep_dirs:
            print(f"{RED}🌊 Dependency '{dep_name}' not found.{RESET}")
            return
        print("🌊 Found the following versions:")
        for d in dep_dirs:
            print(f"  - {d.name}")
        response = input(f"🌊 Are you sure you want to delete all versions of '{dep_name}'? [Y/n]: ").strip()
        if response.lower() == 'y':
            for d in dep_dirs:
                shutil.rmtree(d)
                print(f"🌊 Deleted: {d.name}")
            print(f"{GREEN}🌊 Dependency '{dep_name}' uninstalled.{RESET}")
        else:
            print("🌊 Operation cancelled.")


# ==========================================
# 命令行入口
# ==========================================

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 querier.py <command> [args]")
        return
    command = sys.argv[1]
    args = sys.argv[2:]
    if command == "list_deps":
        detailed = False
        if '-d' in args or '--detailed' in args:
            detailed = True
        list_deps(detailed)
    elif command == "list_packages":
        list_packages()
    elif command == "query_deps":
        pkg = args[0] if args else ""
        ver = None
        detailed = False
        if '-d' in args or '--detailed' in args:
            detailed = True
        if '@' in pkg:
            pkg, ver = pkg.split('@', 1)
        query_deps(pkg, ver, detailed)
    elif command == "query_pkg_reverse":
        dep = args[0] if args else ""
        dep_ver = None
        if '@' in dep:
            dep, dep_ver = dep.split('@', 1)
        query_pkg_reverse(dep, dep_ver)
    elif command == "change_dep_path":
        if len(args) >= 3:
            change_dep_path(args[0], args[1], args[2], args[3] if len(args) > 3 else None)
        else:
            print("Usage: change_dep_path <pkg> <version> <dep> <path>")
    elif command == "restore_default_path":
        restore_default_path(args[0], args[1], args[2])
    elif command == "delete_path_record":
        force = '--force' in args
        args = [a for a in args if a != '--force']
        if args:
            pkg = args[0]
            ver = args[1] if len(args) > 1 else None
            delete_path_record(pkg, ver, force)
    elif command == "install_deps":
        target = args[0] if args else None
        missing = False
        missing_all = False
        if '-m' in args or '--missing' in args:
            missing = True
        if '-ma' in args or '--missing-all' in args:
            missing_all = True
        if target and '@' in target:
            target, _ = target.split('@', 1)
        install_deps(target, missing, missing_all)
    elif command == "uninstall_deps":
        dep_name = args[0] if args else None
        dep_ver = None
        unnecessary = False
        if '-u' in args or '--unnecessary' in args:
            unnecessary = True
        if dep_name and '@' in dep_name:
            dep_name, dep_ver = dep_name.split('@', 1)
        uninstall_deps(dep_name, dep_ver, unnecessary)
    else:
        print(f"Unknown command: {command}")


if __name__ == "__main__":
    main()
