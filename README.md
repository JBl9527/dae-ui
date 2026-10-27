# dae-ui v2 —— 官方 daed 增强部署

> v2 起本项目不再自研面板，改为部署**官方 daed**（daeuniverse/daed），
> 专治老版本 daed 用一段时间后“莫名断流 / 进程掉线”的问题。

## 组成

| 组件 | 说明 |
|---|---|
| daed **v2.1.1 修复版** | 官方源码构建，仅修复 Web 登录死循环（见下），内嵌 dae 内核 v2.1.1 + 官方新版 Web UI；.deb 在本仓库 Release，sha256 对照随包 .dgst 校验 |
| systemd 硬化 drop-in | 官方 unit 的 `Restart=on-abnormal` 不覆盖 panic 非零退出与进程假死 → 改 `Restart=always` |
| 看门狗 timer | 每分钟探活 `http://127.0.0.1:2023`，连续 2 次无响应（约 2 分钟）自动重启 daed，记录在 journal（tag `daed-watchdog`） |

新版 UI 原生自带：**流量显示**（Orchestrate 页的 Traffic Overview）、**节点延迟检测**（节点列表处），
策略组编排、订阅管理都在同一界面里。

## 安装

```bash
git clone https://github.com/JBl9527/dae-ui.git
cd dae-ui
sudo bash install.sh
```

- 适用 Debian / Ubuntu **x86_64 与 arm64**（含斐讯 N1 等 armbian 盒子，见下节）；重跑即升级/修复（幂等）。
- 若机器上装过 v1（自研面板 + 独立版 dae），install.sh 会自动停用并清理它们；
  v1 的 dae 配置目录会保留为 `/etc/dae.v1.bak`。
- 装完打开 `http://<机器IP>:2023`。
- ⚠️ daed 启动后会接管本机 DNS：完成界面配置（导入订阅 + 下面的 DNS 设置）之前，
  本机跑 git/curl 会报 `Could not resolve host`，属正常现象；需要先拉代码时先 `systemctl stop daed`，装完再配界面即可。

**安装向导**：在终端里运行时会先依次询问（回车即默认值）——
① 面板管理员用户名（默认 admin）② 面板管理员密码（留空 = 装后手动建号）
③ 面板监听端口（默认 2023）④ 是否装假死看门狗（默认 是）
⑤ 是否清理 v1 残留（默认 是）⑥ 下载线路（auto/direct/mirror，默认 auto）
⑦ 是否装完自动按地区建分组（默认 否，见下节）。
向导里设了密码的，装完会自动建好管理员账号（设备上已有账号则跳过、不改动），打开界面直接登录。
无人值守可用环境变量代替向导：`DAEDUI_ADMIN_USER`、`DAEDUI_ADMIN_PASS`、`DAEDUI_PORT`、
`DAEDUI_WATCHDOG=1/0`、`DAEDUI_CLEAN_V1=1/0`、`DAEDUI_ROUTE=auto/direct/mirror`、`DAEDUI_AUTOGROUP=1/0`（配合 `sudo -E`）。

## 按地区自动分组（向导第 7 问 / `--autogroup`）

节点多时挑节点费劲，可让脚本按节点名自动建七个地区组（策略统一 `min_moving_avg`）：

| 组名 | 节点名命中规则（正则，任一命中即归组） |
|---|---|
| `HongKong` | 香港 / Hong Kong / 🇭🇰 / HK |
| `USA` | 美国 / United States / 🇺🇸 / US / USA / 洛杉矶 / 硅谷 等 |
| `Taiwan` | 台湾 / Taiwan / 🇹🇼 / TW |
| `Japan` | 日本 / Japan / 🇯🇵 / JP / 东京 / 大阪 |
| `Singapore` | 新加坡 / Singapore / 🇸🇬 / SG / 狮城 |
| `Korea` | 韩国 / Korea / 🇰🇷 / KR / 首尔 |
| `Others` | 以上都没命中的节点 |

- 组名只能用英文：daed 的组名就是 dae 配置里的标识符（路由规则按名引用），后端强制
  `^[a-zA-Z_][-a-zA-Z0-9_…]*$`，中文名建不出来。
- 六个地区组是「订阅 + 正则」绑定：订阅更新进了新节点会自动归组，不用维护。
  `Others` 没有排除型正则可用，是把剩余节点逐个钉进去的：订阅大批量更新后重跑一次刷新。
- 时机：建组需要面板里**先有订阅**。装机时还没有订阅会直接跳过并提示；导入订阅后
  单独补跑即可，不必重装：`sudo bash install.sh --autogroup`（会问账号/密码/端口，
  也可用 `DAEDUI_ADMIN_*` 环境变量）。整个过程可重复运行：同名组跳过创建、只刷新
  绑定，`Others` 会先清旧钉选再重算，不会越跑越多。

## ARM / 斐讯 N1（armbian）

- 修复版同时提供 x86_64 与 arm64 的 .deb，install.sh 按 `uname -m` 自动选包，流程完全一致。
- **装之前先在盒子上验内核**（dae 2.x 的硬要求，不满足会在启动时直接报错）：

  ```bash
  uname -r                      # 需要 ≥ 5.17（路由用 bpf_loop），建议直接 6.x
  ls /sys/kernel/btf/vmlinux    # 必须存在（CO-RE 加载 eBPF 需要 BTF）
  ```

  两条都过才跑 install.sh（脚本里有同样的硬预检，不过会终止并说明原因；
  个别内核有回移补丁、确认能用的可 `DAEDUI_FORCE=1 sudo -E bash install.sh` 跳过）。
- N1 是 S905D（arm64）+ 2GB 内存，跑 daed 足够；首次启动加载 eBPF 会比 x86 稍慢，看门狗已留 2 分钟宽限。
- armbian 上网卡名一般是 `eth0`，`global` 配置里 `lan_interface` 按实际填（`ip -br a` 看）。

## 首次设置清单

0. **⚠️ 先建管理员账号（新版 UI 的坑）**：全新安装还没有任何账号，但向导第 2 步直接让你
   “登录”，输什么都会报 `incorrect username or password`。先在装机终端手动建第一个账号
   （把密码换成你自己的——后端密码策略：**必须含字母+数字、至少 6 位**，纯字母/纯数字会被拒并返回 `too weak password`），
   返回一长串 token 即成功，然后回界面用同样的账号密码登录：

   ```bash
   curl -s http://127.0.0.1:2023/graphql -H 'Content-Type: application/json' \
     -d '{"query":"mutation { createUser(username: \"admin\", password: \"改成你的密码\") }"}'
   ```

   （原理：后端只在“零用户”时开放 `createUser` 建号，UI 向导没有走这条路。已实测此流程。）

1. **导入订阅**：在界面里添加你的订阅链接，等待节点拉取完成。
2. **编排策略组**：在 Orchestrate 页建组、选节点（可先测延迟再选）。
3. **⚠️ 必改 DNS（治断流的关键）**：把配置里的 `dns` 段改成下面这样——
   国外 DNS 只走 TCP 且用纯 IPv4 地址。原因：机场类节点池普遍不支持 UDP 中继，
   默认的 UDP/双栈 DNS 经节点转发会间歇性卡死，表现就是“莫名断流”；
   另外 `dns.google` 这个名字会解析出 IPv6 目标，很多节点没有 IPv6 出口，同样卡。

   ```
   dns {
       upstream {
           alidns: 'udp://dns.alidns.com:53'
           googledns: 'tcp://8.8.8.8:53'
       }
       routing {
           request {
               qname(geosite:cn) -> alidns
               fallback: googledns
           }
           response {
               upstream(googledns) -> accept
               ip(geoip:private) && !qname(geosite:cn) -> googledns
               fallback: accept
           }
       }
   }
   ```

4. **旁路网关模式**：在 `global` 配置里填 `lan_interface`（如 `ens18`），
   局域网设备的网关和 DNS 都指向这台机器的 IP。

## 运维

```bash
systemctl status daed                 # 服务状态
journalctl -u daed -f                 # daed 日志
journalctl -t daed-watchdog           # 看门狗的探活/重启记录
daed resetpass -c /etc/daed           # 忘记管理员密码时重置（会给随机密码）
```

**排障：停掉 daed 后网络仍不通**（ping 通、TCP/UDP 全死、`Could not resolve host`）——
多半是 daed 被强杀后，它挂在网卡上的 TC eBPF 程序残留成了孤儿（`tc filter show dev eth0 ingress`
能看到 `daed_` 开头的 filter，进程已死、无人处理被 tproxy 的流量）。手动清：
`tc qdisc del dev eth0 clsact`（网卡名按实际）。看门狗已内置自动清理：daed 未运行时，
每分钟检查并摘除这类残留。

## 卸载

```bash
sudo systemctl disable --now daed daed-watchdog.timer
sudo dpkg -r daed
sudo rm -rf /etc/systemd/system/daed.service.d /etc/systemd/system/daed-watchdog.* \
            /usr/local/bin/daed-watchdog.sh /etc/daed
sudo systemctl daemon-reload
```

## 版本说明

- 内核与 UI 均锁定 **v2.1.1**（dae / daed 同步发布）。安装包为本仓库 Release 的
  `daed-2.1.1-fix2`：官方 v2.1.1 的 Web 前端在登录成功后会因 QueryProvider 按
  `endpoint|token` identity 重挂载整个界面，把设置向导的步骤状态重置，表现为
  「密码正确却永远回到向导第 1 步」。修复版改 `apps/web` 的 Setup 登录处理
  （存 token 之前先路由到根路径 `/`，让重挂载后的界面直接落到控制面板）；
  fix2 另新增 **Nebula 深空蓝青** 主题并设为默认（原 8 套主题保留，可在面板
  主题选择器切回；浏览器已存过主题选择时需手动点一次 Nebula），并做圆角、
  阴影、背景渐变等全局质感打磨。后端与内核未动。官方版本升级时改 `install.sh`
  里的 `DAED_VERSION` 后重跑即可，若官方仍未修复该 bug，需把同一补丁重新
  应用到新版本源码再构建。
- v1 的自研面板代码已从本仓库移除（git 历史里仍可找回）。
