#!/usr/bin/env python3

# build_versions_index.py
#
# 为「列出版本 / 列出软件包」生成镜像自备的清单。
#
# 为什么需要：设了 MACWAVE_API_DOMAIN 之后，客户端不再问 api.github.com，而是读
#   <api>/pkg/pkginfo_<架构>/versions           一行一个包名
#   <api>/pkg/pkginfo_<架构>/<包名>/versions     一行一个版本记录文件名（_jq@1.8.2）
# infosource 仓库里没有这两类文件 —— 它们本来由 GitHub 的 contents 接口动态算出。
#
# 关键设计：**只列镜像里真实存在的产物**。索引里有 12 条记录按设计或缺陷拿不到产物
# （test_001 上游已删、ldid 校验值不符等）。若把它们也列进去，用户执行 `wave install ldid`
# 会解析出一个装不上的版本，下载阶段才 404 —— 报错位置离原因太远。宁可让它「没有这个版本」。
#
# 用法：
#   python3 scripts/build_versions_index.py \
#       --infosource /opt/macwaveorg/infosource \
#       --mirror /www/wwwroot/mirror.repohub.top/MacWave

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR.parent / "lib"))

import domains  # noqa: E402
from sync_payloads import read_record, records  # noqa: E402

# 索引里两个顶层目录，以及各自的架构子目录前缀。注意 deps 侧叫 depsinfo_，
# 与 bottle 侧的 pkginfo_ 不同名 —— 这两处写错就会去不存在的路径上写文件。
KIND_LAYOUT = {
    "bottle": ("pkg", "pkginfo"),
    "deps": ("deps", "depsinfo"),
}


def version_entry_path(infosource, kind, arch):
    # <infosource>/pkg/pkginfo_arm64、<infosource>/deps/depsinfo_arm64
    # 同时也是对外暴露的路径，所以清单直接写在这里。
    root, prefix = KIND_LAYOUT[kind]
    return infosource / root / f"{prefix}_{arch}"


def collect(infosource, mirror):
    # 返回 {(kind, arch): {包名: [记录文件名, ...]}}
    tree = {}
    missing = []

    for kind, arch, name, version, record in records(infosource):
        sha, url, upstream_name = read_record(record)
        if not sha or not url or not upstream_name:
            missing.append(f"{record}（记录字段不全）")
            continue

        filename = domains.payload_filename(name, version, arch, upstream_name)
        if not (mirror / kind / name / filename).is_file():
            missing.append(f"{record}（镜像里没有 {kind}/{name}/{filename}）")
            continue

        tree.setdefault((kind, arch), {}).setdefault(name, []).append(record.name[1:])

    return tree, missing


def main():
    parser = argparse.ArgumentParser(
        description="Generate the versions lists that a mirror has to serve.")
    parser.add_argument("--infosource", required=True, type=Path,
                        help="path to a checkout of MacWaveOrg/infosource (written in place)")
    parser.add_argument("--mirror", required=True, type=Path,
                        help="mirror root; its bottle/ and deps/ subdirs decide what gets listed")
    args = parser.parse_args()

    if not (args.infosource / "pkg").is_dir():
        print(f"🌊 Error: {args.infosource} does not look like the infosource repository.")
        return 1
    if not (args.mirror / "bottle").is_dir():
        print(f"🌊 Error: {args.mirror} does not look like a mirror root (no bottle/).")
        return 1

    tree, missing = collect(args.infosource, args.mirror)

    # 先清掉旧文件，再写新的 —— 顺序不能反。镜像里删掉的产物必须同时从清单里消失，
    # 否则客户端会拿到一个指向已删除文件的版本号，直到下载阶段才 404。
    # 这一步也要在「镜像为空」之前做：空镜像的正确结果就是「一个都没有」，
    # 而不是保留上一次的清单。
    for kind, arch in sorted({(kind, arch) for kind, arch, _, _, _ in records(args.infosource)}):
        directory = version_entry_path(args.infosource, kind, arch)
        if not directory.is_dir():
            continue
        for stale in directory.glob("*/versions"):
            stale.unlink()
        (directory / "versions").unlink(missing_ok=True)

    if not tree:
        print("🌊 Nothing to list: the mirror has no payloads. Lists were cleared.")
        return 1

    for (kind, arch), packages in sorted(tree.items()):
        directory = version_entry_path(args.infosource, kind, arch)
        directory.mkdir(parents=True, exist_ok=True)

        (directory / "versions").write_text(
            "".join(f"{name}\n" for name in sorted(packages)))

        for name, entries in packages.items():
            # 包目录一定已存在（记录就在里面），但从空镜像重建时未必，统一补一次。
            (directory / name).mkdir(parents=True, exist_ok=True)
            (directory / name / "versions").write_text(
                "".join(f"{entry}\n" for entry in sorted(entries)))

        total = sum(len(v) for v in packages.values())
        print(f"  {kind}/{arch}: {len(packages)} 个名字, {total} 条版本")

    if missing:
        print(f"\n🌊 {len(missing)} 条记录未列入（镜像里没有对应产物）：")
        for line in missing:
            print(f"  - {line}")

    print("\n🌊 Done. 现在可以把 MACWAVE_API_DOMAIN 指向这个 infosource 的对外地址。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
