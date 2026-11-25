#!/usr/bin/env python3

# prepare_bottle.py
# 把一个上游原样搬运的产物重打成「构建时就重定位好」的 prebuilt 产物。
#
# 为什么需要它：Deps / 一部分 Bottle 的字节与上游一致（conda、上游 release），
# 它们的引用是 `@rpath/<名>` + `LC_RPATH=@loader_path/../lib/` —— 装完之后库在
# `deps/<名>/<名>@<版本>/lib/` 下，那串 rpath 解析不到，所以客户端必须现场改写。
# 本脚本在**服务端**把这一步做掉，产物里就是显式的 `@loader_path/../../../deps/...`，
# 客户端只剩「下载 + 解包」。
#
# 布局必须是运行时布局（与 Ports/scripts/relocate_stage.sh 同一套要求）：
#
#     <stage>/bin/<包名>@<版本>/...            软件包自己那一棵
#     <stage>/deps/<名>/<名>@<版本>/...        依赖（含它自己的依赖）
#
# 于是相对路径在用户机上同样成立（`wave basedir --set` 也不受影响：全相对）。
#
# 用法：
#   python3 scripts/prepare_bottle.py --kind deps --name libidn2 --version 2.3.8
#   python3 scripts/prepare_bottle.py --kind pkg  --name htop   --version 3.5.3 --arch arm64
#
# 只下载、重打、打印结果；**不上传、不改索引**。打印出来的就是需要写进记录的三行：
#   sha256、file、relocated: "loader_path"（外加 install: "tree"）。
#
# 索引记录默认从本地 infosource 检出读（--infosource 指定，默认 ~/Projects/MacWaveOrg/infosource），
# 产物默认从镜像站取（与客户端同一组环境变量）。

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELOCATE = REPO / "scripts" / "relocate_rpath.py"
DEFAULT_INFOSOURCE = Path.home() / "Projects" / "MacWaveOrg" / "infosource"
MARKER = "_RELOCATED"


# -------------------- 索引 --------------------

def record_path(infosource, kind, arch, name, version):
    if kind == "pkg":
        return infosource / "pkg" / f"pkginfo_{arch}" / name / f"_{name}@{version}"
    return infosource / "deps" / f"depsinfo_{arch}" / name / f"_{name}@{version}"


def parse_fields(text):
    # infosource 的简易 DSL，与客户端 pkg/pkginfohelper 的 parse_common_fields 同一套规则：
    # 行内第一个引号前有 `字段:` 就开一个新字段；否则这一行是上一个字段的续行
    # （`deps:` 就是这样跨多行的，漏了续行会把依赖边丢掉）。
    fields = {}
    current = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        head = line.split('"', 1)[0]
        if ':' in head:
            current = head.split(':', 1)[0].strip()
            values = [part.strip('"') for part in line[len(head):].split('"') if part.strip('"')]
            fields.setdefault(current, [])
            fields[current].extend(values)
        elif current and line.startswith('"'):
            fields[current].append(line.strip('"'))
    return {key: "\n".join(values) for key, values in fields.items()}


def read_record(infosource, kind, arch, name, version):
    path = record_path(infosource, kind, arch, name, version)
    if not path.is_file():
        sys.exit(f"🌊 Error: no index record at {path}")
    return parse_fields(path.read_text(encoding="utf-8"))


def dep_list(fields):
    raw = fields.get("deps", "")
    return [line.strip() for line in raw.splitlines() if line.strip()]


# -------------------- 取产物 --------------------

def domain(kind):
    name = "MACWAVE_BOTTLE_DOMAIN" if kind == "pkg" else "MACWAVE_DEPS_DOMAIN"
    base = os.environ.get(name, "").rstrip("/")
    if not base:
        sys.exit(f"🌊 Error: {name} is not set; point it at a mirror or leave the tool to "
                 f"download from the record's url (not implemented yet)")
    return base


def stored_name(name, version, arch, filename):
    # 客户端存进 Bottle/Deps 的名字：<名>@<版本>.<架构><扩展名>
    for marker in (".tar.xz", ".tar.bz2", ".tar.gz", ".conda", ".zip"):
        if filename.endswith(marker):
            ext = marker
            break
    else:
        ext = os.path.splitext(filename)[1]
    return f"{name}@{version}.{arch}{ext}"


def fetch(kind, name, version, arch, fields, work):
    filename = fields.get("file")
    if not filename:
        sys.exit(f"🌊 Error: record for {name}@{version} has no file field")
    url = f"{domain(kind)}/{name}/{stored_name(name, version, arch, filename)}"
    out = work / filename
    print(f"🌊 fetching {url.split('repohub.top')[-1]}")
    if subprocess.run(["curl", "-fsSL", "--http1.1", "--retry", "3", "-o", str(out), url]).returncode:
        sys.exit(f"🌊 Error: download failed: {url}")
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    expect = fields.get("sha256", "")
    if expect and digest != expect:
        sys.exit(f"🌊 Error: sha256 mismatch for {name}@{version}\n"
                 f"   expected {expect}\n   got      {digest}")
    return out, filename


# -------------------- 解包 / 打包 --------------------

def extract(path, dest):
    name = path.name
    if name.endswith((".tar.xz", ".tar.bz2", ".tar.gz", ".tar.zst")):
        with tarfile.open(path) as archive:
            archive.extractall(dest)
        return
    if name.endswith(".conda"):
        # .conda = zip 里装着 pkg-*.tar.zst（Python 3.14+ 的 compression.zstd 能解）
        inner = dest.parent / (dest.name + "-conda")
        inner.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path) as archive:
            archive.extractall(inner)
        payload = next(p for p in inner.iterdir() if p.name.endswith(".tar.zst"))
        rc = subprocess.run(["tar", "--zstd", "-xf", str(payload), "-C", str(dest)]).returncode
        if rc != 0:
            sys.exit(f"🌊 Error: cannot extract {payload.name} (needs bsdtar with zstd)")
        return
    shutil.copy2(path, dest / path.name)


def repack(version_dir, out_file):
    # 以版本目录的内容为根打包：客户端解包后就是 <版本目录>/bin/...、<版本目录>/lib/...
    with tarfile.open(out_file, "w:bz2") as archive:
        for entry in sorted(version_dir.iterdir()):
            archive.add(entry, arcname=entry.name)
    return hashlib.sha256(out_file.read_bytes()).hexdigest()


# -------------------- 主流程 --------------------

def stage_target(stage, kind, name, version):
    if kind == "pkg":
        return stage / "bin" / f"{name}@{version}"
    return stage / "deps" / name / f"{name}@{version}"


def prepare(infosource, kind, name, version, arch, out_dir, keep):
    work = Path(tempfile.mkdtemp(prefix=f"prepare-{name}-"))
    try:
        stage = work / "stage"
        # 1. 先把依赖闭包摆好：重定位要按「运行时布局」算相对路径，
        #    缺了兄弟依赖就既算不出路径、也判断不了 @rpath 能不能解析。
        todo = [(kind, name, version)]
        seen = set()
        while todo:
            current_kind, current_name, current_version = todo.pop()
            key = (current_kind, current_name, current_version)
            if key in seen:
                continue
            seen.add(key)
            fields = read_record(infosource, current_kind, arch, current_name, current_version)
            target = stage_target(stage, current_kind, current_name, current_version)
            target.mkdir(parents=True, exist_ok=True)
            payload, _ = fetch(current_kind, current_name, current_version, arch, fields, work)
            extract(payload, target)
            for ref in dep_list(fields):
                dep_name, _, dep_version = ref.partition("@")
                todo.append(("deps", dep_name, dep_version))

        # 2. 重定位整棵 stage，并确认真的位置无关了
        target = stage_target(stage, kind, name, version)
        print(f"🌊 relocating {len(seen)} artifact(s) in the staging tree")
        rc = subprocess.run([sys.executable, str(RELOCATE), str(stage)])
        if rc.returncode != 0:
            sys.exit("🌊 Error: relocation failed; nothing was written")
        rc = subprocess.run([sys.executable, str(RELOCATE), str(stage), "--check"])
        if rc.returncode != 0:
            sys.exit("🌊 Error: staging tree is still not position-independent")

        # 3. 打标记 + 只重打目标产物（依赖由它们自己那一轮处理）
        (target / MARKER).write_text("@loader_path\n", encoding="utf-8")
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / f"{name}@{version}.{arch}.tar.bz2"
        digest = repack(target, out_file)

        print()
        print("🌊 Done. Write these into the record (and upload the archive):")
        print(f"   file:  \"{out_file.name}\"")
        print(f"   sha256: \"{digest}\"")
        print('   relocated: "loader_path"')
        print('   install: "tree"        # 重打后按整树解包，命令在 <版本目录>/bin/ 下')
        print(f"   archive: {out_file}")
        if keep:
            print(f"   staging: {stage}")
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Repack an upstream payload into a prebuilt artifact")
    parser.add_argument("--kind", choices=("pkg", "deps"), required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", default="arm64", choices=("arm64", "amd64"))
    parser.add_argument("--infosource", default=str(DEFAULT_INFOSOURCE))
    parser.add_argument("--out", default=str(Path.cwd() / "prebuilt"))
    parser.add_argument("--keep", action="store_true", help="keep the staging tree for inspection")
    args = parser.parse_args()

    if not RELOCATE.is_file():
        sys.exit(f"🌊 Error: {RELOCATE} not found")
    prepare(Path(args.infosource), args.kind, args.name, args.version,
            args.arch, Path(args.out), args.keep)


if __name__ == "__main__":
    main()
