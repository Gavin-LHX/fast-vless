# fast-vless

VLESS / Trojan Reality 一键安装脚本，适合在 VPS 或 LXC 环境中快速部署 Xray 节点。

当前脚本版本：`V6.2 正式版 by L.H.X`

## 功能

- 自动检测系统并安装基础依赖
- 自动安装 Xray Core
- 一键生成 `VLESS Reality Vision` 节点
- 一键生成 `VLESS Vision + enc` 节点（不带 TLS / Reality）
- 一键生成 `Trojan Reality` 节点
- 一键安装 `SS2022` 节点（基于 shadowsocks-rust）
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

## 支持系统

- Debian / Ubuntu
- CentOS / RHEL / Rocky Linux / AlmaLinux
- Alpine Linux

SS2022 会按系统和架构自动选择 shadowsocks-rust 的 Linux gnu / musl 版本。Alpine 使用 musl 版本，其他系统默认使用 gnu 版本。

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
10) 安装并配置 VLESS Vision + enc 节点（不带 TLS/Reality）
11) 卸载 SS2022
0) 退出
```

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

## VLESS Vision + enc

菜单 `10` 会生成启用 VLESS Encryption 的 Vision 节点，不使用 TLS / Reality。

脚本会调用 Xray 官方命令：

```bash
xray vlessenc
```

并默认使用 `Authentication: ML-KEM-768` 这一组后量子字段：

- 服务端配置写入 `decryption`
- 客户端链接写入 `encryption`
- 传输安全为 `security=none`
- 不生成 `sni`、`pbk`、`sid`、`fp` 等 Reality/TLS 参数

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

## 历史链接

每次成功生成 VLESS、Trojan 或 SS2022 节点后，脚本会自动把链接保存到：

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
- 历史链接文件不会在卸载 Xray 时自动删除
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
