#!/usr/bin/env python3
"""pkginstaller.py伪代码"""

程序开始
# ------------------------------------------------------
读取/opt/macwave_config/config.json，获取下载目录
def CONFIG = 下载目录
# 处理输入的字符串（来自wave.py）. # 形如 wave install ldid@ver
def "install+一个空格后"到"下一个空格前"或"@前" 的字符串 = "ParsePkgName"
# 通过os获取架构:arm64或amd64
if 获取的架构为arm64
    def "Arch" = "arm64"
elif 获取的架构为 amd64
    def "Arch" = "amd64"
else:
    print "🌊 Error: Unknown Arch!{RED}{BOLD}"
    
# 检查:
if "字符串"含有 "@"
   if "字符串"含有"--ver"
        print  "🌊 Error: Repeated Version Number"
    else:
        def "@"后面到"下一个出现的空格"前面的字符串为"ParsePkgVersion"
 elif "字符串"含有"--ver"
     def "--ver"后面的一个空格后面到"下一个出现的空格"前面的字符串为"ParsePkgVersion"
 else:
     读取f"https://api.github.com/repos/MacWaveOrg/infosource/contents/pkg/pkginfo_{Arch}/{ParsePkgName}?ref=main"通过GitHub API返回的JSON
     提取"@"后面的内容为版本号并排除掉"common"
     调用pkgversiobparser.py来获取到最终的最新版本号
     def 此版本为"ParserPkgVersion"

# 版本号检查:
读取文件f"https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_{Arch}/{ParserPkgName}/{ParserPkgName}@{ParsePkgVersion}"
    if 产生错误码
        if (输入的字符串含有"-v" or 输入的字符串含有"--verbose"
            输出详细错误返回内容
        elif 错误码为404
            print "🌊 Error: Can't find parse pacakge version. \n 🌊 If you certain this version is existent, Please contact the administrator."{RED}{BOLD}
        else:
            print "🌊 Error: Service unavailable, Please contact the administrator."{RED}{BOLD}

找到"url"字段
def 第一个\"和第二个\"之间的字符串 = "ParsePkgURL"

# 简单检查，避免低级错误
if "ParsePkgURL" 开头不是"https://"
    if "ParsePkgURL"开头是"http://"
        print "🌊 ParsePkgURL using HTTP！That's insecure, Please contact the administrator."{RED}{BOLD}
    else：
        print "🌊 ParsePkgURL Invalid, Please contact the administrator."{RED}{BOLD}

通过网址"ParsePkgURL"获取下载资源
下载到f"{CONFIG}/tmp
    if 产生错误码
        if (输入的字符串含有"-v" or 输入的字符串含有"--verbose"）
            输出详细错误返回内容
        elif 错误码为404
            print "🌊 Error: Can't find parse pacakge version. \n 🌊 If you certain this version is existent, Please contact the administrator."{RED}{BOLD}
        else:
            print "🌊 Error: The Service of this Package is unavailable, Please contact the administrator ."{RED}{BOLD}

# 这里加一个和之前一样的进度条

# 调用pkginstaller.sh处理文件
# 写入installed.json由pkginstaller.sh进行

    

    
