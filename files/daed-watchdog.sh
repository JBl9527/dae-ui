#!/bin/bash
# daed 看门狗（由 daed-watchdog.timer 每分钟调用）：
# 1) daed 未运行时：清理网卡上残留的 daed TC eBPF 程序（孤儿程序会黑洞 TCP/UDP，详见下方）；
# 2) daed 运行时：只处理“进程还在、但 HTTP 连续无响应”的假死；进程真退出由 systemd 的 Restart=always 负责。
STATE=/run/daed-watchdog.failcount
URL=http://127.0.0.1:__PORT__/

if ! systemctl is-active --quiet daed; then
  # daed 若被强杀/异常退出，挂在网卡 clsact 上的 tproxy 程序可能残留：
  # 进程已死、无人处理被 tproxy 的流量 → ping 通但 TCP/UDP 全死、停服也恢复不了。
  # 此时代替 daed 做善后：发现任一网卡 ingress/egress 有 daed_ filter，就整表摘掉 clsact。
  for dev in $(ls /sys/class/net 2>/dev/null); do
    [ "$dev" = "lo" ] && continue
    if tc filter show dev "$dev" ingress 2>/dev/null | grep -q 'daed_' \
       || tc filter show dev "$dev" egress 2>/dev/null | grep -q 'daed_'; then
      logger -t daed-watchdog "$dev 上残留 daed TC 程序且 daed 未运行，清除 clsact"
      tc qdisc del dev "$dev" clsact 2>/dev/null || true
    fi
  done
  exit 0
fi

# 启动/重启后的 2 分钟内不检查，避免 eBPF 加载较慢时被误杀
PID=$(systemctl show -p MainPID --value daed 2>/dev/null || echo 0)
if [ "${PID:-0}" -gt 0 ] 2>/dev/null; then
  AGE=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')
  if [ -n "$AGE" ] && [ "$AGE" -lt 120 ]; then exit 0; fi
fi

if curl -fsS -m 5 -o /dev/null "$URL"; then
  echo 0 > "$STATE"
  exit 0
fi

N=$(cat "$STATE" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$STATE"
logger -t daed-watchdog "daed HTTP 无响应（第 $N 次）"
if [ "$N" -ge 2 ]; then
  logger -t daed-watchdog "连续 2 次无响应，判定假死，重启 daed"
  systemctl restart daed || true
  echo 0 > "$STATE"
fi
