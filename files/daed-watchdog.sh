#!/bin/bash
# daed 看门狗（由 daed-watchdog.timer 每分钟调用）：
# 只处理“进程还在、但 HTTP 连续无响应”的假死；进程真退出由 systemd 的 Restart=always 负责。
STATE=/run/daed-watchdog.failcount
URL=http://127.0.0.1:2023/

systemctl is-active --quiet daed || exit 0

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
