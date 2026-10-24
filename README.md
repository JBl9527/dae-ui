# dae-ui v2 —— 官方 daed 增强部署

> v2 起本项目不再自研面板，改为部署**官方 daed**（daeuniverse/daed），
> 专治老版本 daed 用一段时间后“莫名断流 / 进程掉线”的问题。

## 组成

| 组件 | 说明 |
|---|---|
| 官方 daed **v2.1.1** | 内嵌 dae 内核 v2.1.1（最新）+ 官方新版 Web UI，官方 .deb 安装，sha256 对照官方 .dgst 校验 |
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
- 装完打开 `http://<机器IP>:2023`，首次使用先创建管理员账号。

## ARM / 斐讯 N1（armbian）

- 官方 v2.1.1 提供 arm64 的 .deb，install.sh 按 `uname -m` 自动选包，流程与 x86 完全一致。
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

## 卸载

```bash
sudo systemctl disable --now daed daed-watchdog.timer
sudo dpkg -r daed
sudo rm -rf /etc/systemd/system/daed.service.d /etc/systemd/system/daed-watchdog.* \
            /usr/local/bin/daed-watchdog.sh /etc/daed
sudo systemctl daemon-reload
```

## 版本说明

- 内核与 UI 均锁定官方 **v2.1.1**（dae / daed 同步发布）。升级时改 `install.sh` 里的
  `DAED_VERSION` 后重跑即可。
- v1 的自研面板代码已从本仓库移除（git 历史里仍可找回）。
