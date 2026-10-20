# LiveBox YSP

此目录只发布 Linux 构建包，不包含项目源码。

LiveBox YSP 把央视频直播转换成标准 HLS，可供电视、手机、网页和 IPTV 播放器使用。

## 项目优势

- **播放器兼容**：输出标准 HLS，可接入 FongMi、TiviMate、VLC、ExoPlayer/Media3 等播放器。
- **线路容灾**：App 线路为主、Web 线路兜底，并根据上游健康状态执行重试、冷却和降级。
- **连续播放**：统一处理清单窗口、媒体序列和线路切换，减少换台、CDN 切换时的卡顿与重复播放。
- **低资源占用**：Go 主程序单进程运行，适合 ARM Linux 设备长期运行。
- **可观测**：提供中文运行日志和播放指标，可查看首帧耗时、分片结果、线路切换及各阶段耗时。

## Linux 构建包

| 文件 | 适用架构 |
| --- | --- |
| `ysp-proxy-20261021-linux-armv7.tar.gz` | ARMv7 硬浮点设备 |
| `ysp-proxy-20261021-linux-arm64.tar.gz` | ARM64 / AArch64 设备 |
| `ysp-proxy-20261021-linux-universal.tar.gz` | 包含以上两种架构，安装时自动选择 |

下载后请用 `SHA256SUMS.txt` 校验文件完整性。

## 安装

解压通用包并运行安装脚本：

```bash
tar -xzf ysp-proxy-20261021-linux-universal.tar.gz
cd ysp-proxy-20261021-linux-universal
sudo ./install.sh
```

服务支持 systemd，安装程序会配置开机启动和运行参数。

## 部署交给 AI

不需要自行研究安装步骤。把设备信息、网络环境和本目录地址交给 AI，让它完成架构判断、安装、配置和启动验证：

```text
请阅读 https://github.com/yuanzl77/LiveBox/tree/main/ysp，
根据我的设备 <型号、系统、架构、内存> 和局域网环境完成部署，
配置可通过电视访问的订阅地址，并验证首页、频道清单、分片和节目单。
```

## 安全说明

服务默认没有鉴权，请只在可信局域网内使用，不要直接暴露到公网。
