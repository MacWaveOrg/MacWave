#!/usr/bin/env python3

# configerror.py

import sys
import subprocess
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'


# -------------------- 环境检测与报错 --------------------

def check_environment():
    
    # 检测当前环境
    # - 如果 /opt/macwave_config/config.json 存在，说明已正式安装，正常继续。
    # - 如果不存在，且当前在 git 仓库里，报错并退出。
    
    config_file = Path("/opt/macwave_config/config.json")
    if config_file.exists():
        return

    try:
        result = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0 or result.stdout.strip() != "true":
            return
    except Exception:
        return

    try:
        shallow_result = subprocess.run(
            ["git", "rev-parse", "--is-shallow-repository"],
            capture_output=True, text=True, timeout=5
        )
        is_shallow = shallow_result.stdout.strip() == "true"
    except Exception:
        is_shallow = False

    try:
        root_result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5
        )
        repo_root = root_result.stdout.strip()
    except Exception:
        repo_root = ""

    if is_shallow:
        print(f"{RED_BOLD}🌊 Error: MacWave is a shallow clone!{RESET}")
    else:
        print(f"{RED_BOLD}🌊 Error: MacWave is a git clone!{RESET}")

    print("")
    print("MacWave is not distributed as a shallow clone. Instead, it uses install.sh to download various files to their corresponding locations. Among other things, install.sh writes a configuration file to /opt/macwave_config. This configuration file records a large amount of information, including the location where you downloaded MacWave, and it is called by many programs. Without it, many programs will not be able to find the directories.")
    print("")
    if is_shallow:
        print("We have detected that you are using a shallow clone, which will cause MacWave to fail to work properly. To continue using it, please run $ /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)\" and select the directory you want to install to. You can also run $ bash " + repo_root + "/lib/install.sh or $ /bin/bash " + repo_root + "/lib/install.sh and select the directory you want to install to in order to fully install MacWave.")
    else:
        print("We have detected that you are using a git clone, which will cause MacWave to fail to work properly. To continue using it, please run $ /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)\" and select the directory you want to install to. You can also run $ bash " + repo_root + "/lib/install.sh or $ /bin/bash " + repo_root + "/lib/install.sh and select the directory you want to install to in order to fully install MacWave.")
    print("")
    print("If you are a collaborator of MacWave, or if you cloned the source code for a specific purpose, please do not run it locally, or at least do not run it in the Git directory.")
    print("")
    print("If you have any other questions, please contact hi@macwave.org.")

    sys.exit(1)


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by wave.py.")
    sys.exit(1)