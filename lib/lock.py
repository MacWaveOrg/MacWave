#!/usr/bin/env python3

# lock.py

# 树级互斥锁：同一时刻只允许一个会**改动安装树**的 wave 在跑。
#
# 为什么需要：以前唯一的一把锁在 installed.json 上，而那个文件已经删掉了
# （它的内容完全可以从 bin/<名>@<版本>/ 推导出来）。于是同时跑两个 wave 会撞在
# 这几处，而且症状都不指向真正的原因：
#
#   - <base>/bin/<名>@<版本>/：depsmanager.sh 先 `rm -rf` 再 `mv`，两个进程
#     同时进来的话，一个会把另一个刚写进去的文件删掉；
#   - links/：不带版本号的软链接互相踩；
#   - .depped_pkg_* / .depped_dep_*：引用计数是"读-改-写"，并发就是丢更新，
#     之后 uninstall 会留下孤儿依赖，或者删掉还有人在用的依赖；
#   - downloads/tmp/<文件名>.partial：同名临时文件被两个进程同时写
#     （sha256 会挡住坏安装，但用户看到的是一句莫名其妙的校验失败）。
#
# 锁的是**整棵树**而不是某个包：上述四处互相牵连，按包加锁仍然会在依赖计数上撞车。
# 代价是"两个 wave 不能同时装不同包"，这个取舍是对的 —— 单机安装本来就是串行的事。
#
# 用 flock，不用锁文件存在性：进程被 Ctrl-C / kill -9 掉之后 flock 由内核释放，
# 不会留下"死锁文件"需要人工删。锁文件里写的 pid 与动作只用于**报错时说明**
# 是谁在跑，不参与判断。
#
# 可重入：命令内部再进来一次（reinstall → install、upgrade --all → 单个 upgrade、
# multi_install → 逐个 install）不能自己把自己锁死。判据是同一个进程的调用深度。

import fcntl
import os
import sys

from configpaths import load_base_dir

LOCK_DIR_NAME = "var/lock"
LOCK_FILE_NAME = "wave.lock"

# depth > 0 表示本进程已经持有锁；handle 是那个已打开的文件的句柄。
_state = {"depth": 0, "handle": None}


def lock_path(base_dir=None):
    base_dir = base_dir if base_dir is not None else load_base_dir()
    return os.path.join(str(base_dir), LOCK_DIR_NAME, LOCK_FILE_NAME)


def _holder_description(path):
    """锁文件里写的「pid 动作」。读不到就返回空串 —— 这只是提示信息。"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read().strip()
    except OSError:
        return ""
    parts = text.split(None, 1)
    if not parts:
        return ""
    if len(parts) == 1:
        return f"pid {parts[0]}"
    return f"pid {parts[0]} ({parts[1]})"


def _report_busy(path):
    holder = _holder_description(path)
    print("🌊 Error: another wave is running on this install tree", file=sys.stderr)
    if holder:
        print(f"🌊        {holder}", file=sys.stderr)
    print("🌊 Next   wait for it to finish, then run this again", file=sys.stderr)
    print(f"🌊        the lock is {path}", file=sys.stderr)
    print("🌊        do not delete it: it is released automatically when that process "
          "exits", file=sys.stderr)


class tree_lock:
    """`with tree_lock("install"):` —— 同一时刻一个改树的 wave。

    拿不到锁时打印原因并 `sys.exit(1)`：这类冲突没有"等一下再说"的合理默认，
    让第二个进程排队会表现为"卡住不动"，比直接说清楚更糟。
    """

    def __init__(self, action):
        self.action = action

    def __enter__(self):
        if _state["depth"] > 0:
            _state["depth"] += 1
            return self

        path = lock_path()
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            handle = open(path, "a+")
        except OSError as error:
            # 装不了锁不该让整个工具用不了（例如只读介质、权限奇怪的安装树）。
            # 说清楚"这次没有互斥"，比默默假装有锁更诚实。
            print(f"🌊 Warning: cannot create the install lock ({error}); "
                  f"continuing without it", file=sys.stderr)
            _state["depth"] = 1
            _state["handle"] = None
            return self

        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            _report_busy(path)
            handle.close()
            sys.exit(1)

        try:
            handle.seek(0)
            handle.truncate()
            handle.write(f"{os.getpid()} {self.action}\n")
            handle.flush()
        except OSError:
            pass  # 内容只是提示信息，写不进去不影响互斥

        _state["depth"] = 1
        _state["handle"] = handle
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        _state["depth"] -= 1
        if _state["depth"] > 0:
            return False
        handle = _state["handle"]
        _state["handle"] = None
        if handle is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            finally:
                handle.close()
        return False
