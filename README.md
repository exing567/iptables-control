# ipt-forward-manager

一个用于在 Linux 服务器上管理 `iptables` 端口转发规则的交互式 Shell 脚本。

脚本通过菜单方式帮助你完成端口转发的添加、批量添加、删除、修改、查询、备份、回滚、导入导出、自检和 DDNS 刷新等操作，适合需要经常维护 DNAT/MASQUERADE 转发规则的服务器场景。

## 功能特性

- 检查 `iptables`、`iptables-save`、`netfilter-persistent` 是否可用
- 自动检查并开启 IPv4 转发：`net.ipv4.ip_forward=1`
- 添加单条 TCP、UDP 或 TCP+UDP 端口转发，目标支持 IPv4 或域名
- 批量添加端口转发规则
- 支持 DDNS 场景：保存域名配置，并在刷新时自动更新解析后的转发 IP
- 从当前配置列表中选择要删除的转发规则
- 删除时可选择 TCP、UDP 或 TCP+UDP，未选择的协议会保留
- 批量按备注 `comment` 删除规则
- 修改已有规则，即先删除旧规则再添加新规则
- 查看转发规则摘要、完整 NAT/FORWARD 规则、带备注规则
- 按端口、IP、备注搜索规则
- 查看指定端口的规则命中次数
- 导出当前转发规则为 `.conf` 配置文件
- 从 `.conf` 配置文件导入转发规则，导入前会预览
- 添加、删除、修改、导入、回滚前自动备份当前规则
- 支持从备份文件回滚 `iptables` 规则
- 保存规则到 `netfilter-persistent` 或 `/etc/iptables/rules.v4`
- 安装 systemd 自检/DDNS 定时刷新服务
- 手动刷新域名/DDNS 转发规则
- 记录操作日志到 `/var/log/ipt-forward-manager.log`

## 适用环境

- Linux 服务器
- Bash
- root 权限
- `iptables`
- 可选：`iptables-persistent` / `netfilter-persistent`
- 可选：`nc` 或 `timeout`，用于测试目标端口 TCP 可达性

脚本内置的安装命令使用 `apt`，因此自动安装依赖更适合 Debian、Ubuntu 等系统。其他发行版可以自行安装 `iptables` 相关组件后再运行脚本。

## 快速开始

```bash
curl -L https://raw.githubusercontent.com/exing567/iptables-control/main/ipt.sh -o ipt.sh && chmod +x ipt.sh && sudo bash ipt.sh
```
运行此指令一次之后，再次运行只用输入`sudo bash ipt.sh`即可

启动后会进入交互菜单，根据编号选择对应功能。

## 常用操作

### 添加单条端口转发

在菜单中选择：

```text
8) 添加单条转发
```

按提示输入：

```text
入站端口，例如 8443: 8443
目标 IP/域名，例如 1.1.1.1 或 home.example.com: home.example.com
目标端口，例如 443: 443
协议: TCP / UDP / TCP + UDP
备注，例如 xjj-forward-8443，留空自动生成
```

添加后脚本会创建对应的：

- `nat` 表 `PREROUTING` DNAT 规则
- `nat` 表 `POSTROUTING` MASQUERADE 规则
- `filter` 表 `FORWARD` ACCEPT 规则

### 批量添加转发

在菜单中选择：

```text
9) 批量添加转发
```

输入格式：

```text
入站端口 目标IP或域名 目标端口 协议 备注
```

示例：

```text
443 1.1.1.1 443 both xjj-forward-443
8443 home.example.com 443 tcp xjj-forward-8443
END
```

协议支持：

- `tcp`
- `udp`
- `both`

如果省略协议，默认使用 `both`。如果省略备注，脚本会自动生成类似下面的备注：

```text
xjj-forward-8443-to-1.1.1.1-443
```

### 使用域名/DDNS

如果目标是家宽动态 IP，可以把目标地址填写为 DDNS 域名，例如：

```text
8443 home.example.com 443 both home-https
```

脚本会在添加规则时解析 `home.example.com`，并把解析到的 IPv4 写入 `iptables`。同时，脚本会把域名原值保存到：

```text
/root/iptables-forward-conf/managed-forwards.conf
```

当 DDNS 解析变化后，可以在菜单中选择：

```text
23) 刷新域名/DDNS 转发
```

脚本会重新解析托管配置中的域名，如果发现当前解析 IP 和已有 DNAT 规则不一致，就自动删除旧 IP 规则并添加新 IP 规则。

### 删除规则

脚本支持两种删除方式：

- 选择配置删除：脚本会列出当前带备注的 DNAT 转发配置，选择序号后再选择要删除 TCP、UDP 或 TCP+UDP
- 批量按备注删除：每行输入一个 `comment`

推荐优先使用选择配置删除，因为它会直接列出当前可删除的转发项，避免手动输入端口、IP 或备注出错。如果同一条转发同时有 TCP 和 UDP，可以只删除其中一个协议，另一个协议会保留。

### 修改规则

在菜单中选择：

```text
12) 修改已有规则
```

脚本会先根据旧备注查找规则，再删除旧规则并添加新规则。修改前会自动备份当前 `iptables` 规则。

## 配置导入导出

### 导出

在菜单中选择：

```text
13) 导出当前转发为 .conf
```

默认导出目录：

```text
/root/iptables-forward-conf
```

导出文件格式：

```text
in_port target_ip_or_domain target_port protocol comment
```

示例：

```text
8443 1.1.1.1 443 tcp xjj-forward-8443
```

### 导入

在菜单中选择：

```text
14) 从 .conf 导入转发，导入前预览
```

配置文件支持注释和空行：

```text
# format: in_port target_ip_or_domain target_port protocol comment
443 1.1.1.1 443 both xjj-forward-443
8443 home.example.com 443 tcp xjj-forward-8443
```

导入前脚本会解析并预览有效规则和错误规则，确认后才会写入 `iptables`。

## 备份与回滚

默认备份目录：

```text
/root/iptables-backup
```

备份文件格式：

```text
iptables-YYYYMMDD-HHMMSS.rules
```

以下操作会自动备份当前规则：

- 添加规则
- 批量添加规则
- 删除规则
- 批量删除规则
- 修改规则
- 导入配置
- 从备份回滚

也可以在菜单中手动执行：

```text
15) 备份当前 iptables 规则
16) 查看备份列表
17) 从备份回滚
```

回滚会使用 `iptables-restore` 覆盖当前规则，请确认备份文件正确后再操作。

## 规则保存

脚本保存规则时会优先使用：

```bash
netfilter-persistent save
```

如果系统没有安装 `netfilter-persistent`，则会写入：

```text
/etc/iptables/rules.v4
```

注意：如果系统没有配置开机自动加载 `/etc/iptables/rules.v4`，重启后规则可能不会自动恢复。建议安装并启用 `iptables-persistent` 或 `netfilter-persistent`。

## 自检/DDNS 刷新服务

脚本支持安装一个 systemd oneshot 服务和 timer 定时器：

```text
20) 安装自检/DDNS 刷新服务
```

服务名称：

```text
ipt-forward-selfcheck.service
ipt-forward-selfcheck.timer
```

安装后会开机自动执行，并默认每 5 分钟执行一次：

```bash
bash ipt.sh --self-check
```

自检内容包括：

- 检查 `iptables` 是否存在
- 检查运行时 IPv4 转发状态
- 尝试开启运行时 `ip_forward`
- 统计 NAT 表中的 DNAT 规则数量
- 刷新托管配置中的域名/DDNS 转发规则
- 写入日志

如需卸载：

```text
21) 卸载自检/DDNS 刷新服务
```

## 日志

日志文件路径：

```text
/var/log/ipt-forward-manager.log
```

可在菜单中选择：

```text
22) 查看脚本日志
```

也可以直接查看：

```bash
sudo tail -n 100 /var/log/ipt-forward-manager.log
```

## 菜单概览

```text
基础检查
  1) 检查 iptables 是否安装
  2) 检查/修复 IPv4 转发 sysctl

规则查看
  3) 查看规则摘要表
  4) 查看全部 NAT / FORWARD 规则
  5) 搜索旧规则，包括端口/IP/备注
  6) 只显示带备注的规则
  7) 查看某端口规则命中次数

添加/删除/修改
  8) 添加单条转发
  9) 批量添加转发
 10) 选择配置删除规则
 11) 批量按备注删除规则
 12) 修改已有规则

配置导入导出
 13) 导出当前转发为 .conf
 14) 从 .conf 导入转发，导入前预览

备份/回滚/测试
 15) 备份当前 iptables 规则
 16) 查看备份列表
 17) 从备份回滚
 18) 测试目标端口 TCP 可达性
 19) 保存当前规则

自检/DDNS/日志
 20) 安装自检/DDNS 刷新服务
 21) 卸载自检/DDNS 刷新服务
 22) 查看脚本日志
 23) 刷新域名/DDNS 转发

  0) 退出
```

## 注意事项

- 请使用 root 权限运行脚本。
- 修改防火墙规则前，建议先确认当前服务器的 SSH 端口不会被误删或阻断。
- 如果服务器使用云厂商安全组，还需要同时放行对应入站端口。
- 目标机器也需要允许来自转发服务器的访问。
- 域名/DDNS 目前使用 IPv4 A 记录，解析失败时会跳过该规则。
- UDP 可达性无法像 TCP 一样可靠检测，脚本中的测试提示仅供参考。
- 执行回滚会覆盖当前 `iptables` 规则，请谨慎操作。
