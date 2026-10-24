# dae-ui

给 [dae](https://github.com/daeuniverse/dae)（eBPF 透明代理）用的轻量面板，只做三件事：

1. **导入订阅** —— 订阅链接写入配置的 `subscription` 段由 dae 自己拉取解析；面板同时解析一份用于展示节点名单。
2. **自定义策略组** —— 自动模式：按订阅范围 + 节点名关键词筛选，`min_moving_avg` 延迟选优；可给组绑定域名关键词，命中域名的流量走该组。
3. **切换节点** —— 手动模式：选中的节点以固定 tag 写入 `node` 段，策略组 `filter: name(<tag>) + policy: fixed(0)` 精确引用。应用配置走 `dae validate` 校验 + 热重载，不中断现有连接。

## 设计原则

面板与 dae 是**两个独立进程**（这是 daed 的教训：核心、Web、数据库塞一个进程，在小内存设备上进程一挂流量就失控）。面板只负责生成配置、校验、触发重载；面板自身崩溃不影响 dae 转发。dae 由官方 systemd 单元托管（Restart=on-abnormal）。

生成配置布局：

```
/etc/dae/config.dae          入口：include + global + dns
/etc/dae/config.d/panel.dae  subscription / node / group / routing
```

默认分流：私有地址直连、组播直连、UDP 443（QUIC）拦截、国内 IP/域名（geoip:cn / geosite:cn）直连，其余走默认策略组；DNS 国内走阿里、国外走 Google 并带响应防污染规则。

## 安装（x86_64，Ubuntu/Debian/armbian-x86 等 systemd 发行版）

```bash
git clone https://github.com/JBl9527/dae-ui.git
cd dae-ui
sudo bash install.sh
```

安装脚本会：检查内核 eBPF 条件（BTF 等）→ 安装官方 dae v2.1.1 发布包（含二进制、geoip/geosite 数据、官方 systemd 单元）→ 安装面板到 `/usr/local/dae-ui` 并启动（端口 9623）。

面板数据（订阅/策略组/设置）保存在 `/usr/local/dae-ui/data/`，与程序分离。

## 使用

打开 `http://<机器IP>:9623`：

1. 添加订阅（标签仅英文/数字/下划线）→ 拉取节点；
2. 在策略组里选自动/手动、筛节点或固定节点；自定义组可填域名关键词；
3. 点「保存并应用配置」→ 再点「启动」dae；
4. 旁路网关模式：在面板填 LAN 网卡名（如 `eth0`），局域网设备把网关指向本机 IP。只代理本机则留空。

## 注意

- 面板**无登录鉴权**，仅限局域网使用，不要暴露公网。
- 订阅仅支持链接列表 / Base64 格式（机场的通用/v2ray 格式），不支持 Clash YAML 订阅。
- dae 对内核有 eBPF 相关要求，PVE 里请给虚拟机用较新的 Ubuntu/Debian 官方内核；启动失败先看面板里的 dae 日志。
- 当前仅 x86_64。dae 本体为 AGPL-3.0，本面板仅通过配置文件与命令行管理 dae，不链接其代码。
