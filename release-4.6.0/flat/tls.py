#!/usr/bin/env python3

# tls.py

# TLS 的两件事的唯一实现：
#
#   1. `--skip-ssl`：设一次，全进程生效（下面）
#   2. `MACWAVE_CACERT`：额外的根证书（文件最后一节「证书失败的分诊」也有它的建议）
#
# 后者是前者之外的另一种选择：企业网络里 TLS 被中间设备重签、或自建镜像用私有
# CA 时，把根证书交给我们就够了，不该让人为了连上而把校验整个关掉。
#
# 为什么要有这个模块：这个旗标原先只在 download_file 里读，于是「版本清单」
# `@common`、版本记录、依赖元数据、info / search / latest 这些请求照样校验证书。
# 而自签证书的镜像恰好在**第一个**请求上就失败 —— 旗标等于没写。
#
# 做法是把状态放在模块级，由 wave.py 在分发命令之前设一次（值来自
# cli/common.py 的 parse()）；所有发请求的地方都加 `**tls.request_kwargs()`。
# 这样不会再有「漏了哪一处」。
#
# 为什么分「请求」与「授权」两段：install / upgrade 会先弹一句安全询问，用户
# 答否（或非交互读不到答复）时**不能**跳过校验。若在分发之前就直接打开，
# 那个询问就形同虚设。所以先 configure() 记下「命令行里写了」，
# 真正生效要等 grant()。

import os
import sys

# 名字的唯一来源是 config/envvar.py（同层邻居，只依赖标准库）。
import envvar


RED_BOLD = '\033[1;31m'
RESET = '\033[0m'

# urllib3 是 requests 的依赖，正常安装一定在。但 lib/selfupdate.py 会被测试
# 用「什么都没装」的解释器直接导入，顶层硬导入会让那种调用一并失败；
# 缺了它只是少抑制一条警告，不影响把 verify 关掉。
try:
    import urllib3
    from urllib3.exceptions import InsecureRequestWarning
except ImportError:
    urllib3 = None
    InsecureRequestWarning = None


_requested = False
_enabled = False
_cacert_seen = None     # 上次解析时的原值；None = 还没解析过
_cacert = ""            # 展开后的路径；"" = 没设（用系统证书库）
_cacert_reported = False


CACERT_NAME = envvar.CACERT


def cacert_path():
    """`MACWAVE_CACERT` 的值：展开 ~ 后的绝对路径；没设时返回空字符串。

    设了却不可用（不存在、不是文件、读不了）就**报错退出**，而不是悄悄忽略 ——
    静默忽略的后果是用户以为自己已经信任了那家 CA，实际还在失败，于是他会去
    怀疑 --skip-ssl 没用、怀疑镜像、怀疑网络，唯独不会想到是路径写错了。
    """
    global _cacert_seen, _cacert, _cacert_reported

    raw = (os.environ.get(CACERT_NAME) or "").strip()
    if raw == _cacert_seen:
        return _cacert
    # 原值变了就重新解析（测试会改环境变量；真实进程里只解析一次）
    _cacert_seen = raw
    _cacert_reported = False

    if not raw:
        _cacert = ""
        return _cacert

    path = os.path.abspath(os.path.expanduser(raw))
    problem = None
    if not os.path.exists(path):
        problem = "does not exist"
    elif os.path.isdir(path):
        problem = "is a directory, not a PEM file"
    elif not os.access(path, os.R_OK):
        problem = "is not readable"
    elif os.path.getsize(path) == 0:
        problem = "is empty"

    if problem:
        if not _cacert_reported:
            _cacert_reported = True
            print(f"{RED_BOLD}🌊 Error: {CACERT_NAME} {problem}: {path}{RESET}",
                  file=sys.stderr)
            print(f"{RED_BOLD}🌊 Next      point it at the CA's root certificate in PEM form, "
                  f"e.g. export {CACERT_NAME}=/etc/ssl/corp-root.pem{RESET}", file=sys.stderr)
            print(f"{RED_BOLD}🌊           unset it to go back to the system trust store{RESET}",
                  file=sys.stderr)
        raise SystemExit(1)

    _cacert = path
    return _cacert


def configure(requested):
    """记下是否要求跳过证书校验。返回是否要求。

    结论由 cli/common.py 的 parse() 给出（--skip-ssl 是公共旗标），这里只收结果 ——
    同一条命令行不该在两层里各解析一遍。
    """
    global _requested
    _requested = bool(requested)
    if not _requested:
        # 坏路径要在任何请求之前就报错；被 --skip-ssl 覆盖时不校验 ——
        # 两者同时给时 skip-ssl 优先，此时那个文件根本不会被读到。
        cacert_path()
    return _requested


def requested():
    return _requested


def grant():
    """真正启用。命令行没要求时什么也不做，返回 False。"""
    global _enabled
    if not _requested:
        return False
    _enabled = True
    # 关了校验就会一直刷 InsecureRequestWarning，把真正的报错淹掉
    if urllib3 is not None:
        urllib3.disable_warnings(InsecureRequestWarning)
    return True


def revoke():
    """在询问被拒后撤销请求，避免下游某一处又把校验关掉。"""
    global _requested, _enabled
    _requested = False
    _enabled = False


def enabled():
    return _enabled


def request_kwargs():
    """给 requests 的额外关键字；什么都不用改时是空字典，调用处不需要分支。

    优先级：`--skip-ssl`（不校验）> `MACWAVE_CACERT`（用这家的根证书）>
    系统证书库。三者互斥，都是「这次请求怎么判定对端可信」的同一件事。
    """
    if _enabled:
        return {"verify": False}
    cacert = cacert_path()
    return {"verify": cacert} if cacert else {}


def curl_flags():
    """给 curl 的等价旗标：`-k` 对应 verify=False，`--cacert` 对应 verify=<pem>。"""
    if _enabled:
        return ["-k"]
    cacert = cacert_path()
    return ["--cacert", cacert] if cacert else []


def urlopen_kwargs():
    """给 urllib 的额外关键字：它不认 verify，只能换一个 SSLContext。"""
    import ssl

    if _enabled:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        return {"context": context}

    cacert = cacert_path()
    if cacert:
        # 给了 cafile 之后仍会校验证书链与主机名，只是信任根换成这一份
        return {"context": ssl.create_default_context(cafile=cacert)}
    return {}


# -------------------- 证书失败的分诊 --------------------
#
# 以前这一层对所有的握手失败只说一句「SSL error」，于是四类完全不同的病拿到
# 同一个建议，四种下一步也跟着乱：
#
#   过期            服务端的事，只能等它换证书
#   自签 / 私有 CA  企业网络里很常见，要么信任那家 CA，要么换镜像
#   链不完整        镜像少发了中间证书，得让维护者修
#   主机名不匹配    地址指错了 —— 这时**最不该**做的就是绕过校验
#   连接 / DNS      根本不是 TLS 问题，别去折腾证书
#
# 分类只认两条证据：异常文本（requests / urllib3 会把它带上来），以及
# 「不校验地握手一次」读到的对端证书（notAfter、SAN）。后者只在已经确定是
# 证书问题之后才做，而且读不到就跳过 —— 分诊本身不能变成新的失败点。

EXPIRED = "expired"
SELF_SIGNED = "self-signed"
INCOMPLETE = "incomplete-chain"
HOSTNAME = "hostname"
CERT_OTHER = "certificate"
NETWORK = "network"


_EXPIRED_MARKERS = ("certificate has expired", "certificate_expired", "cert has expired",
                    "expired certificate")
_SELF_SIGNED_MARKERS = ("self-signed certificate", "self signed certificate", "self-signed cert")
_INCOMPLETE_MARKERS = ("unable to get local issuer certificate", "unable to get issuer certificate",
                       "unable to verify the first certificate", "incomplete certificate chain",
                       "certificate chain is incomplete")
_HOSTNAME_MARKERS = ("hostname mismatch", "doesn't match", "does not match",
                     "not valid for", "ip address mismatch", "no appropriate commonname",
                     "no appropriate subjectaltname")
_NETWORK_MARKERS = ("name or service not known", "nodename nor servname", "getaddrinfo",
                    "temporary failure in name resolution", "connection refused",
                    "network is unreachable", "no route to host", "connection reset",
                    "connection aborted", "eof occurred", "max retries exceeded",
                    "newconnectionerror", "timed out", "timeout", "proxy")
_CERT_MARKERS = ("certificate verify failed", "certificate_verify_failed", "sslerror",
                 "certificate error", "tlsv1 alert", "unknown ca", "handshake failure")


def _text_of(error):
    """异常或字符串 → 小写文本，连同异常链一起（urllib3 把真正的原因包在里层）。"""
    if isinstance(error, str):
        return error.lower()
    parts = [str(error)]
    seen = 0
    cause = getattr(error, "__cause__", None) or getattr(error, "__context__", None)
    while cause is not None and seen < 5:
        parts.append(str(cause))
        cause = getattr(cause, "__cause__", None) or getattr(cause, "__context__", None)
        seen += 1
    return " ".join(parts).lower()


def classify(error):
    """把一次失败归到上面那几类；不是 TLS 的事也照样给个答案，认不出返回 None。

    顺序有讲究：过期证书的报错里同样带着「certificate verify failed」，
    自签与主机名不匹配也都在同一句里，所以先认具体的、再认笼统的。
    """
    text = _text_of(error)
    if any(marker in text for marker in _EXPIRED_MARKERS):
        return EXPIRED
    if any(marker in text for marker in _SELF_SIGNED_MARKERS):
        return SELF_SIGNED
    if any(marker in text for marker in _INCOMPLETE_MARKERS):
        return INCOMPLETE
    if any(marker in text for marker in _HOSTNAME_MARKERS):
        return HOSTNAME
    # 笼统的证书失败排在网络之前：走代理时请求失败的文本里也会出现 proxy / timeout，
    # 而「证书」这个词只有真出证书问题才会出现。
    if any(marker in text for marker in _CERT_MARKERS):
        return CERT_OTHER
    if any(marker in text for marker in _NETWORK_MARKERS):
        return NETWORK
    return None


def _cacert_advice():
    """「自签 / 链不完整」时那句关于自定义根证书的建议。

    已经设了就提醒核对（这时再叫他设一遍只会让人以为旗标没生效），
    没设才给一条可以直接照抄的 export。
    """
    current = cacert_path()
    if current:
        return [f"{CACERT_NAME} is already set to {current} — check that this file contains "
                f"the root this server chains to"]
    return [f"trust that root instead of disabling checks: "
            f"export {CACERT_NAME}=/path/to/root.pem"]


def _is_certificate(kind):
    return kind in (EXPIRED, SELF_SIGNED, INCOMPLETE, HOSTNAME, CERT_OTHER)


def _target(url):
    """url → (host, port)，取不到返回 (None, None)。"""
    from urllib.parse import urlsplit

    try:
        parts = urlsplit(url or "")
    except ValueError:
        return None, None
    if not parts.hostname:
        return None, None
    return parts.hostname, parts.port or (443 if parts.scheme == "https" else 80)


_PEER_CACHE = {}


def peer_certificate(url, timeout=5):
    """**诊断用**：不校验证书地握手一次，只为读出对方的 notAfter / SAN。

    只在已经确认是证书问题后调用；不发送任何应用数据，失败返回 None。
    """
    import socket
    import ssl
    import tempfile
    import os

    host, port = _target(url)
    if not host:
        return None
    # `wave latest -a` 会对几十个包各失败一次，同一台主机的握手只做一次
    if (host, port) in _PEER_CACHE:
        return _PEER_CACHE[(host, port)]
    try:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with context.wrap_socket(sock, server_hostname=host) as secure:
                der = secure.getpeercert(binary_form=True)
    except (OSError, ssl.SSLError, ValueError):
        return None
    if not der:
        return None

    # CERT_NONE 下 getpeercert() 返回空字典，只能把 DER 转成 PEM 再解码。
    # _test_decode_cert 是私有的，但它只读文件、不建连接，坏掉时外面有兜底。
    path = None
    try:
        handle, path = tempfile.mkstemp(suffix=".pem")
        with os.fdopen(handle, "w") as stream:
            stream.write(ssl.DER_cert_to_PEM_cert(der))
        cert = ssl._ssl._test_decode_cert(path)
    except (AttributeError, OSError, ValueError, ssl.SSLError):
        cert = None
    finally:
        if path:
            try:
                os.unlink(path)
            except OSError:
                pass
    _PEER_CACHE[(host, port)] = cert
    return cert


def _not_after(cert):
    """证书的到期日，YYYY-MM-DD；读不到返回 None。"""
    import time

    raw = (cert or {}).get("notAfter")
    if not raw:
        return None
    for pattern in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
        try:
            return time.strftime("%Y-%m-%d", time.strptime(raw, pattern))
        except ValueError:
            continue
    return None


def _names(cert, limit=3):
    """证书上写的 DNS / IP 名字（SAN 优先），最多 limit 个。"""
    entries = [value for kind, value in (cert or {}).get("subjectAltName", ())
               if kind in ("DNS", "IP Address")]
    if not entries:
        for group in (cert or {}).get("subject", ()):
            for key, value in group:
                if key == "commonName":
                    entries.append(value)
    return entries[:limit]


def explain(error, url=""):
    """返回 (一句话结论, [下一步...])；认不出来返回 None。

    结论直接说「是什么」，建议里给「该谁去做什么」—— 证书问题最怕的就是
    把用户送去重试一件他改不了的事。
    """
    kind = classify(error)
    if kind is None:
        return None

    host, _port = _target(url)

    if kind == NETWORK:
        where = f" {host}" if host else ""
        return (f"cannot reach{where}: this is a network problem, not a TLS or certificate one",
                ["check DNS, the proxy (--proxy) and the mirror address, then retry",
                 "`wave mirror` shows which address each kind of data is fetched from"])

    cert = peer_certificate(url) if _is_certificate(kind) else None

    if kind == EXPIRED:
        expiry = _not_after(cert)
        headline = "the server's certificate has expired"
        if expiry:
            headline = f"the server's certificate has expired (notAfter: {expiry})"
        return (headline,
                ["nothing on your side can fix this: the server sent an out-of-date certificate",
                 "retry later, or contact the mirror maintainer",
                 "do not work around this with --skip-ssl — the server really is misconfigured"])

    if kind == SELF_SIGNED:
        advice = ["this is normal inside a corporate network that inspects TLS, "
                  "or on a self-hosted mirror with its own CA",
                  "ask your network team for the root certificate"]
        advice += _cacert_advice()
        advice += ["otherwise switch to an official mirror (`wave mirror` shows the addresses in use)",
                   "--skip-ssl bypasses verification (insecure); it does not make the connection safe"]
        return ("the server uses a self-signed certificate or a private CA", advice)

    if kind == INCOMPLETE:
        advice = ["the root is usually fine — what is missing is the intermediate certificate "
                  "the server should send along",
                  "ask the mirror maintainer to serve the full chain"]
        advice += _cacert_advice()
        advice += ["or switch to an official mirror; --skip-ssl bypasses verification (insecure)"]
        return ("the server's certificate chain is incomplete (a required intermediate CA is missing)",
                advice)

    if kind == HOSTNAME:
        issued = _names(cert)
        headline = "the certificate is not valid for this host"
        if host:
            headline = f"the certificate is not valid for {host}"
        advice = []
        if issued:
            advice.append("the certificate was issued for: " + ", ".join(issued))
        if host:
            advice.append(f"you are connecting to: {host}")
        advice += ["this is a configuration problem: check the domain in use "
                   "(`wave mirror` shows them) and the DNS answer",
                   "do not work around this with --skip-ssl or a custom CA — "
                   "that would trust a certificate meant for another host"]
        return (headline, advice)

    # 剩下的证书类失败：说不出具体是哪一种，就把原文留在结论里
    first_line = str(error).strip().splitlines()[0][:200] if str(error).strip() else ""
    advice = ["check the mirror's certificate chain (it may be mid-renewal), or use an official mirror",
              "`wave mirror` shows which address each kind of data is fetched from"]
    if first_line:
        advice.insert(0, first_line)
    return ("TLS certificate verification failed", advice)


def hints(error, url="", fallback=None):
    """给 `steplog.fail(hint=...)` 用：分类结论 + 下一步；认不出时返回 fallback。"""
    explained = explain(error, url)
    if explained is None:
        if fallback is None:
            return []
        return [fallback] if isinstance(fallback, str) else list(fallback)
    headline, advice = explained
    return [headline] + advice
