#!/bin/bash
# dae-ui v2 —— 官方 daed 增强部署（不再使用自研面板）
# 内容：官方 daed 2.1.1（内嵌 dae 内核 2.1.1 + 官方新版 UI）+ 稳定性硬化
#   1) systemd drop-in：Restart=always（官方 on-abnormal 不覆盖 panic 退出与假死）
#   2) 看门狗 timer：每分钟探活 daed 的 HTTP，连续 2 次无响应自动重启（治“假死”）
# 适用：Debian / Ubuntu，x86_64 与 arm64（斐讯 N1 等 armbian 盒子），root 运行。
set -e
cd "$(dirname "$0")"

DAED_VERSION="2.1.1"
BASE="https://github.com/daeuniverse/daed/releases/download/v${DAED_VERSION}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：sudo bash install.sh" >&2; exit 1
fi
case "$(uname -m)" in
  x86_64)  DEB="installer-daed-linux-x86_64.deb" ;;
  aarch64) DEB="installer-daed-linux-arm64.deb" ;;
  *) echo "暂不支持的架构：$(uname -m)（官方 v${DAED_VERSION} 的 .deb 只有 x86_64 与 arm64）" >&2; exit 1 ;;
esac
for cmd in curl systemctl dpkg sha256sum; do
  command -v "$cmd" >/dev/null || { echo "缺少命令：$cmd" >&2; exit 1; }
done

echo "== 内核 eBPF 预检 =="
# dae 2.x 路由依赖 bpf_loop（内核 ≥5.17）与 vmlinux BTF（CO-RE 加载），缺一必启动失败。
# 个别发行版内核有回移补丁，确认没问题可用 DAEDUI_FORCE=1 跳过预检。
KREL="$(uname -r)"
KMAJ="$(echo "$KREL" | cut -d. -f1 | tr -cd '0-9')"
KMIN="$(echo "$KREL" | cut -d. -f2 | tr -cd '0-9')"
PREFAIL=0
if [ "${KMAJ:-0}" -lt 5 ] || { [ "${KMAJ:-0}" -eq 5 ] && [ "${KMIN:-0}" -lt 17 ]; }; then
  echo "  [错误] 内核 $KREL 低于 5.17：dae 2.x 需要 bpf_loop，低版本会直接启动失败。" >&2
  echo "         armbian/斐讯 N1 请先升级到 6.x 内核（如 ophub 内核）再重跑本脚本。" >&2
  PREFAIL=1
fi
if [ ! -f /sys/kernel/btf/vmlinux ]; then
  echo "  [错误] 未发现内核 BTF（/sys/kernel/btf/vmlinux 不存在）：dae 用 CO-RE 加载 eBPF，缺 BTF 无法启动。" >&2
  echo "         请换带 CONFIG_DEBUG_INFO_BTF 的内核（6.x 主线/armbian 官方内核一般自带）。" >&2
  PREFAIL=1
fi
if [ "$PREFAIL" = "1" ]; then
  if [ -n "${DAEDUI_FORCE:-}" ]; then
    echo "  DAEDUI_FORCE 已设置，跳过预检继续（风险自负）"
  else
    echo "  预检未通过，终止安装。确认内核有回移补丁可重跑：DAEDUI_FORCE=1 sudo -E bash install.sh" >&2
    exit 1
  fi
else
  echo "  内核预检通过（$KREL，BTF 存在）"
fi

echo "== 清理旧组件（v1 自研面板 / 独立版 dae，如有） =="
systemctl disable --now dae-ui >/dev/null 2>&1 || true
systemctl disable --now dae >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dae-ui.service /usr/lib/systemd/system/dae.service /usr/bin/dae
rm -rf /usr/local/dae-ui /usr/share/dae
# /etc/dae 是 v1 独立版 dae 的配置，daed 不用它；保留备份以防反悔
if [ -d /etc/dae ] && [ ! -d /etc/dae.v1.bak ]; then mv /etc/dae /etc/dae.v1.bak; fi

echo "== 下载官方 daed v${DAED_VERSION} =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
dl() {
  # 国内家宽直连 GitHub 常被掐（连接挂起数分钟）：先 12 秒探活，不通直接走镜像，不在死路上耗。
  local MIRROR="https://ghfast.top/"
  local PREFIX=""
  if curl -fsS -m 12 -o /dev/null https://github.com/ 2>/dev/null; then
    echo "  GitHub 直连可用"
  else
    PREFIX="$MIRROR"
    echo "  GitHub 直连不通，改走 ghfast 镜像"
  fi
  curl -fL --retry 2 -m 600 -o "$TMP/$DEB" "${PREFIX}$BASE/$DEB" \
    || curl -fL --retry 2 -m 600 -o "$TMP/$DEB" "${MIRROR}$BASE/$DEB"
  curl -fsSL --retry 2 -m 60 -o "$TMP/$DEB.dgst" "${PREFIX}$BASE/$DEB.dgst" \
    || curl -fsSL --retry 2 -m 60 -o "$TMP/$DEB.dgst" "${MIRROR}$BASE/$DEB.dgst" || true
}
dl
if [ -s "$TMP/$DEB.dgst" ]; then
  EXPECT="$(awk '$3=="sha256"{print $1}' "$TMP/$DEB.dgst")"
  ACTUAL="$(sha256sum "$TMP/$DEB" | awk '{print $1}')"
  if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then
    echo "  sha256 校验通过"
  else
    echo "  [错误] sha256 校验失败：期望 $EXPECT，实际 $ACTUAL" >&2; exit 1
  fi
else
  echo "  [警告] 未取到官方 .dgst，跳过完整性校验"
fi

echo "== 安装 daed =="
dpkg -i "$TMP/$DEB" || apt-get install -f -y
mkdir -p /etc/daed

echo "== 写入稳定性硬化 =="
mkdir -p /etc/systemd/system/daed.service.d
cp -f files/10-hardening.conf /etc/systemd/system/daed.service.d/10-hardening.conf
cp -f files/daed-watchdog.sh /usr/local/bin/daed-watchdog.sh
chmod +x /usr/local/bin/daed-watchdog.sh
cp -f files/daed-watchdog.service /etc/systemd/system/daed-watchdog.service
cp -f files/daed-watchdog.timer /etc/systemd/system/daed-watchdog.timer
systemctl daemon-reload
systemctl enable --now daed-watchdog.timer
systemctl enable daed >/dev/null 2>&1 || true
systemctl restart daed

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "${DAEDUI_SKIP_HEALTHCHECK:-}" ]; then
  echo "== 等待 daed 就绪（最多 30 秒） =="
  OK=0
  for i in $(seq 1 30); do
    if curl -fsS -m 3 -o /dev/null http://127.0.0.1:2023/; then OK=1; break; fi
    sleep 1
  done
  if [ "$OK" != "1" ]; then
    echo "[错误] daed 未在 30 秒内就绪，状态如下：" >&2
    systemctl status daed --no-pager -n 5 >&2 || true
    echo "看日志：journalctl -u daed -n 50 --no-pager" >&2
    exit 1
  fi
fi

echo
echo "安装完成：$(daed -v 2>/dev/null || echo daed)"
echo "  管理界面：http://${IP:-<本机IP>}:2023"
echo "  接下来（详见 README）："
echo "    1) 打开界面；若登录报 incorrect username or password，是还没建账号："
echo "       先按 README「首次设置清单」第 0 步用 curl 建第一个管理员账号再登录"
echo "    2) 导入订阅 → 在 Orchestrate 里编排策略组"
echo "    3) 按 README 把 DNS 改成 TCP 版（重要，治断流）"
echo "    4) 旁路模式：在 global 配置里填 lan_interface（如 ens18），设备网关/DNS 指向本机"
