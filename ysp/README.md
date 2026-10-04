ysp-proxy ARM Linux 安装说明
============================

支持的系统：
- 使用 systemd 的 Linux
- armv7l（ARMv7 硬浮点）或 aarch64 / arm64
- Debian、Ubuntu、Armbian 等基于 apt 的发行版

安装步骤：
1. 解压 ysp-proxy-<版本>-linux-universal.tar.gz。
2. 执行：sudo ./install.sh
3. 按提示依次设置端口、公网访问地址、解码并发数、分片预取、异常日志、EPG 缓存路径和内存上限。

安装程序会写入：
- /opt/ysp-proxy                          程序与运行数据
- /etc/ysp-proxy.conf                     运行参数
- /etc/systemd/system/ysp-proxy.service   systemd 服务单元

依赖下载：
预编译的 cmg-native 与 libopenh264 直接随包提供，正常情况下不会联网。
只有预编译产物在目标机无法运行、需要回退到源码编译时，才会按需下载 OpenH264
2.6.0 源码包（默认优先走 github.776512.xyz 镜像，下完做 SHA256 校验）。
如需指定自己的镜像，可先设置 YSP_OPENH264_URL，再执行安装。

升级说明：
解压新版本包后再次执行同一条命令即可。安装程序会读取旧配置作为默认值，
未修改的项继续沿用；覆盖前会备份旧文件，启动失败时自动回滚到升级前的版本。
