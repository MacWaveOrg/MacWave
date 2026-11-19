# Keys/ —— 公钥（只放公钥）

这个目录里放 MacWave 发布签名用的**公钥**，仓库与安装树里是同一份：

```
仓库            Keys/*.asc   Keys/macwave-rsa.pub.pem
安装树          <base_dir>/Keys/*.asc   <base_dir>/Keys/macwave-rsa.pub.pem
```

`Keys/` 列在 `scripts/assets.txt` 里，所以它随安装清单一起下发 —— 装了 MacWave 的人
手里就有验签需要的公钥，不必再去官网另找一遍。

两把钥、两条链，别混：

| 文件 | 算法 | 谁验 | 验什么 |
| --- | --- | --- | --- |
| `D0E229FB.asc` | OpenPGP（Ed25519） | **人**：`gpg --verify SHA256SUMS.asc SHA256SUMS` | Release 附件的清单 |
| `macwave-rsa.pub.pem` | RSA-3072（PEM） | **机器**：`openssl dgst -sha256 -verify` | `latest.toml.sig` |

为什么要两把：装机/自更新时手上只有 bash + curl + openssl，而 macOS 自带的
openssl 是 LibreSSL，验不了 OpenPGP。所以自动路径走 RSA，GPG 那把留给人工核对。

## 约定

- **只放公钥。** 私钥绝不进仓库、不进 CI、不进 Actions secret；签名只在本机做，
  CI 只负责验（见 `docs/RELEASE-CHECKLIST.md` 的「签名」一节）。
- **一钥一文件，armored（`-----BEGIN PGP PUBLIC KEY BLOCK-----`）。** 文件名用
  指纹后 8 位或角色名，例如 `7A1B2C3D.asc` / `release-2026.asc`。这样同一目录可以
  同时放着「当前签名钥」和「下一把」。
- **可能有两把。** 轮换期间新旧公钥都在这里：旧钥继续验已发布的版本，新钥验之后的
  版本。验签程序对**任意一把**验通即可 —— 这也是把公钥随安装树下发的原因：换钥那天
  用户手里的旧安装仍然验得了新资产。
- 本 `README.md` 会一起装进安装树，但它不参与验签；验签只看 `*.asc` / `*.gpg`。

## 验签涉及的文件（预留）

发布资产的签名对是「清单 + 清单的签名」：

| 名称 | 说明 | 代码里的常量 |
| --- | --- | --- |
| `SHA256SUMS` | 该 tag 下全部资产的 sha256 清单 | `net/signature.py` 的 `SUMS_NAME` |
| `SHA256SUMS.asc` | 上面那份清单的 detached 签名 | `net/signature.py` 的 `SIG_NAME` |

## 指纹白名单（引导环节）

`Keys/` 是随安装清单从**网络**取回来的。只按「目录里有没有 `.asc`」判断，就等于
「谁能改资产，谁就能换公钥」—— 整条信任链是空的。所以真正的锚点是
`net/signature.py` 的 `PINNED_FINGERPRINTS`：一份写在代码里、改动会出现在 diff 里的
指纹白名单。白名单非空时，`public_keys()` 只返回指纹命中的钥匙。

现在填的就是本目录这把钥：

```
7220E218395DE865AACC339167F14E52D0E229FB    Ed25519, sign-only, 2026-11-19 生成
UID：MacWave Release <macwaveorg@outlook.com>
公钥文件：D0E229FB.asc
```

轮换时在这里加新指纹、**旧指纹先留着**（已发布的旧版本还要用它验），等旧版本退场
再删。填之前请先把指纹发在两处以上（本仓库、README、官网、Release 正文）。

## RSA 公钥（机器验签）

```
macwave-rsa.pub.pem    RSA-3072, 2026-11-19 生成, 无到期日（只能靠轮换）
标识（DER 的 sha256）：8a32ff7475a1908365b8da7d50b5290a462fa639037850020e08a6fb576ebfc0
私钥：~/MD/密钥/private/macwave-rsa.key（口令保护，永不入库）
```

`lib/install.sh` 与 `lib/selfupdate.sh` 里**各内嵌一份同样的 PEM**：这两个脚本是被
curl 下来直接执行的，没法 source，也就没法先去读一个文件再验。内嵌的那份由

```bash
python3 scripts/embed_rsa_pub.py          # 公钥变了就跑一次
python3 scripts/embed_rsa_pub.py --check  # 只检查是否同步（signature_test 会跑）
```

维护。**不要手工改脚本里那段** —— 少一个字符就是验不过，而验不过只是警告，很容易
上线之后才发现。轮换 RSA 钥 = 生成新钥 → 覆盖 `macwave-rsa.pub.pem` → 跑一次
`embed_rsa_pub.py` → 提交。

验签时的公钥优先级（`mw_trusted_pub()`）：`MACWAVE_RSA_PUB`（一个 PEM 路径，运维/
测试用）→ 脚本内嵌的那份。**故意不去读 `<base_dir>/Keys/`**：那份和 `latest.toml`
走同一个下载通道，能换数据的人也能换公钥，拿它验等于自证。安装树里这份是给人和
外部工具用的。

## 4.4 的实验期策略：验不过只警告

4.4 起客户端会做三件事（`lib/install.sh`、`lib/selfupdate.sh`、`update_commands.template.sh`）：

| 检查 | 依赖什么 | 不符时 |
|---|---|---|
| `latest.toml` 的签名 | 脚本内嵌的 RSA 公钥（可用 `MACWAVE_RSA_PUB` 覆盖） | **警告** |
| `update_commands.sh` 的哈希 | `latest.toml` 的 `update_commands_sha256` | **警告** |
| 每个下载文件的哈希 | `want <路径> <0\|1> <sha256>` 的第三列 | **警告** |

- 设 `MACWAVE_WANT_HASHES=1` 才会逐文件校验（客户端在拿到 `update_commands_sha256`
  时自己置上）；不设就是 4.4 之前的行为。
- 设 `MACWAVE_STRICT_HASHES=1` 才把「警告」升级成「失败」。**这是未来的默认**，
  现在不设 —— 验签能力要等客户端版本铺开。
- 没有任何哈希/签名时静默放行：2026-12-01 之前的 Release 本来就没有签名对。

验签入口是 `net/signature.py` 的 `verify_detached()`：给它「数据 + 签名」以及这个
目录，它用 `gpg --verify` 对着此处的公钥验一次（用临时 GNUPGHOME，不碰用户自己的
钥匙环）。它目前只服务于**人工核对**；自动路径（`latest.toml.sig`）走的是上面那把
RSA 钥。

`latest.toml.sig` 的校验已经接进两个脚本；`SHA256SUMS.asc` 那条按设计仍由人跑 ——
2026-12-01 之前的 Release 没有签名对，那时强制验签会把所有老版本判成失败。
