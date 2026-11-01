#!/usr/bin/env python3

# tls.py

# `--skip-ssl` 的唯一实现：设一次，全进程生效。
#
# 为什么要有这个模块：这个旗标原先只在 download_file 里读，于是「版本清单」
# `@common`、版本记录、依赖元数据、info / search / latest 这些请求照样校验证书。
# 而自签证书的镜像恰好在**第一个**请求上就失败 —— 旗标等于没写。
#
# 做法是把状态放在模块级，由 wave.py 在分发命令之前从原始命令行里设一次；
# 所有发请求的地方都加 `**tls.request_kwargs()`。这样不会再有「漏了哪一处」。
#
# 为什么分「请求」与「授权」两段：install / upgrade 会先弹一句安全询问，用户
# 答否（或非交互读不到答复）时**不能**跳过校验。若在分发之前就直接打开，
# 那个询问就形同虚设。所以先 configure_from() 记下「命令行里写了」，
# 真正生效要等 grant()。

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


def configure_from(argv):
    """从原始命令行记下是否要求跳过证书校验。返回是否要求。"""
    global _requested
    _requested = "--skip-ssl" in argv
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
    """给 requests 的额外关键字；没开时是空字典，调用处不需要分支。"""
    return {"verify": False} if _enabled else {}


def curl_flags():
    """给 curl 的等价旗标：curl 是 `-k`，与 requests 的 verify=False 同义。"""
    return ["-k"] if _enabled else []


def urlopen_kwargs():
    """给 urllib 的额外关键字：它不认 verify，只能换一个不校验证书的 SSLContext。"""
    if not _enabled:
        return {}
    import ssl

    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return {"context": context}
