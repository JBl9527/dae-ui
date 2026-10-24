#!/bin/bash
# dae-ui installer (x86_64, systemd based distros: Ubuntu / Debian / armbian-x86)
# Installs: official dae binary (pinned) + geo data + dae-ui panel.
set -e

DAE_VERSION="${DAE_VERSION:-v2.1.1}"
PANEL_DIR=/usr/local/dae-ui
PANEL_PORT="${DAEUI_PORT:-9623}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：sudo bash install.sh" >&2; exit 1
fi
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  echo "当前版本仅支持 x86_64，你的架构是 $ARCH" >&2; exit 1
fi
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "需要 systemd" >&2; exit 1; }

echo "== 内核 eBPF 预检 =="
WARN=0
if [ ! -f /sys/kernel/btf/vmlinux ]; then
  echo "  [警告] 未发现内核 BTF (/sys/kernel/btf/vmlinux)，dae 可能无法启动"
  WARN=1
fi
if [ -r /proc/config.gz ]; then
  for opt in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF CONFIG_BPF_JIT; do
    if ! zcat /proc/config.gz | grep -q "^$opt=y"; then
      echo "  [警告] 内核选项 $opt 未开启，dae 可能无法启动"; WARN=1
    fi
  done
fi
[ "$WARN" = "0" ] && echo "  内核预检通过"

echo "== 安装 dae $DAE_VERSION =="
if [ -x /usr/bin/dae ] && /usr/bin/dae --version 2>/dev/null | grep -q "${DAE_VERSION#v}"; then
  echo "  已安装同版本，跳过下载"
else
  PKG="dae-linux-x86_64.tar.xz"
  URL="https://github.com/daeuniverse/dae/releases/download/${DAE_VERSION}/${PKG}"
  TMP="$(mktemp -d)"
  echo "  下载 $URL"
  if ! curl -fL --retry 2 -o "$TMP/$PKG" "$URL"; then
    echo "  GitHub 直连失败，尝试镜像…"
    curl -fL --retry 2 -o "$TMP/$PKG" "https://ghfast.top/${URL}"
  fi
  # tar 包是文件系统覆盖结构：usr/bin/dae、usr/share/dae/*.dat、etc/dae/example.dae、dae.service
  tar -xJf "$TMP/$PKG" -C /
  rm -rf "$TMP"
  systemctl daemon-reload
  echo "  dae 已安装：$(/usr/bin/dae --version 2>/dev/null | head -1)"
fi
# dae 服务不设开机自启：首次在面板里加好订阅、点“应用配置”后再启动，避免空配置启动失败
systemctl disable dae >/dev/null 2>&1 || true

echo "== 安装 dae-ui 面板 =="
mkdir -p "$PANEL_DIR/data" "$PANEL_DIR/static"
cp -f app.py "$PANEL_DIR/app.py"
cp -f static/index.html "$PANEL_DIR/static/index.html"
cp -f dae-ui.service /etc/systemd/system/dae-ui.service
systemctl daemon-reload
systemctl enable dae-ui >/dev/null 2>&1 || true
systemctl restart dae-ui

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "安装完成。"
echo "  面板地址：http://${IP:-<本机IP>}:${PANEL_PORT}"
echo "  使用顺序：添加订阅 → 拉取 → 配置策略组 → 保存并应用配置 → 启动 dae"
echo "  旁路网关模式：在面板里填 LAN 网卡名（如 eth0），局域网设备网关指向本机 IP"
echo "  注意：面板无登录鉴权，不要暴露到公网"
