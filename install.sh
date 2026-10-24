#!/bin/bash
# dae-ui v2 —— 官方 daed 增强部署（不再使用自研面板）
# 内容：官方 daed 2.1.1（内嵌 dae 内核 2.1.1 + 官方新版 UI）+ 稳定性硬化
#   1) systemd drop-in：Restart=always（官方 on-abnormal 不覆盖 panic 退出与假死）
#   2) 看门狗 timer：每分钟探活 daed 的 HTTP，连续 2 次无响应自动重启（治“假死”）
# 适用：Debian / Ubuntu x86_64，root 运行。
set -e
cd "$(dirname "$0")"

DAED_VERSION="2.1.1"
DEB="installer-daed-linux-x86_64.deb"
BASE="https://github.com/daeuniverse/daed/releases/download/v${DAED_VERSION}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：sudo bash install.sh" >&2; exit 1
fi
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  echo "当前版本仅支持 x86_64，你的架构是 $ARCH" >&2; exit 1
fi
for cmd in curl systemctl dpkg sha256sum; do
  command -v "$cmd" >/dev/null || { echo "缺少命令：$cmd" >&2; exit 1; }
done

echo "== 内核 eBPF 预检 =="
if [ ! -f /sys/kernel/btf/vmlinux ]; then
  echo "  [警告] 未发现内核 BTF (/sys/kernel/btf/vmlinux)，dae 内核可能无法启动"
else
  echo "  内核预检通过"
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
  curl -fL --retry 2 -m 600 -o "$TMP/$DEB" "$BASE/$DEB" \
    || curl -fL --retry 2 -m 600 -o "$TMP/$DEB" "https://ghfast.top/$BASE/$DEB"
  curl -fsSL --retry 2 -m 60 -o "$TMP/$DEB.dgst" "$BASE/$DEB.dgst" \
    || curl -fsSL --retry 2 -m 60 -o "$TMP/$DEB.dgst" "https://ghfast.top/$BASE/$DEB.dgst" || true
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
echo "    1) 打开界面，首次使用先创建管理员账号"
echo "    2) 导入订阅 → 在 Orchestrate 里编排策略组"
echo "    3) 按 README 把 DNS 改成 TCP 版（重要，治断流）"
echo "    4) 旁路模式：在 global 配置里填 lan_interface（如 ens18），设备网关/DNS 指向本机"
