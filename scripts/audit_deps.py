#!/usr/bin/env python3

# audit_deps.py
# 依赖数据审计。data 模式查 infosource 数据的引用格式与完整性（不需要安装）；
# edges 模式查已安装依赖的实测动态库引用是否都被数据声明（需要本机已装依赖）。
# 用法：python3 scripts/audit_deps.py [data|edges|all] [--data-dir 目录] [--base-dir 目录] [--arch arm64] [--check-urls]
# data 模式加 --check-urls 会联网确认每个 url 可访问（默认关闭，因为依赖网络）。

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 常量 --------------------

BRANCH = "infosource"
RAW_BASE = f"https://raw.githubusercontent.com/MacWaveOrg/MacWave/{BRANCH}"
TREE_API = f"https://api.github.com/repos/MacWaveOrg/MacWave/git/trees/{BRANCH}?recursive=1"
CONFIG_FILE = Path("/opt/macwave_config/config.json")
DATA_GROUPS = ("pkg", "surfboard")
REF_PATTERN = re.compile(r'^[^@\s,]+@[^@\s,]+$')
MACHO_MAGIC = ('cffaedfe', 'cefaedfe', 'feedfacf', 'feedface', 'cafebabe', 'bebafeca')
SYSTEM_PREFIXES = ('/usr/lib/', '/System/', '/Library/Apple/')
CURL_ONLY = False
FETCH_TIMEOUT = 30
URL_TIMEOUT = 20
URL_WORKERS = 8
USER_AGENT = 'MacWave-audit'


# -------------------- 辅助函数 --------------------

def fail(message):
    print(f"{RED_BOLD}🌊 Error: {message}{RESET}")
    sys.exit(1)


def ignore_filtered(items, patterns):
    # --ignore 命中整条报告文本时不计入（用于已知的历史遗留问题）
    if not patterns:
        return items
    return [item for item in items if not any(re.search(pattern, item) for pattern in patterns)]


def detect_arch():
    # 与 pkg/pkginstaller.py 的架构命名保持一致
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "amd64"
    return "arm64"


def parse_fields(text):
    # 与 surfboard/depsinstaller.py 的 DSL 规则一致：
    # 1. 行内第一个引号前有声明（如 deps:），该行属于该字段。
    # 2. 行内第一个引号前无声明，则向上回溯到最近的字段声明。
    # 3. 同字段多行内容合并为列表。
    fields = {}
    current_key = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        head = line.split('"', 1)[0]

        if ':' in head:
            current_key = head.split(':', 1)[0].strip()
            fields.setdefault(current_key, [])
            value_text = line[len(head):]
        else:
            if current_key is None:
                continue
            value_text = line

        for value in re.findall(r'"([^"]*)"', value_text):
            fields[current_key].append(value)

    return fields


def get_deps(fields):
    return [value for value in fields.get("deps", []) if str(value).strip()]


def is_macho(path):
    try:
        with open(path, 'rb') as f:
            return f.read(4).hex() in MACHO_MAGIC
    except OSError:
        return False


def macho_refs(path):
    result = subprocess.run(['otool', '-L', str(path)], capture_output=True, text=True)
    refs = []
    for line in result.stdout.splitlines()[1:]:
        ref = line.split(" (")[0].strip()
        if ref and not ref.startswith(SYSTEM_PREFIXES):
            refs.append(ref)
    return refs


def split_data_path(path):
    # surfboard/depsinfo_arm64/gettext/_gettext@0.21.0 -> ("dep", "arm64", "gettext@0.21.0")
    parts = path.split("/")
    group = parts[0]
    kind = "dep" if group == "surfboard" else "pkg"
    arch = parts[1].split("info_", 1)[1]
    return kind, arch, os.path.basename(path).lstrip("_")


# -------------------- 数据来源 --------------------

def load_local_data(root):
    files = {}
    for group in DATA_GROUPS:
        if not (root / group).is_dir():
            continue
        for data_dir in sorted((root / group).glob("*info_*")):
            for path in sorted(data_dir.rglob("_*@*")):
                files[str(path.relative_to(root))] = path.read_text()
    return files


class FetchError(Exception):
    pass


def request_headers(url):
    # api.github.com 未认证时只有 60 次/小时，而 CI Runner 共用出口 IP，很容易被限流；
    # 带上 token 后配额提到 5000 次/小时（raw.githubusercontent.com 不需要）
    if 'api.github.com' not in url:
        return {}
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    return {'Authorization': f'Bearer {token}'} if token else {}


def fetch_text(url):
    # 优先用标准库；本地 Python 缺根证书（macOS 常见）时改走 curl，且不再重复尝试
    global CURL_ONLY
    headers = request_headers(url)

    if not CURL_ONLY:
        try:
            request = urllib.request.Request(url, headers={**headers, 'User-Agent': USER_AGENT})
            with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
                return response.read().decode()
        except urllib.error.HTTPError as error:
            # 服务端已经明确回应了（比如 403 限流），直接带原因报错
            raise FetchError(f"{url} -> HTTP {error.code}")
        except (urllib.error.URLError, TimeoutError, UnicodeDecodeError):
            CURL_ONLY = True

    command = ['curl', '-fsSL', '--http1.1', '--retry', '3', '--retry-delay', '2',
               '--retry-all-errors', '--max-time', str(FETCH_TIMEOUT)]
    for key, value in headers.items():
        command += ['-H', f'{key}: {value}']
    command.append(url)

    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        raise FetchError(url)
    return result.stdout.decode()


def head_status(url):
    # 只取状态码，供 --check-urls 做连通性检查；网络层失败返回 0，由调用方按“需人工确认”处理
    global CURL_ONLY
    if not CURL_ONLY:
        try:
            request = urllib.request.Request(url, method='HEAD', headers={'User-Agent': USER_AGENT})
            with urllib.request.urlopen(request, timeout=URL_TIMEOUT) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code
        except (urllib.error.URLError, TimeoutError):
            CURL_ONLY = True

    result = subprocess.run(['curl', '-sIL', '--http1.1', '--retry', '2', '--max-time', str(URL_TIMEOUT),
                             '-o', '/dev/null', '-w', '%{http_code}', url], capture_output=True)
    if result.returncode != 0:
        return 0
    try:
        return int(result.stdout.decode().strip())
    except ValueError:
        return 0


def load_remote_data():
    try:
        tree = json.loads(fetch_text(TREE_API))["tree"]
    except FetchError as error:
        fail(f"Cannot fetch the data tree from GitHub: {error}\n"
             "🌊 With no token, api.github.com allows only 60 requests per hour and CI runners share their "
             "IP, so this is often a rate limit. Set GH_TOKEN, or pass --data-dir with a local checkout "
             "of the 'infosource' branch.")
    except (ValueError, KeyError):
        fail(f"Cannot parse the data tree returned by GitHub ({TREE_API}).")

    paths = []
    for item in tree:
        path = item.get("path", "")
        name = os.path.basename(path)
        if item.get("type") == "blob" and "@" in name and name.startswith("_"):
            if path.split("/")[0] in DATA_GROUPS:
                paths.append(path)

    print(f"🌊 Fetching {len(paths)} data file(s) from branch '{BRANCH}'...")
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            contents = list(pool.map(fetch_text, [f"{RAW_BASE}/{quote(path)}" for path in paths]))
    except FetchError as error:
        fail(f"Cannot fetch {error}.")

    return dict(zip(paths, contents))


def resolve_data(data_dir):
    if data_dir:
        root = Path(data_dir).expanduser()
        if not root.is_dir():
            fail(f"Data directory not found: {root}")
        return load_local_data(root)

    # 在 infosource 分支上直接读本地，否则从 GitHub 拉取
    repo_root = Path(__file__).resolve().parent.parent
    for group in DATA_GROUPS:
        if any((repo_root / group).glob("*info_*")):
            return load_local_data(repo_root)

    return load_remote_data()


# -------------------- data 模式 --------------------

def audit_data(files, check_urls=False):
    print("🌊 Auditing dependency data...")

    version_files = {}
    common_paths = set()
    for path in files:
        if os.path.basename(path).endswith("@common"):
            common_paths.add(path)
        else:
            kind, arch, ref = split_data_path(path)
            version_files[path] = (kind, arch, ref)

    problems = []
    warnings = []
    refs = 0
    url_targets = []

    # 文件名（含目录）里有空格时，安装器拼 URL 不会转义，必然 404
    for path in sorted(files):
        if " " in path:
            problems.append(f"{path}: 文件名含空格（安装器拼 URL 时不会转义）")

    for path in sorted(version_files):
        kind, arch, ref = version_files[path]
        fields = parse_fields(files[path])
        label = f"{path.split('/')[1]}/{ref}"

        url = (fields.get("url") or [""])[0]
        if not url.startswith("https://"):
            problems.append(f"{label}: url 缺失或跨行损坏（必须单行且带引号）-> {url or '(无)'}")
        elif check_urls:
            url_targets.append((label, url))

        sha256 = (fields.get("sha256") or [""])[0]
        if not sha256:
            warnings.append(f"{label}: 未声明 sha256（安装器会跳过校验）")
        elif not re.fullmatch(r'[0-9a-f]{64}', sha256):
            problems.append(f"{label}: sha256 不是 64 位小写十六进制 -> {sha256}")

        deps = get_deps(fields)
        seen = set()
        for dep_ref in deps:
            if not REF_PATTERN.match(dep_ref):
                problems.append(f"{label}: deps 引用格式错误（不能用逗号分隔/不能有空格）-> '{dep_ref}'")
                continue
            if dep_ref in seen:
                warnings.append(f"{label}: deps 里重复声明 {dep_ref}")
            seen.add(dep_ref)
            refs += 1

            dep_name, _, dep_version = dep_ref.partition("@")
            common_path = f"surfboard/depsinfo_{arch}/{dep_name}/_{dep_name}@common"
            version_path = f"surfboard/depsinfo_{arch}/{dep_name}/_{dep_name}@{dep_version}"
            if common_path not in common_paths:
                problems.append(f"{label}: depsinfo 缺少 {dep_name} 的 @common")
            if version_path not in files:
                problems.append(f"{label}: depsinfo 缺少 {dep_name}@{dep_version} 的版本文件")

    # 格式合法不代表能取到：实测确认每个 url 可达，避免出现“看着正常但 404”的死链
    if url_targets:
        print(f"🌊 Probing {len(url_targets)} url(s) over the network...")
        with ThreadPoolExecutor(max_workers=URL_WORKERS) as pool:
            statuses = list(pool.map(lambda target: head_status(target[1]), url_targets))
        for (label, url), status in zip(url_targets, statuses):
            if status in (404, 410):
                problems.append(f"{label}: url 返回 HTTP {status}（资源不存在）-> {url}")
            elif status != 200:
                warnings.append(f"{label}: url 返回 HTTP {status or '无响应'}（需人工确认）-> {url}")

    for path in sorted(common_paths):
        kind, arch, ref = split_data_path(path)
        owner = ref.split("@")[0]
        fields = parse_fields(files[path])
        label = f"{path.split('/')[1]}/{ref}"

        # dep_name / bin_name 缺失时安装器都有退回逻辑，因此按警告处理
        if kind == "dep":
            dep_name = (fields.get("dep_name") or [""])[0]
            if not dep_name:
                warnings.append(f"{label}: @common 缺少 dep_name（安装器会退回用引用名）")
            elif dep_name != owner:
                warnings.append(f"{label}: @common 的 dep_name 是 '{dep_name}'，与目录名不一致")
        elif not fields.get("bin_name"):
            problems.append(f"{label}: @common 缺少 bin_name")

    print(f"🌊 Checked {len(version_files)} version file(s) and {refs} dependency reference(s).")
    return problems, warnings


# -------------------- edges 模式 --------------------

def resolve_base_dir(base_dir):
    if base_dir:
        root = Path(base_dir).expanduser()
    elif CONFIG_FILE.exists():
        try:
            root = Path(json.loads(CONFIG_FILE.read_text())["base_dir"])
        except (ValueError, KeyError):
            return None
    else:
        return None

    return root if root.is_dir() else None


def audit_edges(files, base_dir, arch):
    deps_root = base_dir / "deps"
    if not deps_root.is_dir():
        print(f"{YELLOW}🌊 No installed dependencies in {deps_root}, skipping the edge audit.{RESET}")
        return [], []

    if subprocess.run(['which', 'otool'], capture_output=True).returncode != 0:
        fail("'otool' not found. Install the Xcode Command Line Tools: xcode-select --install")

    print(f"🌊 Auditing dependency edges in {deps_root}...")

    # 库文件名 -> 提供它的依赖名
    provider = {}
    for owner_dir in sorted(deps_root.iterdir()):
        if not owner_dir.is_dir():
            continue
        for version_dir in sorted(owner_dir.iterdir()):
            lib_dir = version_dir / "lib"
            if not lib_dir.is_dir():
                continue
            for lib in lib_dir.iterdir():
                provider.setdefault(lib.name, owner_dir.name)

    problems = []
    warnings = []
    checked = 0

    for owner_dir in sorted(deps_root.iterdir()):
        if not owner_dir.is_dir():
            continue

        for version_dir in sorted(owner_dir.iterdir()):
            if not version_dir.is_dir():
                continue

            name, _, version = version_dir.name.partition("@")
            checked += 1

            # 以数据里的声明为准，数据缺失时退回已安装的 _DEPS
            data_path = f"surfboard/depsinfo_{arch}/{name}/_{name}@{version}"
            if data_path in files:
                declared = {ref.partition("@")[0] for ref in get_deps(parse_fields(files[data_path]))}
            else:
                deps_file = version_dir / "_DEPS"
                declared = set()
                if deps_file.is_file():
                    declared = {line.strip().strip('"').partition("@")[0]
                                for line in deps_file.read_text().splitlines() if line.strip()}
                warnings.append(f"{name}@{version}: 没有对应的数据文件，用已安装的 _DEPS 代替")

            referenced = set()
            for path in list(version_dir.rglob("lib/*")) + list(version_dir.rglob("bin/*")):
                if not path.is_file() or not is_macho(path):
                    continue
                for ref in macho_refs(path):
                    owner = provider.get(os.path.basename(ref))
                    if owner and owner != name:
                        referenced.add(owner)

            for owner in sorted(referenced - declared):
                problems.append(f"{name}@{version} 实际引用了 {owner}，但数据里没有声明")
            for owner in sorted(declared - referenced):
                warnings.append(f"{name}@{version} 声明了 {owner}，但本机产物里没有引用")

    print(f"🌊 Checked {checked} installed dependency(ies).")
    return problems, warnings


# -------------------- 主流程 --------------------

def main():
    parser = argparse.ArgumentParser(
        description="Audit MacWave dependency data (infosource) and the installed dependency edges.")
    parser.add_argument("mode", nargs="?", default="all", choices=["data", "edges", "all"],
                        help="data: 只查数据；edges: 只查本机依赖边；all: 两者都查（默认）")
    parser.add_argument("--data-dir", help="infosource 检出的目录（默认：本地有就用，否则从 GitHub 拉取）")
    parser.add_argument("--base-dir", help="MacWave 安装目录（默认读 /opt/macwave_config/config.json）")
    parser.add_argument("--arch", choices=["arm64", "amd64"], help="目标架构（默认本机架构）")
    parser.add_argument("--check-urls", action="store_true",
                        help="联网确认每个 url 可访问（默认关闭；依赖网络，按需开启）")
    parser.add_argument("--ignore", action="append", default=[],
                        help="忽略匹配该正则的报告（可重复），用于已知的历史遗留问题")
    args = parser.parse_args()

    arch = args.arch or detect_arch()
    print(f"🌊 MacWave dependency audit (arch: {arch})")

    files = resolve_data(args.data_dir)
    problems = []
    warnings = []

    if args.mode in ("data", "all"):
        found, notes = audit_data(files, args.check_urls)
        problems += found
        warnings += notes

    if args.mode in ("edges", "all"):
        base_dir = resolve_base_dir(args.base_dir)
        if base_dir is None:
            if args.mode == "edges":
                fail("MacWave is not installed. Use --base-dir to point at an installation.")
        else:
            found, notes = audit_edges(files, base_dir, arch)
            problems += found
            warnings += notes

    problems = ignore_filtered(problems, args.ignore)
    warnings = ignore_filtered(warnings, args.ignore)

    print("")
    for warning in warnings:
        print(f"{YELLOW}🌊 Warning: {warning}{RESET}")
    if problems:
        print(f"{RED_BOLD}🌊 {len(problems)} problem(s) found:{RESET}")
        for problem in problems:
            print(f"{RED_BOLD}  ✗ {problem}{RESET}")
        sys.exit(1)

    print(f"{GREEN}🌊 Audit passed.{RESET}")


if __name__ == "__main__":
    main()
