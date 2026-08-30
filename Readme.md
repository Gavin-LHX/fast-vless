# fast-vless

VLESS / Trojan Reality / SS2022 / Snell 一键安装脚本，适合在 VPS 或 LXC 环境中快速部署代理节点。

当前脚本版本：`V6.3 正式版 by L.H.X`

## 功能

- 自动检测系统并安装基础依赖
- 创建节点前自动安装 Chrony、同步系统时间并启用开机自启
- 自动安装 Xray Core
- 一键生成 `VLESS Reality Vision` 节点
- 一键生成 `VLESS + enc + Vision flow` 节点
- 一键生成 `Trojan Reality` 节点
- 一键安装 `SS2022` 节点（基于 shadowsocks-rust）
- 一键安装官方 `Snell Server v5.0.1` 节点
- 按服务器地区自动选择 Reality 伪装 CDN 域名
- 使用 `xray tls ping` 探测证书链长度，避免超过 Reality 可用上限
- 支持手动输入 Reality 域名 / SNI，并在使用前先探测可用性
- 支持粘贴 `https://example.com/path`，脚本会自动提取真实域名
- 自动生成客户端导入链接
- 自动保存历史节点链接，方便后续查询
- 生成 VLESS 中转链接
- 开启 BBR 加速
- 检查 IP 纯净度和流媒体解锁
- 运行 Ookla Speedtest 测速
- 卸载 Xray
- 卸载 SS2022
- 卸载 Snell v5
- 从主菜单手动执行 Chrony 时间同步

## 支持系统

- Debian / Ubuntu
- CentOS / RHEL / Rocky Linux / AlmaLinux
- Alpine Linux

SS2022 会按系统和架构自动选择 shadowsocks-rust 的 Linux gnu / musl 版本。Alpine 使用 musl 版本，其他系统默认使用 gnu 版本。

Snell 使用 Surge 官方发布的 `v5.0.1` 内核，支持 `amd64`、`i386`、`aarch64` 和 `armv7l`。官方文件带有 UPX 自解包外壳，外层 ELF 虽会被 `file` 识别为静态链接，实际运行时仍会加载 glibc。Alpine 会自动补齐 OpenRC，并安装官方仓库中的 `gcompat`、`libstdc++`、`libgcc`、`libcap-utils` 和临时安装 `upx`，在服务器本机无损解包后运行原版内核，不需要源码、musl 重编译或额外二进制仓库。脚本会先校验官方压缩包的固定 SHA-256。

Chrony 会按系统自动选择安装和服务管理方式：Debian / Ubuntu 使用 `apt` 与 `chrony.service`，CentOS / RHEL / Rocky Linux / AlmaLinux 使用 `dnf` 或 `yum` 与 `chronyd.service`，Alpine 使用 `apk` 安装 `chrony`（新版会补装 `chrony-openrc`）并启用 OpenRC 的 `chronyd` 服务。

请使用 `root` 权限运行脚本。如果当前用户不是 root，可以先执行：

```bash
sudo -s
```

或：

```bash
su root
```

## 快速开始

```bash
bash <(curl -L https://raw.githubusercontent.com/Gavin-LHX/fast-vless/main/xrayvless.sh)
```

## 主菜单

```text
1) 安装并配置 VLESS Reality Vision节点
2) 生成Trojan Reality节点
3) 生成 VLESS 中转链接
4) 开启 BBR 加速
5) 检查 IP 纯净度 & 流媒体解锁
6) Ookla Speedtest 测试
7) 卸载 Xray
8) 查看历史节点链接
9) 安装并配置 SS2022 节点
10) 安装并配置 VLESS + enc + Vision flow 节点
11) 卸载 SS2022
12) 安装 Chrony 并同步系统时间
13) 安装并配置 Snell v5 节点
14) 卸载 Snell v5
0) 退出
```

## Chrony 时间同步

创建以下节点前，脚本会自动安装并运行 Chrony：

- `1) VLESS Reality Vision`
- `2) Trojan Reality`
- `9) SS2022`
- `10) VLESS + enc + Vision flow`
- `13) Snell v5`

脚本会保留发行版自带的 Chrony 配置和 NTP 源，启用服务开机自启，并使用 `chronyc` 触发快速采样和校时。也可以在主菜单选择：

```text
12) 安装 Chrony 并同步系统时间
```

单独安装或重新执行时间同步。同步完成后会显示当前系统时间和 Chrony 跟踪状态。

部分未授权调整系统时间的 LXC 容器会由宿主机统一维护时钟。遇到这种情况时，脚本会给出警告并继续创建节点，不会因为 Chrony 权限不足中断部署。

## Reality 域名选择

安装 VLESS 或 Trojan 节点时，脚本会提示：

```text
Reality 域名/SNI（回车自动按地区选择，手动输入则先探测）:
```

直接回车时，脚本会：

1. 通过 `curl ipinfo.io` 检测服务器地区
2. 按地区选择游戏 / 软件 / CDN 类候选域名
3. 使用 Xray 自带的 `xray tls ping` 逐个探测
4. 只使用 SNI 握手成功且证书链长度小于 `8192` 的域名
5. 把选中的域名写入 Xray 配置和最终链接的 `sni` 参数

手动输入域名时，脚本也会先执行 `xray tls ping`。如果探测失败或证书链长度不合格，会要求重新输入。

手动输入支持方向键编辑；如果粘贴完整 URL，例如：

```text
https://www.alibabagroup.com/
```

脚本会自动识别为：

```text
www.alibabagroup.com
```

## 候选域名策略

候选域名优先选择大陆可访问倾向较强的大流量游戏、软件和 CDN 域名，例如米哈游 / HoYoverse、腾讯、网易相关 CDN。

新加坡 / 东南亚地区会优先使用 HoYoverse SG、Hoyolab、Alibaba / Alicdn 等候选域名，再进入全局候选。

脚本不会把以下类型放入自动候选池：

- 政治相关网站
- NSFW 网站
- 政府网站
- 银行网站
- 苹果网站
- 已知证书链超过 Reality 上限的域名

`www.microsoft.com` 不再作为默认域名，仅作为所有 CDN 候选都失败后的最后兜底，并且使用前同样必须通过 `xray tls ping` 探测。

## VLESS + enc + Vision flow

菜单 `10` 会生成启用 VLESS Encryption 的 VLESS 节点，并使用 `xtls-rprx-vision` 流控。

脚本会调用 Xray 官方命令：

```bash
xray vlessenc
```

并默认使用 `Authentication: ML-KEM-768` 这一组后量子字段：

- 服务端配置写入 `decryption`
- 客户端链接写入 `encryption`
- 流控为 `flow=xtls-rprx-vision`
- 传输安全为 `security=none`
- 不生成 `sni`、`pbk`、`sid`、`fp` 等 Reality 参数

生成的链接会比较长，这是 ML-KEM-768 方案的正常现象。

## SS2022

菜单 `9` 会安装 shadowsocks-rust 并生成 SS2022 节点。

默认配置：

- method：`2022-blake3-aes-128-gcm`
- 默认端口：`8388`
- 密码：自动执行 `openssl rand -base64 16` 生成
- 模式：`tcp_and_udp`
- 配置文件：`/etc/shadowsocks/config.json`

服务路径：

- systemd：`/etc/systemd/system/shadowsocks.service`
- Alpine / OpenRC：`/etc/init.d/shadowsocks`

菜单 `11` 可卸载 SS2022，会停止服务、取消开机启动，并删除 shadowsocks-rust 二进制和 `/etc/shadowsocks` 配置目录。

## Snell v5

菜单 `13` 会从 Surge 官方地址下载并安装 `Snell Server v5.0.1`。脚本不会重新打包或托管 Snell 内核，也不会使用第三方兼容实现。

Debian / Ubuntu / RHEL 系直接运行官方内核。Alpine 会安装 `gcompat`、`libstdc++`、`libgcc` 和 `libcap-utils`，并使用 Alpine 官方 `upx` 在本机去除官方文件的自解包外壳，再通过 musl 的 glibc 兼容层运行；安装结束后会删除临时 UPX 安装依赖。脚本会尝试授予专用 `snell` 用户绑定低端口的最小 capability；如果容器文件系统不支持，则提示改用 `1024-65535` 端口。

默认配置：

- 官方内核版本：`v5.0.1`
- 默认端口：`6160`，安装时可以修改
- PSK：自动执行 `openssl rand -hex 24` 生成
- 协议版本：`version: 5`
- UDP：`udp: true`，v5 自动支持 UDP 转发
- 连接复用：`reuse: false`
- TLS：关闭
- obfs：关闭，服务端配置中不写入 `obfs` 或 `obfs-host`
- 配置文件：`/etc/snell/snell-server.conf`

Snell v5 的普通 UDP 会通过 UDP-over-TCP 转发；Surge 的 QUIC Proxy Mode 会使用服务器相同端口的 UDP，因此脚本会在已启用的 UFW 或 firewalld 中同时放行 TCP 和 UDP。

服务路径：

- systemd：`/etc/systemd/system/snell.service`
- Alpine / OpenRC：`/etc/init.d/snell`
- 官方内核：`/usr/local/bin/snell-server`

脚本会输出两种客户端配置：

- Surge 行格式：显式包含 `version=5, reuse=false`；UDP 在 v5 中自动启用，不需要额外参数
- YAML 格式：显式包含 `version: 5`、`udp: true`、`reuse: false`

Snell 没有统一的标准 URI，因此脚本保存的是客户端配置块，不会伪造 `snell://` 链接。官方说明和内核下载地址见 [Surge Snell Knowledge Base](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)。

菜单 `14` 可停止并卸载 Snell v5，同时删除服务、配置、官方内核、由脚本创建的专用 `snell` 系统账户，以及脚本自行添加的 UFW/firewalld 端口规则。

## 历史链接

每次成功生成 VLESS、Trojan、SS2022 或 Snell 节点后，脚本会自动把链接或客户端配置保存到：

```bash
/root/xray_link_history.txt
```

可以在主菜单中选择：

```text
8) 查看历史节点链接
```

查看之前生成过的节点链接。

## 文件说明

- `xrayvless.sh`：主菜单脚本，负责安装、配置、生成链接和常用检测功能
- `xrayinstall.sh`：systemd 系统使用的 Xray 安装脚本
- `xrayinstall-alpine.sh`：Alpine / OpenRC 系统使用的 Xray 安装脚本
- `Readme.md`：项目说明文档
- `Readme.cn.md`：简体中文说明文档

## 注意事项

- 脚本会写入 `/usr/local/etc/xray/config.json`
- 每次重新生成 VLESS 或 Trojan 节点都会覆盖当前 Xray 配置
- 开启 BBR 功能会重写 `/etc/sysctl.conf`，如服务器已有自定义内核参数，请先自行备份
- 卸载 Xray 会删除 `/usr/local/etc/xray` 和 `/usr/local/bin/xray`
- 卸载 SS2022 会删除 `/etc/shadowsocks`、`/usr/local/bin/ssserver` 和 `/usr/local/bin/sslocal`
- 卸载 Snell 会删除 `/etc/snell`、`/usr/local/bin/snell-server` 和对应服务文件
- 历史链接文件不会在卸载 Xray 时自动删除
- Chrony 使用系统自带的默认 NTP 源，脚本不会覆盖已有 `/etc/chrony.conf` 或 `/etc/chrony/chrony.conf`
- 自动候选采用保守域名池，不等同于从大陆网络做实时 GFW 可达性检测

## 卸载

运行脚本后，在主菜单选择：

```text
7) 卸载 Xray
```

即可停止并禁用 Xray 服务，同时删除 Xray 配置和二进制文件。

如需卸载 SS2022，在主菜单选择：

```text
11) 卸载 SS2022
```

如需卸载 Snell v5，在主菜单选择：

```text
14) 卸载 Snell v5
```
