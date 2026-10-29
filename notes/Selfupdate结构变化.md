## Slefupdate仓库结构变更

新结构如下：

```
selfupdate
    ├─ macwavedata
    │  └─ VERSION_NUMBER
    │     └─ update_commands.sh (注：更新命令插入点（可用于结构变动等）。把下载哪些文件并放到对应位置的操作改为读取这个脚本，这样就可以只下载变化的文件，比如新版本的 `help.py` 没变，这个脚本里不写，就不需要像以前一样再安装一次），也不再需要`files_info`
    │ （仅列举一个版本为例）    
    ├─ pythondata
    │  └─ 3.14.9
           └─ python_url.toml（记录`python`解释器源头URL，一般不用）
```

如果	`selfupdate`或`install`有参数`--install-python-from-source`则会从源头下载`python`解释器。每次更新脚本只需判断当前解释器是不是MacWave给的最新版，再决定需不需要重新下载。  

`python_url.toml`可以这样写：
```
[arm64]
arm64_url = "https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.14.9+20261021-aarch64-apple-darwin-install_only.tar.gz"
arm64_sha256 = "226d696642a8a53d03b4d5b255b1c319b1575a6d44bd723a953c9f507755e36a"

[amd64]
amd64_url = "https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.14.9+20261021-x86_64-apple-darwin-install_only.tar.gz"
amd64_sha256 = "600cf336dd007e7c72318214fd0708a56c555b516964175df4a748e4ff0487a2"
```

把`MACWAVE_PYTHON_DATA`默认（我们新建一个仓库）`MacWaveOrg`的`Python`仓库