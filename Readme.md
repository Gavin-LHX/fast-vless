# fast-vless

VLESS / Trojan Reality 一键安装脚本，适合在 VPS 或 LXC 环境中快速部署 Xray 节点。

当前脚本版本：`V6.2 正式版 by L.H.X`

## 功能

- 自动检测系统并安装基础依赖
- 自动安装 Xray Core
- 一键生成 `VLESS Reality Vision` 节点
- 一键生成 `Trojan Reality` 节点
- 支持自定义 Reality 域名 / SNI
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

## Reality 域名 / SNI

安装 VLESS 或 Trojan 节点时，脚本会提示输入 Reality 域名 / SNI：

```text
Reality 域名/SNI（默认 www.microsoft.com）:
```

直接回车会使用默认值 `www.microsoft.com`。如果你想使用其他域名，可以在这里输入，例如：

```text
www.microsoft.com
```

脚本会把该域名同时写入 Xray 配置中的 `dest`、`serverNames`，以及最终生成链接中的 `sni` 参数。

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

## 卸载

运行脚本后，在主菜单选择：

```text
7) 卸载 Xray
```

即可停止并禁用 Xray 服务，同时删除 Xray 配置和二进制文件。
