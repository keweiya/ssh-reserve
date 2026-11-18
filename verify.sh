#!/usr/bin/env bash
# =============================================================================
#  ssh-reserve 压力复验：负载打满时 ssh 还能不能连
#
#  做三件事：
#    1. 测空闲时的 ssh banner 延迟（基线）
#    2. 在 heavy.slice 里压满 CPU + 吃掉大半内存
#    3. 压测中再测延迟，并检查 sshd 的 cgroup 是否真的被保护
#
#  用法: bash verify.sh [--mem-mb 900] [--hold 60]
# =============================================================================
set -uo pipefail

MEM_MB=900
HOLD=45

while [[ $# -gt 0 ]]; do
  case $1 in
    --mem-mb) MEM_MB=${2:?}; shift 2 ;;
    --hold)   HOLD=${2:?}; shift 2 ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then echo "需要 root" >&2; exit 1; fi

# --- 自动发现端口 ---
MAIN_PORTS=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')
MAIN_PORT=$(echo "$MAIN_PORTS" | awk '{print $1}')
MAIN_PORT=${MAIN_PORT:-22}

probe() { # $1=port -> 毫秒 或 FAIL
  local s e
  s=$(date +%s%N)
  if exec 3<>"/dev/tcp/127.0.0.1/$1" 2>/dev/null; then
    head -c 24 <&3 >/dev/null 2>&1
    exec 3<&- 3>&- 2>/dev/null
    e=$(date +%s%N)
    printf '%d' $(( (e-s)/1000000 ))
  else
    printf 'FAIL'
  fi
}

mem_avail() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo; }
mem_pct()   { local a; a=$(mem_avail); printf '%d' $(( a * 100 / $(awk '/^MemTotal:/{printf "%d",$2/1024}' /proc/meminfo) )); }

cleanup() {
  systemctl stop sr-cpu sr-mem 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=================================================="
echo " 基线（空闲）"
echo "=================================================="
printf "  MemAvailable : %s MiB (%s%%)\n" "$(mem_avail)" "$(mem_pct)"
printf "  load         : %s\n" "$(cut -d' ' -f1-3 /proc/loadavg)"
printf "  ssh :%-6s : %s ms\n" "$MAIN_PORT" "$(probe "$MAIN_PORT")"

echo
echo "=================================================="
echo " 施加负载：heavy.slice 内 4×CPU 满载 + ${MEM_MB}M 内存"
echo "=================================================="

systemd-run --quiet --collect --slice=heavy.slice --unit=sr-cpu 2>/dev/null \
  /bin/sh -c 'for i in 1 2 3 4; do yes >/dev/null & done; wait'
systemd-run --quiet --collect --slice=heavy.slice --unit=sr-mem 2>/dev/null \
  /usr/bin/python3 -c "import time
b=bytearray(${MEM_MB}*1024*1024)
for i in range(0,len(b),4096): b[i]=1
time.sleep(${HOLD})"

sleep 3
printf "  MemAvailable : %s MiB (%s%%)\n" "$(mem_avail)" "$(mem_pct)"
printf "  load         : %s\n" "$(cut -d' ' -f1-3 /proc/loadavg)"

echo
echo "=================================================="
echo " 负载下的 ssh 响应（earlyoom 介入之前）"
echo "=================================================="
for i in 1 2 3; do
  # 探测与内存读数放在同一轮，便于看出压力在哪个点被 earlyoom 解除
  latency=$(probe "$MAIN_PORT")
  printf "  #%d ssh :%-6s : %s ms   MemAvailable %s MiB (%s%%)\n" \
    "$i" "$MAIN_PORT" "$latency" "$(mem_avail)" "$(mem_pct)"
  sleep 1
done

if systemctl is-active --quiet sr-mem 2>/dev/null; then
  echo "  (压测进程仍在，内存压力持续)"
else
  echo "  (压测进程已被 earlyoom 回收 —— 这本身就是预期行为：它杀了压测而不是 sshd)"
fi

echo
echo "=================================================="
echo " sshd cgroup 保护状态"
echo "=================================================="
CG=/sys/fs/cgroup/system.slice/ssh.service
if [[ -f $CG/memory.min ]]; then
  printf "  memory.current: %s MiB\n"  "$(( $(cat $CG/memory.current) / 1048576 ))"
  printf "  memory.min    : %s MiB  <- 实际用量应远小于它\n" "$(( $(cat $CG/memory.min) / 1048576 ))"
  printf "  memory.max    : %s MiB\n"  "$(( $(cat $CG/memory.max) / 1048576 ))"
  printf "  cpu.weight    : %s\n"      "$(cat $CG/cpu.weight)"
  printf "  memory.swap.max: %s  (0 = 禁止换出)\n" "$(cat $CG/memory.swap.max)"
  echo "  memory.events:"
  grep -E "^(low|high|max|oom|oom_kill)" "$CG/memory.events" | sed 's/^/    /'
  echo "  ^^ low/high/max/oom 全为 0 = 保护生效，sshd 没被回收"
else
  echo "  cgroup v1 或未安装，跳过"
fi

if [[ -f /sys/fs/cgroup/heavy.slice/memory.max ]]; then
  printf "  heavy.slice   : max=%sM current=%sM\n" \
    "$(( $(cat /sys/fs/cgroup/heavy.slice/memory.max) / 1048576 ))" \
    "$(( $(cat /sys/fs/cgroup/heavy.slice/memory.current) / 1048576 ))"
fi

echo
echo "=================================================="
echo " 服务存活"
echo "=================================================="
for u in ssh earlyoom; do
  printf "  %-12s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null || echo n/a)"
done
if systemctl is-active --quiet earlyoom 2>/dev/null; then
  echo "  earlyoom 最近决策:"
  journalctl -u earlyoom --no-pager -n 4 -o cat 2>/dev/null | sed 's/^/    /'
fi

echo
echo "=================================================="
echo " 清理"
echo "=================================================="
cleanup
sleep 2
printf "  清理后 MemAvailable: %s MiB\n" "$(mem_avail)"
printf "  %-12s %s\n" ssh "$(systemctl is-active ssh 2>/dev/null || echo n/a)"
