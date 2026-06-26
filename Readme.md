# fast-vless

VLESS / Trojan Reality 一键安装脚本，适合在 VPS 或 LXC 环境中快速部署 Xray 节点。

当前脚本版本：`V6.2 正式版 by L.H.X`

## 功能

- 自动检测系统并安装基础依赖
- 自动安装 Xray Core
- 一键生成 `VLESS Reality Vision` 节点
- 一键生成 `Trojan Reality` 节点
- 按服务器地区自动选择 Reality 伪装 CDN 域名
- 使用 `xray tls ping` 探测证书链长度，避免超过 Reality 可用上限
- 支持手动输入 Reality 域名 / SNI，并在使用前先探测可用性
- 自动生成客户端导入链接
- 自动保存历史节点链接，方便后续查询
- 生成 VLESS 中转链接
- 开启 BBR 加速
- 检查 IP 纯净度和流媒体解锁
- 运行 Ookla Speedtest 测速
- 卸载 Xray

## 支持系统

- Debian / Ubuntu
- CentOS / RHEL / Rocky Linux / AlmaLinux
- Alpine Linux

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

## 候选域名策略

候选域名优先选择大陆可访问倾向较强的大流量游戏、软件和 CDN 域名，例如米哈游 / HoYoverse、腾讯、网易相关 CDN。

脚本不会把以下类型放入自动候选池：

- 政治相关网站
- NSFW 网站
- 政府网站
- 银行网站
- 苹果网站
- 已知证书链超过 Reality 上限的域名

`www.microsoft.com` 不再作为默认域名，仅作为所有 CDN 候选都失败后的最后兜底，并且使用前同样必须通过 `xray tls ping` 探测。

## 历史链接

每次成功生成 VLESS 或 Trojan 节点后，脚本会自动把链接保存到：

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
- 历史链接文件不会在卸载 Xray 时自动删除
- 自动候选采用保守域名池，不等同于从大陆网络做实时 GFW 可达性检测

## 卸载

运行脚本后，在主菜单选择：

```text
7) 卸载 Xray
```

即可停止并禁用 Xray 服务，同时删除 Xray 配置和二进制文件。
