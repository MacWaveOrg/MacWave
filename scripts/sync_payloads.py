#!/usr/bin/env python3

# sync_payloads.py
# 把 infosource 里登记的产物抓下来，按 4.0 的约定命名，写成一棵树。
#
#   <out>/bottle/<包名>/<包名>@<版本>.<架构><扩展名>
#   <out>/deps/<依赖名>/<依赖名>@<版本>.<架构><扩展名>
#
# 这棵树同时是两种东西：
#   1. 上传到 Bottle / Deps 仓库 Release 的内容（CI 用）
#   2. 镜像站 nginx 的根目录（用户自己用 rsync/发布工具同步过去）
#
# 字节原样搬运，不重打包，所以 sha256 必须与索引里写的一致；不一致就报错，
# 不写入 —— 宁可缺一个包，也不要放一个校验不过的文件进去。
#
# 用法：
#   python3 scripts/sync_payloads.py --infosource ../infosource --out ./mirror
#   python3 scripts/sync_payloads.py --infosource ../infosource --out ./mirror --only jq,yq
#   python3 scripts/sync_payloads.py --infosource ../infosource --out ./mirror --kinds bottle
#
# 重复运行是安全的：已经存在且校验通过的文件会跳过。

import argparse
import concurrent.futures as futures
import hashlib
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(REPO_DIR / "lib"))

import domains  # noqa: E402  —— 命名规则只此一份，避免脚本与客户端各写一套

SHA_RE = re.compile(r'^sha256:\s*"([0-9a-f]{64})"\s*$', re.M)
URL_RE = re.compile(r'^url:\s*"([^"]+)"\s*$', re.M)
FILE_RE = re.compile(r'^file:\s*"([^"]+)"\s*$', re.M)

# 目录名 → 架构：pkginfo_arm64 / depsinfo_amd64
ARCH_RE = re.compile(r'^(?:pkginfo|depsinfo)_(arm64|amd64)$')


def records(infosource):
    # 产出 (kind, arch, name, version, path)
    for kind, root_name in (("bottle", "pkg"), ("deps", "deps")):
        root = infosource / root_name
        if not root.is_dir():
            continue
        for directory in sorted(root.iterdir()):
            match = ARCH_RE.match(directory.name)
            if not match:
                continue
            arch = match.group(1)
            for record in sorted(directory.glob("*/_*@*")):
                if record.name.endswith("@common"):
                    continue
                # _<名字>@<版本>
                stem = record.name[1:]
                name, _, version = stem.partition("@")
                if not name or not version:
                    continue
                yield kind, arch, name, version, record


def read_record(path):
    text = path.read_text()
    sha = SHA_RE.search(text)
    url = URL_RE.search(text)
    fil = FILE_RE.search(text)
    return (sha.group(1) if sha else "",
            url.group(1) if url else "",
            fil.group(1) if fil else "")


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url, destination, timeout=60, attempts=3):
    import requests

    partial = destination.with_suffix(destination.suffix + ".part")
    destination.parent.mkdir(parents=True, exist_ok=True)

    for attempt in range(1, attempts + 1):
        try:
            with requests.get(url, stream=True, timeout=timeout) as response:
                if response.status_code != 200:
                    return f"HTTP {response.status_code}"
                with open(partial, "wb") as stream:
                    for chunk in response.iter_content(1 << 16):
                        stream.write(chunk)
            partial.replace(destination)
            return ""
        except Exception as error:
            partial.unlink(missing_ok=True)
            if attempt == attempts:
                return str(error)[:120]
    return "download failed"


def sync_one(job, out_dir, overwrite, source):
    kind, arch, name, version, record = job
    sha, url, upstream_name = read_record(record)

    if not sha:
        return ("error", f"{record}: no sha256")
    if not url:
        return ("error", f"{record}: no url")
    if not upstream_name:
        return ("error", f"{record}: no file field (run backfill_file_field.py first)")

    filename = domains.payload_filename(name, version, arch, upstream_name)
    destination = out_dir / kind / name / filename

    if source == "payload":
        # 从我们自己的存储（Bottle / Deps 的 Release）取，不再打扰上游。
        # 香港镜像站用它同步：链路是 香港→GitHub，与大陆出口无关。
        url = domains.payload_url(kind, name, filename)

    if destination.exists() and not overwrite:
        if sha256_of(destination) == sha:
            return ("skip", str(destination))
        # 内容不对就重下：磁盘上这份是坏的，留着只会让人以为已经同步好了
        destination.unlink()

    problem = fetch(url, destination)
    if problem:
        return ("error", f"{destination}: {problem}")

    actual = sha256_of(destination)
    if actual != sha:
        destination.unlink()
        return ("error", f"{destination}: sha256 mismatch (want {sha[:12]}, got {actual[:12]})")

    return ("ok", str(destination))


def main():
    parser = argparse.ArgumentParser(description="Fetch and lay out 4.0 payloads.")
    parser.add_argument("--infosource", required=True, type=Path,
                        help="path to a checkout of MacWaveOrg/infosource")
    parser.add_argument("--out", required=True, type=Path,
                        help="output tree; its bottle/ and deps/ subdirs are what a mirror serves")
    parser.add_argument("--kinds", default="bottle,deps",
                        help="comma separated: bottle, deps (default: both)")
    parser.add_argument("--only", default="",
                        help="comma separated package/dependency names to limit the run")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--overwrite", action="store_true",
                        help="re-download even when the file is already correct")
    parser.add_argument("--source", choices=("upstream", "payload"), default="upstream",
                        help="upstream: fetch from the url recorded in the index (CI); "
                             "payload: fetch from our own Release/mirror (a mirror box)")
    args = parser.parse_args()

    if not (args.infosource / "pkg").is_dir():
        print(f"🌊 Error: {args.infosource} does not look like the infosource repository.")
        return 1

    wanted_kinds = {kind.strip() for kind in args.kinds.split(",") if kind.strip()}
    only = {name.strip() for name in args.only.split(",") if name.strip()}

    jobs = [job for job in records(args.infosource)
            if job[0] in wanted_kinds and (not only or job[2] in only)]

    if not jobs:
        print("🌊 Nothing to do: no matching records.")
        return 0

    print(f"🌊 {len(jobs)} artifact(s) → {args.out}")

    counts = {"ok": 0, "skip": 0, "error": 0}
    failures = []

    with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for status, detail in pool.map(
                lambda job: sync_one(job, args.out, args.overwrite, args.source), jobs):
            counts[status] += 1
            if status == "error":
                failures.append(detail)
            elif status == "ok":
                print(f"  ↓ {detail}")

    print(f"\n🌊 fetched {counts['ok']}, already present {counts['skip']}, failed {counts['error']}")

    for detail in failures:
        print(f"  ❌ {detail}")

    if counts["error"]:
        print("🌊 Fix the failures above; a missing or unverified file must not reach a mirror.")
        return 1

    print(f"🌊 Mirror root: {args.out}")
    print(f"🌊   MACWAVE_BOTTLE_DOMAIN=<该目录对外地址>/bottle")
    print(f"🌊   MACWAVE_DEPS_DOMAIN=<该目录对外地址>/deps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
