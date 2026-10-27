#!/bin/bash
# dae-ui v2 —— 官方 daed 增强部署（不再使用自研面板）
# 内容：daed 2.1.1 修复版（官方源码改 Web 登录流程 + 新增 Nebula 默认主题，
#   见下方 FIX_RELEASE 说明；内嵌 dae 内核 2.1.1 与其余部分与官方一致）+ 稳定性硬化
#   1) systemd drop-in：Restart=always（官方 on-abnormal 不覆盖 panic 退出与假死）
#   2) 看门狗 timer：每分钟探活 daed 的 HTTP，连续 2 次无响应自动重启（治“假死”）
# 适用：Debian / Ubuntu，x86_64 与 arm64（斐讯 N1 等 armbian 盒子），root 运行。
set -e
cd "$(dirname "$0")"

DAED_VERSION="2.1.1"
# 修复版安装包（本仓库 Release）：官方 v2.1.1 前端有登录死循环 bug——登录成功存入
# token 后，QueryProvider 按 endpoint|token 的 identity 重挂载整个界面，设置向导的
# 步骤状态被重置，nextStep() 失效，用户被弹回向导第 1 步、永远进不了面板。
# 修复版仅改 apps/web 的 Setup 登录处理（存 token 前先路由到根路径），其余与官方
# 源码逐一对应；包名与官方 installer 相同，.dgst 的 sha256 校验流程不变。
# fix2 另在 apps/web 新增 Nebula 深空蓝青主题并设为默认（原 8 套主题保留可切回），
# 并做圆角/阴影/背景渐变等质感打磨；后端与内核仍未动。
FIX_RELEASE="daed-2.1.1-fix2"
BASE="https://github.com/JBl9527/dae-ui/releases/download/${FIX_RELEASE}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：sudo bash install.sh" >&2; exit 1
fi
case "$(uname -m)" in
  x86_64)  DEB="installer-daed-linux-x86_64.deb" ;;
  aarch64) DEB="installer-daed-linux-arm64.deb" ;;
  *) echo "暂不支持的架构：$(uname -m)（修复版 .deb 只有 x86_64 与 arm64）" >&2; exit 1 ;;
esac
for cmd in curl systemctl dpkg sha256sum; do
  command -v "$cmd" >/dev/null || { echo "缺少命令：$cmd" >&2; exit 1; }
done

# ---------- 安装选项（向导 / 环境变量 / 默认值） ----------
# 终端交互运行时走问答向导；非交互（脚本调用）时用环境变量或默认值：
#   DAEDUI_ADMIN_USER=admin DAEDUI_ADMIN_PASS='你的密码' DAEDUI_PORT=2023 \
#   DAEDUI_WATCHDOG=1 DAEDUI_CLEAN_V1=1 DAEDUI_ROUTE=auto DAEDUI_AUTOGROUP=0 sudo -E bash install.sh
# ROUTE 取值：auto（探活后自动选）/ direct（GitHub 直连）/ mirror（ghfast 镜像）
# 只补建地区分组（不重装）：sudo bash install.sh --autogroup
ADMIN_USER="${DAEDUI_ADMIN_USER:-admin}"
ADMIN_PASS="${DAEDUI_ADMIN_PASS:-}"
PORT="${DAEDUI_PORT:-2023}"
WANT_WATCHDOG="${DAEDUI_WATCHDOG:-1}"
CLEAN_V1="${DAEDUI_CLEAN_V1:-1}"
ROUTE="${DAEDUI_ROUTE:-auto}"
AUTOGROUP="${DAEDUI_AUTOGROUP:-0}"

# JSON 字符串值转义（一层）。GraphQL 报文里的值要连过两层解析，调用处须套两遍（见建号处）。
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'; }

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

if [ "${1:-}" != "--autogroup" ] && [ -t 0 ] && [ -t 1 ]; then
  echo
  echo "===== 安装向导（直接回车用默认值） ====="
  ask "1) 面板管理员用户名" "$ADMIN_USER" ADMIN_USER
  while :; do
    printf '2) 面板管理员密码（留空 = 装完按 README 手动建号）: ' > /dev/tty
    read -r -s _p1 < /dev/tty || _p1=""; echo > /dev/tty
    if [ -z "$_p1" ]; then ADMIN_PASS=""; break; fi
    printf '   再输入一次确认: ' > /dev/tty
    read -r -s _p2 < /dev/tty || _p2=""; echo > /dev/tty
    if [ "$_p1" != "$_p2" ]; then
      echo "   两次密码不一致，请重输" > /dev/tty
      continue
    fi
    # 密码规则取后端与官方 UI 的交集：后端要求含字母+数字、≥6 位；
    # 官方 UI 的登录/注册表单只接受 6~20 位，超长密码建得出却登不进，必须在向导就拦住
    if [ "${#_p1}" -lt 6 ] || [ "${#_p1}" -gt 20 ] || ! printf '%s' "$_p1" | grep -q '[A-Za-z]' || ! printf '%s' "$_p1" | grep -q '[0-9]'; then
      echo "   密码不合规：需含字母+数字、6~20 位（太短太长、纯字母/纯数字都不行），请重输" > /dev/tty
      continue
    fi
    ADMIN_PASS="$_p1"; break
  done
  unset _p1 _p2
  ask "3) 面板监听端口" "$PORT" PORT
  ask_yn "4) 安装假死看门狗（每分钟探活，假死自动重启）" "$WANT_WATCHDOG" WANT_WATCHDOG
  ask_yn "5) 清理旧版 v1 自研面板/独立 dae 残留" "$CLEAN_V1" CLEAN_V1
  ask "6) 下载线路（auto 自动 / direct 直连 / mirror 镜像）" "$ROUTE" ROUTE
  ask_yn "7) 装完自动按地区建分组（香港/美国/台湾/日本/新加坡/韩国/其他）" "$AUTOGROUP" AUTOGROUP
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
echo "  端口：$PORT ｜ 看门狗：$([ "$WANT_WATCHDOG" = "1" ] && echo '开' || echo '关') ｜ 清理 v1：$([ "$CLEAN_V1" = "1" ] && echo '是' || echo '否') ｜ 线路：$ROUTE ｜ 自动建组：$([ "$AUTOGROUP" = "1" ] && echo '开' || echo '关')"

# ---------- 按地区自动建分组 ----------
# 原理：daed 的组可按「订阅 + 节点名正则」绑定（groupAddSubscriptions，后端是 upsert，
# 重跑只会刷新正则与新订阅绑定，不会重复建组）。六个地区组用正则，订阅更新时新节点
# 自动归组；「其他」没有排除型正则可用，把未被六组认领的节点逐个钉入（groupAddNodes），
# 订阅更新后重跑本功能（--autogroup）会先清旧钉选再重算。
# 组名受 daed 限制只能是英文标识符（dae 配置语法，路由按名引用），故用英文名
REGION_NAMES=("HongKong" "USA" "Taiwan" "Japan" "Singapore" "Korea")
REGION_REGEX=(
  '香港|Hong Kong|🇭🇰|(^|[^A-Za-z])HK([^A-Za-z]|$)'
  '美国|美國|United States|🇺🇸|(^|[^A-Za-z])(US|USA)([^A-Za-z]|$)|洛杉矶|洛杉磯|硅谷|Silicon Valley'
  '台湾|台灣|Taiwan|🇹🇼|(^|[^A-Za-z])TW([^A-Za-z]|$)'
  '日本|Japan|🇯🇵|(^|[^A-Za-z])JP([^A-Za-z]|$)|东京|東京|大阪'
  '新加坡|Singapore|🇸🇬|(^|[^A-Za-z])SG([^A-Za-z]|$)|狮城|獅城'
  '韩国|韓國|Korea|🇰🇷|(^|[^A-Za-z])KR([^A-Za-z]|$)|首尔|首爾'
)

json_id_list() { # 每行一个 id，输出 \"id1\",\"id2\" 形式（引号带反斜杠，供拼进 GraphQL 的 JSON 字符串；切勿用裸引号，会撑破 JSON）
  local _out="" _id _bs='\'
  while IFS= read -r _id || [ -n "$_id" ]; do
    [ -z "$_id" ] && continue
    _out="${_out}${_bs}\"${_id}${_bs}\","
  done
  printf '%s' "${_out%,}"
}

gql() { # $1=报文 $2=token(可空)，输出响应原文，网络失败输出空
  if [ -n "${2:-}" ]; then
    curl -s -m 15 "http://127.0.0.1:$PORT/graphql" -H 'Content-Type: application/json' -H "Authorization: Bearer $2" -d "$1" || true
  else
    curl -s -m 15 "http://127.0.0.1:$PORT/graphql" -H 'Content-Type: application/json' -d "$1" || true
  fi
}

do_autogroup() {
  echo "== 自动按地区建分组 =="
  if [ -z "$ADMIN_PASS" ]; then
    echo "  未提供管理员密码，拿不到面板接口令牌，本次跳过。导入订阅后可补跑："
    echo "    DAEDUI_ADMIN_PASS='你的密码' sudo -E bash install.sh --autogroup"
    return 0
  fi
  local _U _P PAYLOAD RESP TOKEN SUB_IDS SUB_JSON GROUP_TOKENS
  _U="$(json_esc "$(json_esc "$ADMIN_USER")")"
  _P="$(json_esc "$(json_esc "$ADMIN_PASS")")"
  PAYLOAD='{"query":"query { token(username: \"'"${_U}"'\", password: \"'"${_P}"'\") }"}'
  RESP="$(gql "$PAYLOAD")"
  TOKEN="$(printf '%s' "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$TOKEN" ]; then
    echo "  登录面板接口失败（账号或密码不对？），跳过自动建组。返回：${RESP:-无响应}"
    return 0
  fi
  RESP="$(gql '{"query":"query { subscriptions { id } }"}' "$TOKEN")"
  SUB_IDS="$(printf '%s' "$RESP" | grep -o '"id":"[^"]*"' | sed 's/"id":"//; s/"$//' || true)"
  if [ -z "$SUB_IDS" ]; then
    echo "  尚无订阅，跳过建组。先在面板导入订阅，再运行：sudo bash install.sh --autogroup"
    return 0
  fi
  SUB_JSON="$(printf '%s\n' "$SUB_IDS" | json_id_list)"
  RESP="$(gql '{"query":"query { groups { id name } }"}' "$TOKEN")"
  GROUP_TOKENS="$(printf '%s' "$RESP" | grep -o '"id":"[^"]*"\|"name":"[^"]*"' || true)"

  find_or_create_group() { # $1=组名，打印组 id（失败打印空）
    local _name="$1" _gid _N _resp
    _gid="$(printf '%s\n' "$GROUP_TOKENS" | awk -F'"' -v want="$_name" '
      /^"id":/ { id=$4 }
      /^"name":/ { if ($4==want) { print id; exit } }')"
    if [ -z "$_gid" ]; then
      _N="$(json_esc "$(json_esc "$_name")")"
      _resp="$(gql '{"query":"mutation { createGroup(name: \"'"${_N}"'\", policy: min_moving_avg) { id } }"}' "$TOKEN")"
      _gid="$(printf '%s' "$_resp" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//; s/"$//' || true)"
      [ -z "$_gid" ] && echo "  [详情] 建组 ${_name} 返回：${_resp:-无响应}" >&2
    fi
    printf '%s' "$_gid"
  }

  local i gname gregex gid _G _R
  for i in "${!REGION_NAMES[@]}"; do
    gname="${REGION_NAMES[$i]}"; gregex="${REGION_REGEX[$i]}"
    gid="$(find_or_create_group "$gname")"
    if [ -z "$gid" ]; then echo "  [跳过] 「$gname」组创建失败"; continue; fi
    _G="$(json_esc "$(json_esc "$gid")")"
    _R="$(json_esc "$(json_esc "$gregex")")"
    RESP="$(gql '{"query":"mutation { groupAddSubscriptions(id: \"'"${_G}"'\", subscriptionIDs: ['"${SUB_JSON}"'], nameFilterRegex: \"'"${_R}"'\") }"}' "$TOKEN")"
    case "$RESP" in
      *'"groupAddSubscriptions"'*) echo "  「$gname」组就绪（正则绑定全部订阅）" ;;
      *) echo "  [警告] 「$gname」绑定订阅返回异常：${RESP:-无响应}" ;;
    esac
  done

  # 「其他」：逐个订阅拉节点（daed 的 nodes 查询不带 subscriptionId 时只返回无订阅的
  # 独立节点，订阅节点必须按订阅查），本地扣掉被六个地区正则认领的，剩下的钉入
  local TOTAL_ALL NODE_TOKENS LINES LEFTOVER_IDS LEFT TOTAL nid nname claimed r _line _sid _resp
  TOTAL_ALL=0; NODE_TOKENS=""
  for _sid in $SUB_IDS; do
    _resp="$(gql '{"query":"query { nodes(subscriptionId: \"'"${_sid}"'\", first: 2000) { totalCount edges { id name } } }"}' "$TOKEN")"
    _cnt="$(printf '%s' "$_resp" | sed -n 's/.*"totalCount":\([0-9]*\).*/\1/p' | head -1)"
    [ -n "$_cnt" ] && TOTAL_ALL=$((TOTAL_ALL + _cnt))
    NODE_TOKENS="${NODE_TOKENS}
$(printf '%s' "$_resp" | grep -o '"id":"[^"]*"\|"name":"[^"]*"' || true)"
  done
  LINES="$(printf '%s\n' "$NODE_TOKENS" | awk -F'"' '
    /^"id":/ { id=$4 }
    /^"name":/ { print id "\t" $4 }')"
  LEFTOVER_IDS=""; LEFT=0; TOTAL=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    nid="${_line%%$'\t'*}"; nname="${_line#*$'\t'}"
    TOTAL=$((TOTAL+1)); claimed=0
    for r in "${REGION_REGEX[@]}"; do
      if printf '%s' "$nname" | grep -Eq "$r"; then claimed=1; break; fi
    done
    if [ "$claimed" = "0" ]; then
      LEFT=$((LEFT+1))
      LEFTOVER_IDS="${LEFTOVER_IDS} ${nid}"
    fi
  done <<EOF
$LINES
EOF
  gid="$(find_or_create_group "Others")"
  if [ -n "$gid" ]; then
    _G="$(json_esc "$(json_esc "$gid")")"
    # 先清掉该组旧的逐个钉选（订阅更新后节点 id 会变），再钉入本次算出的
    RESP="$(gql '{"query":"query { groups(id: \"'"${_G}"'\") { nodes { id } } }"}' "$TOKEN")"
    local OLD_IDS OLD_JSON
    OLD_IDS="$(printf '%s' "$RESP" | grep -o '"id":"[^"]*"' | sed 's/"id":"//; s/"$//' || true)"
    OLD_JSON="$(printf '%s\n' "$OLD_IDS" | json_id_list)"
    if [ -n "$OLD_JSON" ]; then
      gql '{"query":"mutation { groupDelNodes(id: \"'"${_G}"'\", nodeIDs: ['"${OLD_JSON}"']) }"}' "$TOKEN" > /dev/null
    fi
    if [ "$LEFT" -gt 0 ]; then
      local LEFTOVER_JSON
      LEFTOVER_JSON="$(printf '%s\n' "$LEFTOVER_IDS" | tr ' ' '\n' | json_id_list)"
      RESP="$(gql '{"query":"mutation { groupAddNodes(id: \"'"${_G}"'\", nodeIDs: ['"${LEFTOVER_JSON}"']) }"}' "$TOKEN")"
      case "$RESP" in
        *'"groupAddNodes"'*) : ;;
        *) echo "  [警告] 「Others」钉入节点返回异常：${RESP:-无响应}" ;;
      esac
    fi
    echo "  「Others」组就绪：$LEFT 个未被六地区认领的节点（本次共扫描 $TOTAL 个）"
    if [ -n "$TOTAL_ALL" ] && [ "$TOTAL_ALL" -gt "$TOTAL" ] 2>/dev/null; then
      echo "  [提示] 节点总数 $TOTAL_ALL 超过单次拉取上限，本次只处理前 $TOTAL 个；节点特别多时「其他」可能不全"
    fi
  else
    echo "  [跳过] 「Others」组创建失败"
  fi
  echo "  提示：之后新增订阅或订阅大批量更新节点后，重跑 sudo bash install.sh --autogroup 即可刷新（六地区组是正则绑定、自动纳新，主要是补「其他」与新订阅的绑定）"
}

if [ "${1:-}" = "--autogroup" ]; then
  if [ -z "$ADMIN_PASS" ] && [ -t 0 ]; then
    printf '面板管理员用户名 [%s]: ' "$ADMIN_USER" > /dev/tty
    read -r _ans < /dev/tty || _ans=""; [ -n "$_ans" ] && ADMIN_USER="$_ans"
    printf '面板管理员密码: ' > /dev/tty
    read -r -s ADMIN_PASS < /dev/tty || ADMIN_PASS=""; echo > /dev/tty
    printf '面板监听端口 [%s]: ' "$PORT" > /dev/tty
    read -r _ans < /dev/tty || _ans=""; [ -n "$_ans" ] && PORT="$_ans"
  fi
  do_autogroup
  exit 0
fi

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

echo "== 下载 daed v${DAED_VERSION} 修复版（${FIX_RELEASE}，本仓库 Release）=="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
dl() {
  # 国内家宽连 GitHub 有两种死法：连不上、或连得上但龟速（资源 CDN 只有几十 KB/s）。
  # 对策：auto 先对“真正的 .deb 地址”做 1 字节探活；下载带断点续传（-C -），
  # 直连若持续低于 ~40KB/s 就中止并换镜像续传，而不是从零重下、干等超时。
  local MIRROR="https://ghfast.top/"
  local PREFIX=""
  case "$ROUTE" in
    mirror) PREFIX="$MIRROR"; echo "  使用 ghfast 镜像（安装选项）" ;;
    direct) echo "  使用 GitHub 直连（安装选项）" ;;
    *)
      if curl -fsSL -m 12 -o /dev/null -r 0-0 "$BASE/$DEB" 2>/dev/null; then
        echo "  GitHub 直连可用"
      else
        PREFIX="$MIRROR"
        echo "  GitHub 直连不通，改走 ghfast 镜像"
      fi ;;
  esac
  curl -fL -C - --retry 2 --speed-limit 40960 --speed-time 30 -m 1200 -o "$TMP/$DEB" "${PREFIX}$BASE/$DEB" \
    || curl -fL -C - --retry 2 -m 1200 -o "$TMP/$DEB" "${MIRROR}$BASE/$DEB" \
    || { rm -f "$TMP/$DEB"; curl -fL --retry 2 -m 1200 -o "$TMP/$DEB" "${MIRROR}$BASE/$DEB"; }
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
  echo "  [警告] 未取到 .dgst，跳过完整性校验"
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
    *'too weak password'*)   ACCOUNT_NOTE="密码被后端拒绝（需含字母+数字、至少 6 位）：用合规密码重跑向导，或按 README 第 0 步手动建号" ;;
    *'a user already exists'*) ACCOUNT_NOTE="设备上已有账号，本次未改动（改密码：界面内修改，或终端 daed resetpass -c /etc/daed）" ;;
    *'"data":{"createUser"'*) ACCOUNT_NOTE="管理员账号已自动建好：$ADMIN_USER —— 打开界面直接登录" ;;
    *)                      ACCOUNT_NOTE="自动建号未成功（返回：${RESP:-无响应}），按 README 第 0 步手动建号" ;;
  esac
  echo "  $ACCOUNT_NOTE"
fi
if [ "$AUTOGROUP" = "1" ] && [ -z "${DAEDUI_SKIP_HEALTHCHECK:-}" ]; then
  do_autogroup
fi
unset ADMIN_PASS _p1 _p2 2>/dev/null || true

echo
echo "安装完成：$(daed -v 2>/dev/null || echo daed)"
echo "  管理界面：http://${IP:-<本机IP>}:$PORT"
echo "  注意：daed 运行时会接管本机 DNS；界面里配好订阅与 DNS 之前，本机域名解析可能暂时不可用"
echo "        （用 IP 开界面不受影响；需要先上网拉代码时先 systemctl stop daed）"
if [ -n "$ACCOUNT_NOTE" ]; then
  echo "  $ACCOUNT_NOTE"
fi
echo "  接下来（详见 README）："
if [ -z "${ACCOUNT_NOTE}" ]; then
  echo "    1) 首次打开界面前先建号：按 README「首次设置清单」第 0 步用 curl 建第一个管理员"
fi
echo "    · 导入订阅 → 在 Orchestrate 里编排策略组（选了自动建组但当时没订阅的：导入后运行 sudo bash install.sh --autogroup 补建）"
echo "    · 按 README 把 DNS 改成 TCP 版（重要，治断流）"
echo "    · 旁路模式：在 global 配置里填 lan_interface（如 ens18），设备网关/DNS 指向本机"
