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

# ---------- 安装选项（向导 / 环境变量 / 默认值） ----------
# 终端交互运行时走问答向导；非交互（脚本调用）时用环境变量或默认值：
#   DAEDUI_ADMIN_USER=admin DAEDUI_ADMIN_PASS='你的密码' DAEDUI_PORT=2023 \
#   DAEDUI_WATCHDOG=1 DAEDUI_CLEAN_V1=1 DAEDUI_ROUTE=auto sudo -E bash install.sh
# ROUTE 取值：auto（探活后自动选）/ direct（GitHub 直连）/ mirror（ghfast 镜像）
ADMIN_USER="${DAEDUI_ADMIN_USER:-admin}"
ADMIN_PASS="${DAEDUI_ADMIN_PASS:-}"
PORT="${DAEDUI_PORT:-2023}"
WANT_WATCHDOG="${DAEDUI_WATCHDOG:-1}"
CLEAN_V1="${DAEDUI_CLEAN_V1:-1}"
ROUTE="${DAEDUI_ROUTE:-auto}"

ask() { # 提示 默认值 目标变量名
  local _p="$1" _d="$2" _v="$3" _ans
  printf '%s [%s]: ' "$_p" "$_d" > /dev/tty
  read -r _ans < /dev/tty || _ans=""
  [ -z "$_ans" ] && _ans="$_d"
  printf -v "$_v" '%s' "$_ans"
}
ask_yn() { # 提示 默认(1/0) 目标变量名
  local _p="$1" _d="$2" _v="$3" _ans _def="n"
  [ "$_d" = "1" ] && _def="y"
  printf '%s [y/n，默认 %s]: ' "$_p" "$_def" > /dev/tty
  read -r _ans < /dev/tty || _ans=""
  case "${_ans:-$_def}" in
    y|Y) printf -v "$_v" '1' ;;
    *)   printf -v "$_v" '0' ;;
  esac
}

if [ -t 0 ] && [ -t 1 ]; then
  echo
  echo "===== 安装向导（直接回车用默认值） ====="
  ask "1) 面板管理员用户名" "$ADMIN_USER" ADMIN_USER
  while :; do
    printf '2) 面板管理员密码（留空 = 装完按 README 手动建号）: ' > /dev/tty
    read -r -s _p1 < /dev/tty || _p1=""; echo > /dev/tty
    if [ -z "$_p1" ]; then ADMIN_PASS=""; break; fi
    printf '   再输入一次确认: ' > /dev/tty
    read -r -s _p2 < /dev/tty || _p2=""; echo > /dev/tty
    if [ "$_p1" = "$_p2" ]; then ADMIN_PASS="$_p1"; break; fi
    echo "   两次密码不一致，请重输" > /dev/tty
  done
  unset _p1 _p2
  ask "3) 面板监听端口" "$PORT" PORT
  ask_yn "4) 安装假死看门狗（每分钟探活，假死自动重启）" "$WANT_WATCHDOG" WANT_WATCHDOG
  ask_yn "5) 清理旧版 v1 自研面板/独立 dae 残留" "$CLEAN_V1" CLEAN_V1
  ask "6) 下载线路（auto 自动 / direct 直连 / mirror 镜像）" "$ROUTE" ROUTE
fi

case "$PORT" in
  ''|*[!0-9]*) echo "[错误] 端口不合法：$PORT" >&2; exit 1 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[错误] 端口超出范围：$PORT" >&2; exit 1
fi
case "$ROUTE" in auto|direct|mirror) ;; *) ROUTE="auto" ;; esac

echo "== 本次安装选项 =="
echo "  管理员：$ADMIN_USER（$([ -n "$ADMIN_PASS" ] && echo '装完自动建号' || echo '未设密码，装后手动建号')）"
echo "  端口：$PORT ｜ 看门狗：$([ "$WANT_WATCHDOG" = "1" ] && echo '开' || echo '关') ｜ 清理 v1：$([ "$CLEAN_V1" = "1" ] && echo '是' || echo '否') ｜ 线路：$ROUTE"

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
  elif [ -t 0 ] && [ -t 1 ]; then
    _go="0"
    ask_yn "  预检未通过，仍要继续安装？" "0" _go
    if [ "$_go" != "1" ]; then echo "  已取消安装。" >&2; exit 1; fi
    echo "  已确认继续（风险自负）"
  else
    echo "  预检未通过，终止安装。确认内核有回移补丁可重跑：DAEDUI_FORCE=1 sudo -E bash install.sh" >&2
    exit 1
  fi
else
  echo "  内核预检通过（$KREL，BTF 存在）"
fi

if [ "$CLEAN_V1" = "1" ]; then
  echo "== 清理旧组件（v1 自研面板 / 独立版 dae，如有） =="
  systemctl disable --now dae-ui >/dev/null 2>&1 || true
  systemctl disable --now dae >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/dae-ui.service /usr/lib/systemd/system/dae.service /usr/bin/dae
  rm -rf /usr/local/dae-ui /usr/share/dae
  # /etc/dae 是 v1 独立版 dae 的配置，daed 不用它；保留备份以防反悔
  if [ -d /etc/dae ] && [ ! -d /etc/dae.v1.bak ]; then mv /etc/dae /etc/dae.v1.bak; fi
else
  echo "== 跳过旧组件清理（安装选项） =="
fi

echo "== 下载官方 daed v${DAED_VERSION} =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
dl() {
  # 国内家宽直连 GitHub 常被掐（连接挂起数分钟）：auto 模式先 12 秒探活，不通直接走镜像。
  local MIRROR="https://ghfast.top/"
  local PREFIX=""
  case "$ROUTE" in
    mirror) PREFIX="$MIRROR"; echo "  使用 ghfast 镜像（安装选项）" ;;
    direct) echo "  使用 GitHub 直连（安装选项）" ;;
    *)
      if curl -fsS -m 12 -o /dev/null https://github.com/ 2>/dev/null; then
        echo "  GitHub 直连可用"
      else
        PREFIX="$MIRROR"
        echo "  GitHub 直连不通，改走 ghfast 镜像"
      fi ;;
  esac
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
if [ "$PORT" != "2023" ]; then
  # 自定义端口：在 drop-in 里覆盖官方 unit 的 ExecStart，加上 -l 监听参数
  {
    echo ""
    echo "# 安装向导指定的面板端口"
    echo "[Service]"
    echo "ExecStart="
    echo "ExecStart=/usr/bin/daed run -c /etc/daed/ -l 0.0.0.0:$PORT"
  } >> /etc/systemd/system/daed.service.d/10-hardening.conf
fi
if [ "$WANT_WATCHDOG" = "1" ]; then
  sed "s/__PORT__/$PORT/g" files/daed-watchdog.sh > /usr/local/bin/daed-watchdog.sh
  chmod +x /usr/local/bin/daed-watchdog.sh
  cp -f files/daed-watchdog.service /etc/systemd/system/daed-watchdog.service
  cp -f files/daed-watchdog.timer /etc/systemd/system/daed-watchdog.timer
fi
systemctl daemon-reload
if [ "$WANT_WATCHDOG" = "1" ]; then
  systemctl enable --now daed-watchdog.timer
else
  systemctl disable --now daed-watchdog.timer >/dev/null 2>&1 || true
fi
systemctl enable daed >/dev/null 2>&1 || true
systemctl restart daed

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "${DAEDUI_SKIP_HEALTHCHECK:-}" ]; then
  echo "== 等待 daed 就绪（最多 30 秒） =="
  OK=0
  for i in $(seq 1 30); do
    if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$PORT/"; then OK=1; break; fi
    sleep 1
  done
  if [ "$OK" != "1" ]; then
    echo "[错误] daed 未在 30 秒内就绪，状态如下：" >&2
    systemctl status daed --no-pager -n 5 >&2 || true
    echo "看日志：journalctl -u daed -n 50 --no-pager" >&2
    exit 1
  fi
fi

ACCOUNT_NOTE=""
if [ -n "$ADMIN_PASS" ] && [ -z "${DAEDUI_SKIP_HEALTHCHECK:-}" ]; then
  echo "== 创建面板管理员账号 =="
  json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'; }
  # JSON 里的 \" 必须以字面两字符进入报文：用单引号段拼装（单引号保留反斜杠），
  # 切勿把 \" 放进 printf 格式串——printf 会吃掉反斜杠，撑破 JSON。
  # 值要转义两层：先 GraphQL 字符串层（json_esc 一遍），再 JSON 层（再一遍），缺一层都会被解析器拒。
  _U="$(json_esc "$(json_esc "$ADMIN_USER")")"
  _P="$(json_esc "$(json_esc "$ADMIN_PASS")")"
  PAYLOAD='{"query":"mutation { createUser(username: \"'"${_U}"'\", password: \"'"${_P}"'\") }"}'
  RESP="$(printf '%s' "$PAYLOAD" \
    | curl -s -m 10 "http://127.0.0.1:$PORT/graphql" -H 'Content-Type: application/json' -d @- || true)"
  unset _U _P PAYLOAD
  case "$RESP" in
    *'a user already exists'*) ACCOUNT_NOTE="设备上已有账号，本次未改动（改密码：界面内修改，或终端 daed resetpass -c /etc/daed）" ;;
    *'"data":{"createUser"'*) ACCOUNT_NOTE="管理员账号已自动建好：$ADMIN_USER —— 打开界面直接登录" ;;
    *)                      ACCOUNT_NOTE="自动建号未成功（返回：${RESP:-无响应}），按 README 第 0 步手动建号" ;;
  esac
  echo "  $ACCOUNT_NOTE"
fi
unset ADMIN_PASS _p1 _p2 2>/dev/null || true

echo
echo "安装完成：$(daed -v 2>/dev/null || echo daed)"
echo "  管理界面：http://${IP:-<本机IP>}:$PORT"
if [ -n "$ACCOUNT_NOTE" ]; then
  echo "  $ACCOUNT_NOTE"
fi
echo "  接下来（详见 README）："
if [ -z "${ACCOUNT_NOTE}" ]; then
  echo "    1) 首次打开界面前先建号：按 README「首次设置清单」第 0 步用 curl 建第一个管理员"
fi
echo "    · 导入订阅 → 在 Orchestrate 里编排策略组"
echo "    · 按 README 把 DNS 改成 TCP 版（重要，治断流）"
echo "    · 旁路模式：在 global 配置里填 lan_interface（如 ens18），设备网关/DNS 指向本机"
