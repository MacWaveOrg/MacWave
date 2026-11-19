#!/usr/bin/env python3

# signature.py

# GPG 验签的**唯一实现**，也是「签名相关的东西放哪」的唯一定义。
#
# 为什么现在就写：发布流程从 2026-12-01 起要求每个 Release 带 `SHA256SUMS` 与
# `SHA256SUMS.asc`（见 docs/RELEASE-CHECKLIST.md）。但**更早发布的版本没有签名对**，
# 客户端不能一上来就强制验 —— 那会把所有历史版本判成失败。所以这里先把「能不能验、
# 拿什么验、怎么验」定下来，接入下载路径留到签名对普及之后。
#
# 公钥在哪：仓库 `Keys/`，安装树 `<base_dir>/Keys/`，同一份。`Keys/` 列在
# scripts/assets.txt 里，随安装清单下发，所以装过 MacWave 的机器本地就有公钥 ——
# 验签不依赖「再去官网下载一个公钥」，那一步恰恰是最容易被换掉的。
#
# 可能的形态（两把）：轮换期间目录里同时有旧钥与新钥，**任意一把验通即可**。
# 这与「换钥那天，用户手里的旧安装还能验新资产」是同一件事。
#
# 与 net/tls.py 的分工：TLS 管「这条连接是跟谁在说话」，这里管「这批字节是谁签的」。
# 两者都只在**已经拿到字节之后**才可能失败，也都要给出「下一步该做什么」。

import os
import shutil
import subprocess
import sys
import tempfile

SUMS_NAME = "SHA256SUMS"
SIG_NAME = "SHA256SUMS.asc"

# 信任的发布签名钥指纹（40 位十六进制，大写、无空格；短写只用于显示）。
#
# 为什么必须有这一条：`Keys/` 是**从网络**取回来的（随安装清单下发）。只按「目录里
# 有没有 .asc」判断，等于「谁能改资产，谁就能换公钥」—— 整条信任链就是空的。
# 指纹写在代码里，改动它会出现在 diff 里，无法静默替换。
#
# **在真正接上验签之前，这里是空的**：空 = 不筛（只验「签名与公钥对得上」）。
# 接通那天填上真实指纹，`public_keys()` 就只返回白名单里的钥匙。
PINNED_FINGERPRINTS = (
    # 当前签名钥（2026-11-19 生成，Ed25519，sign-only）。公钥见 Keys/D0E229FB.asc。
    "7220E218395DE865AACC339167F14E52D0E229FB",
    # 轮换期在这里加新钥，旧钥**先留着**：已发布的旧版本仍要用它验。
)

# 安装树里公钥目录的名字（仓库里同名）。改这里就要改 scripts/assets.txt 与
# lib/install.sh 的目录准备（scripts/structure_test.sh 会拦）。
KEYS_DIR_NAME = "Keys"

# 验签结果。用字面量而不是 Enum：这个模块会被「什么都没装」的解释器导入，
# 少一个 import 就少一种失败。
OK = "ok"                        # 签名有效，且签的正是这份数据
NO_KEYS = "no-keys"              # Keys/ 里没有可用公钥（安装树不完整 / 用户删了）
NO_GPG = "no-gpg"                # 本机没有 gpg（验不了，不等于签名坏）
BAD_SIGNATURE = "bad-signature"  # 有公钥、验了，但不通过：这是要报出去的
NO_SIGNATURE = "no-signature"    # 这个版本压根没带签名（2026-12-01 之前的正常情况）

_HINT = {
    OK: ["the download matches the signature"],
    NO_KEYS: ["no public keys found: reinstall MacWave to restore them",
              "manual check: gpg --verify SHA256SUMS.asc SHA256SUMS"],
    NO_GPG: ["gpg is not installed, so the signature cannot be checked",
             "install it (Homebrew: brew install gnupg) if you want the check",
             "this is not a signature failure"],
    BAD_SIGNATURE: ["do not install this download: the signature does not match",
                    "retry once; if it persists, the mirror or the asset was tampered with",
                    "compare with the official Release page before trusting it"],
    NO_SIGNATURE: ["this release carries no signature pair (releases before 2026-12-01)",
                   "verify the SHA256 sums by hand if you want extra assurance"],
}


def keys_dir(base_dir):
    """安装树里的公钥目录（仓库里同名，见 Keys/README.md）。"""
    return os.path.join(str(base_dir), KEYS_DIR_NAME)


def public_keys(base_dir):
    """`Keys/` 下**可信的**公钥文件，按名字排序。

    只认 .asc / .gpg / .pub：目录里的 README.md 是给人看的，不该被当成钥匙，
    也不该因为它的存在就让「有没有公钥」判断出错。

    `PINNED_FINGERPRINTS` 非空时，只返回指纹在白名单里的钥匙 —— 这是引导环节
    唯一的锚点：`Keys/` 本身是网络取回来的，不筛就等于没验。
    """
    directory = keys_dir(base_dir)
    if not os.path.isdir(directory):
        return []
    found = []
    for name in sorted(os.listdir(directory)):
        if name.startswith("."):
            continue
        if name.lower().endswith((".asc", ".gpg", ".pub")):
            path = os.path.join(directory, name)
            if os.path.isfile(path) and os.path.getsize(path) > 0:
                found.append(path)
    if not PINNED_FINGERPRINTS:
        return found

    pinned = {fingerprint.upper() for fingerprint in PINNED_FINGERPRINTS}
    trusted = []
    for path in found:
        if fingerprints_of(path) & pinned:
            trusted.append(path)
    return trusted


def fingerprints_of(key_path, timeout=10):
    """一个公钥文件里的全部指纹（大写）；读不出来返回空集合。"""
    if not gpg_available():
        return set()
    workdir = tempfile.mkdtemp(prefix="macwave-gpg-fpr-")
    try:
        environment = dict(os.environ)
        environment["GNUPGHOME"] = workdir
        environment["LC_ALL"] = "C"
        listed = subprocess.run(
            ["gpg", "--batch", "--no-tty", "--with-colons", "--import-options",
             "show-only", "--import", str(key_path)],
            capture_output=True, text=True, env=environment, timeout=timeout)
        found = set()
        for line in listed.stdout.splitlines():
            if line.startswith("fpr:"):
                parts = line.split(":")
                if len(parts) > 9:
                    found.add(parts[9].strip().upper())
        return found
    except (OSError, subprocess.SubprocessError):
        return set()
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def gpg_available():
    return shutil.which("gpg") is not None


def verify_detached(data, signature, base_dir, timeout=30):
    """验一次 detached 签名。返回 (结果, 说明行列表)。

    data / signature 可以是 bytes（验下载到内存的内容），也可以是路径（验盘上的
    文件）。公钥取自 `<base_dir>/Keys/`。

    **不抛异常**：验签失败是「这批字节不可信」，不是程序出错，调用方要能按结果
    决定是拒绝安装还是只警告。真正的编程错误（参数不对）才走 TypeError。
    """
    if signature in (None, b"", ""):
        return NO_SIGNATURE, list(_HINT[NO_SIGNATURE])

    keys = public_keys(base_dir)
    if not keys:
        return NO_KEYS, list(_HINT[NO_KEYS])
    if not gpg_available():
        return NO_GPG, list(_HINT[NO_GPG])

    workdir = tempfile.mkdtemp(prefix="macwave-gpg-")
    try:
        # 临时钥匙环：绝不碰用户自己的 ~/.gnupg —— 那里可能有同名不同指纹的钥匙，
        # 也可能因为 pinentry 弹窗把无人值守的安装卡死。
        environment = dict(os.environ)
        environment["GNUPGHOME"] = workdir
        environment["LC_ALL"] = "C"      # 报错文本认英文，下面要按关键词判断

        data_path = _materialize(data, workdir, "payload")
        sig_path = _materialize(signature, workdir, "payload.asc")

        for key in keys:
            imported = subprocess.run(
                ["gpg", "--batch", "--no-tty", "--quiet", "--import", key],
                capture_output=True, text=True, env=environment, timeout=timeout)
            if imported.returncode != 0:
                # 一把钥匙坏了不该让另一把失去机会：继续试下一把。
                continue

        verified = subprocess.run(
            ["gpg", "--batch", "--no-tty", "--verify", sig_path, data_path],
            capture_output=True, text=True, env=environment, timeout=timeout)

        if verified.returncode == 0:
            return OK, list(_HINT[OK])

        detail = (verified.stderr or verified.stdout or "").strip().splitlines()
        tail = detail[-3:] if detail else ["gpg --verify failed without output"]
        return BAD_SIGNATURE, list(_HINT[BAD_SIGNATURE]) + tail
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _materialize(value, workdir, name):
    """bytes / 路径 → 盘上的路径。

    两种输入形态都要支持：清单小、可以整个读进内存；资产可能有上百 MB，只能是路径。
    写出去的临时文件跟着 workdir 一起删，不需要单独记账。
    """
    if isinstance(value, bytes):
        path = os.path.join(workdir, name)
        with open(path, "wb") as stream:
            stream.write(value)
        return path
    return str(value)


def explain(result):
    """给 CLI 用的一句结论（英文，终端文案的约定）。"""
    return {
        OK: "signature verified",
        NO_KEYS: "cannot verify: no public keys in Keys/",
        NO_GPG: "cannot verify: gpg is not installed",
        BAD_SIGNATURE: "signature verification failed",
        NO_SIGNATURE: "this release carries no signature",
    }.get(result, f"unknown verification result: {result}")


if __name__ == "__main__":
    # 手工验一次：python3 net/signature.py <数据文件> <签名文件> <base_dir>
    if len(sys.argv) != 4:
        print("usage: signature.py <data> <signature> <base_dir>", file=sys.stderr)
        raise SystemExit(2)
    outcome, lines = verify_detached(sys.argv[1], sys.argv[2], sys.argv[3])
    print(f"🌊 {explain(outcome)}")
    for line in lines:
        print(f"🌊   {line}")
    raise SystemExit(0 if outcome == OK else 1)
