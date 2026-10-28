#!/usr/bin/env python3

# publish_payloads.py
# 把 sync_payloads.py 生成的暂存目录发布到 Bottle / Deps 仓库的 Release。
#
# 约定（与 lib/domains.py 的 payload_url 一一对应）：
#
#   <包名>/<包名>@<版本>.<架构><扩展名>
#   ↓
#   https://github.com/MacWaveOrg/Bottle/releases/download/<包名>/<文件名>
#
# 所以 **tag = 包名**，一个包一个 Release，架构靠文件名区分（arm64 / amd64 同名同版本）。
#
# 三条不可违反的规则：
#   1. 只增不删。旧版本必须一直可下载 —— 多版本共存是 MacWave 的设计前提，
#      删掉一个资产就等于让 `wave install <包>@<旧版本>` 永久失效。
#   2. 已存在且大小相同的资产跳过，不重复上传（省时间也省配额）。
#   3. 校验在下载阶段就做过了（sync_payloads.py 对 sha256），这里只负责发布。
#
# 用法：
#   python3 scripts/publish_payloads.py --staging ./mirror            # 报告，不发布
#   python3 scripts/publish_payloads.py --staging ./mirror --write    # 真正上传
#   python3 scripts/publish_payloads.py --staging ./mirror --write --only jq
#
# 需要 gh CLI 已登录（凭据要有目标仓库的 contents:write）。

import argparse
import json
import subprocess
import sys
from pathlib import Path

KIND_REPO = {
    "bottle": "MacWaveOrg/Bottle",
    "deps": "MacWaveOrg/Deps",
}


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}\n{result.stderr.strip()}")
    return result


def existing_assets(repo, tag):
    # Release 不存在时 gh 返回 404，这里当作「空」而不是错误。
    result = run(["gh", "api", f"repos/{repo}/releases/tags/{tag}"], check=False)
    if result.returncode != 0:
        return None
    try:
        return {asset["name"]: asset["size"] for asset in json.loads(result.stdout).get("assets", [])}
    except ValueError:
        return None


def ensure_release(repo, tag, write):
    # 一个包一个 Release。标题与说明刻意朴素：这是数据仓库，不是发布公告页。
    assets = existing_assets(repo, tag)
    if assets is not None:
        return assets, False

    if not write:
        return {}, True

    run(["gh", "release", "create", tag,
         "--repo", repo,
         "--title", tag,
         "--notes", f"Payloads for `{tag}`.\n\n"
                    f"Served to MacWave 4.0 clients as "
                    f"`<MACWAVE_BOTTLE_DOMAIN or MACWAVE_DEPS_DOMAIN>/{tag}/<file>`.\n"
                    f"Assets are byte-for-byte copies of the upstream artifacts; "
                    f"their checksums are recorded in the `infosource` index.\n"
                    f"Nothing here is ever replaced: a rebuild gets a new version suffix."])
    return {}, True


def publish(kind, staging, write, only):
    root = staging / kind
    if not root.is_dir():
        return 0, 0, []

    repo = KIND_REPO[kind]
    uploaded = 0
    skipped = 0
    problems = []

    for package_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        package = package_dir.name
        if only and package not in only:
            continue

        files = sorted(path for path in package_dir.iterdir() if path.is_file())
        if not files:
            continue

        assets, created = ensure_release(repo, package, write)
        if created:
            print(f"  + release {repo}:{package}")
        assets = assets or {}

        for path in files:
            size = path.stat().st_size
            if path.name in assets:
                # 同名同大小视为已发布。内容正确性由 sync 阶段的 sha256 保证。
                if assets[path.name] == size:
                    skipped += 1
                    continue
                problems.append(f"{repo}:{package}/{path.name} exists with a different size; "
                                f"assets are immutable, publish a new version suffix instead")
                continue

            if not write:
                print(f"  ≈ would upload {repo}:{package}/{path.name} ({size} bytes)")
                uploaded += 1
                continue

            run(["gh", "release", "upload", package, str(path), "--repo", repo, "--clobber"])
            print(f"  ↑ {repo}:{package}/{path.name} ({size} bytes)")
            uploaded += 1

    return uploaded, skipped, problems


def main():
    parser = argparse.ArgumentParser(description="Publish payloads to GitHub Releases.")
    parser.add_argument("--staging", required=True, type=Path,
                        help="directory produced by sync_payloads.py")
    parser.add_argument("--write", action="store_true", help="actually create releases and upload")
    parser.add_argument("--kinds", default="bottle,deps")
    parser.add_argument("--only", default="", help="comma separated package names")
    args = parser.parse_args()

    kinds = [kind.strip() for kind in args.kinds.split(",") if kind.strip()]
    only = {name.strip() for name in args.only.split(",") if name.strip()}

    total_uploaded = total_skipped = 0
    all_problems = []

    for kind in kinds:
        uploaded, skipped, problems = publish(kind, args.staging, args.write, only)
        total_uploaded += uploaded
        total_skipped += skipped
        all_problems.extend(problems)

    verb = "uploaded" if args.write else "would upload"
    print(f"\n🌊 {verb} {total_uploaded}, already present {total_skipped}")

    for problem in all_problems:
        print(f"  ❌ {problem}")

    if all_problems:
        return 1
    if not args.write and total_uploaded:
        print("🌊 Re-run with --write to publish.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
