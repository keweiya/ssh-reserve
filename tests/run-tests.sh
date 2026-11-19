#!/usr/bin/env bash
# =============================================================================
#  ssh-reserve 本地回归测试
#
#  目的：在发版前把能测的都测掉，不拿用户机器当测试环境。
#  默认只做静态检查和 dry-run（不改本机任何配置）。
#
#  用法:
#    bash tests/run-tests.sh              # 静态 + dry-run 全量
#    bash tests/run-tests.sh --legacy     # 额外测试旧方案清理（会临时改 /etc）
#    bash tests/run-tests.sh --full       # 额外做真实安装 + 自动回滚（谨慎）
# =============================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL=$ROOT/install.sh
UNINSTALL=$ROOT/uninstall.sh
VERIFY=$ROOT/verify.sh

DO_LEGACY=0
DO_FULL=0
for a in "$@"; do
  case $a in
    --legacy) DO_LEGACY=1 ;;
    --full)   DO_FULL=1; DO_LEGACY=1 ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 0 ;;
  esac
done

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; R=; Y=; B=; D=; N=
fi

pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$N" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; [[ -n ${2:-} ]] && printf '       %s%s%s\n' "$D" "$2" "$N"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$Y" "$N" "$1"; }
group() { printf '\n%s[ %s ]%s\n' "$B" "$1" "$N"; }

dry() { bash "$INSTALL" --dry-run "$@" 2>&1; }

# ---------------------------------------------------------------------------
group "T1 静态检查"
# ---------------------------------------------------------------------------
for f in "$INSTALL" "$UNINSTALL" "$VERIFY"; do
  if bash -n "$f" 2>/dev/null; then pass "bash -n $(basename "$f")"; else fail "bash -n $(basename "$f")"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$INSTALL" "$UNINSTALL" "$VERIFY" >/tmp/sc.$$ 2>&1; then
    pass "shellcheck -S warning"
  else
    fail "shellcheck -S warning" "$(head -3 /tmp/sc.$$)"
  fi
  rm -f /tmp/sc.$$
else
  skip "shellcheck 未安装"
fi

# 已知踩过的坑：systemctl show --value 返回格式化字符串，不能直接算术
if grep -qE 'systemctl show.*--value' "$INSTALL"; then
  if grep -A3 'systemctl show.*--value' "$INSTALL" | grep -qE '\$\(\( *[A-Za-z_]+ */'; then
    fail "--value 的结果被用于算术" "会触发 value too great for base"
  else
    pass "--value 的结果未用于算术"
  fi
else
  pass "无 --value 直接算术风险"
fi

# 管道运行时带参数必须提示 -s --
if grep -q '\-s --' "$INSTALL"; then pass "文档提示了管道传参写法"; else fail "缺少管道传参提示"; fi

# VERSION 必须与最新 git tag 一致（漏改会导致 tag 里的版本号对不上）
VER=$(grep -m1 '^VERSION=' "$INSTALL" | cut -d'"' -f2)
TAG=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
if [[ -z $TAG ]]; then
  skip "无 tag，跳过版本一致性检查"
elif [[ $VER == "$TAG" ]]; then
  pass "VERSION 与最新 tag 一致 ($VER)"
else
  fail "VERSION($VER) 与最新 tag($TAG) 不一致" "发版前用 sed 同步 install.sh 的 VERSION"
fi

# 所有 cond && action 形式在 set -e 下的隐患（粗筛）
if grep -qE '^\s*\(\( [^)]+ \)\) && ' "$INSTALL"; then
  fail "存在裸的 (( )) && 表达式" "set -e 下条件为假会中断"
else
  pass "无裸 (( )) && 表达式"
fi

# ---------------------------------------------------------------------------
group "T2 参数组合（dry-run 必须全部成功）"
# ---------------------------------------------------------------------------
run_case() {
  local desc=$1; shift
  if dry "$@" >/dev/null; then pass "dry-run $desc"; else fail "dry-run $desc" "$(dry "$@" 2>&1 | tail -2)"; fi
}
run_case "无参数"
run_case "--no-swap"            --no-swap
run_case "--with-slice"         --with-slice
run_case "--no-watchdog"        --no-watchdog
run_case "--no-earlyoom"        --no-earlyoom
run_case "--no-kernel"          --no-kernel
run_case "--system-floor 64M"   --system-floor 64M
run_case "--system-floor 96M"   --system-floor 96M
run_case "--system-floor 256M"  --system-floor 256M
run_case "--swap-size 4G"       --swap-size 4G
run_case "--swap-size 512M"     --swap-size 512M
# 用唯一路径，避免被上一次运行的残留污染
TMP_SWAP=$(mktemp -u /tmp/ssh-reserve-test.XXXXXXXX)
run_case "--swap-file 唯一路径" --swap-file "$TMP_SWAP"
rm -f "$TMP_SWAP"
run_case "--clean-legacy"       --clean-legacy
run_case "组合参数"             --system-floor 64M --with-slice --no-swap --no-earlyoom

# ---------------------------------------------------------------------------
group "T3 生成的配置内容正确"
# ---------------------------------------------------------------------------
OUT=$(dry)
chk() { if grep -qF -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1" "未找到: $2"; fi; }
nochk() { if grep -qF -- "$2" <<<"$OUT"; then fail "$1" "不应出现: $2"; else pass "$1"; fi; }

chk "sshd CPUWeight=10000"        "CPUWeight=10000"
chk "sshd MemoryMin=32M"          "MemoryMin=32M"
chk "sshd MemoryMax=512M"         "MemoryMax=512M"
chk "sshd MemorySwapMax=0"        "MemorySwapMax=0"
chk "sshd OOMScoreAdjust=-1000"   "OOMScoreAdjust=-1000"
chk "sshd OOMPolicy=continue"     "OOMPolicy=continue"
chk "sshd Nice=-5"                "Nice=-5"
chk "StartLimit 在 [Unit] 段"     "StartLimitIntervalSec=0"
chk "system.slice 96M"            "MemoryMin=96M"
chk "watchdog 1800s"              "RuntimeWatchdogSec=1800s"
chk "earlyoom 只看内存"           "-s 100,100"
chk "earlyoom 豁免 sshd"          "--avoid '^(sshd|"
chk "sshd 抗风暴"                 "PerSourceMaxStartups 2"
chk "LoginGraceTime"              "LoginGraceTime 20"
chk "journald 限额"               "SystemMaxUse="
chk "sysctl min_free"             "vm.min_free_kbytes ="
chk "sysctl swappiness"           "vm.swappiness = 20"

# 默认不该生成的东西
if grep -qF "[dry-run] /etc/systemd/system/heavy.slice" <<<"$OUT"; then
  fail "默认不该生成 heavy.slice" "出现了 heavy.slice 配置"
else
  pass "默认不生成 heavy.slice 配置"
fi
if grep -qF "[dry-run] /etc/systemd/system/user.slice.d/" <<<"$OUT"; then
  fail "默认不该生成 user.slice 限制" "出现了 user.slice.d 配置"
else
  pass "默认不生成 user.slice 限制"
fi
if grep -qF "/usr/local/bin/heavy" <<<"$OUT"; then
  fail "默认不该安装 heavy 命令" "出现了 /usr/local/bin/heavy"
else
  pass "默认不安装 heavy 命令"
fi

# ---------------------------------------------------------------------------
group "T4 错误处理（该失败的必须失败）"
# ---------------------------------------------------------------------------
must_fail() {
  local desc=$1; shift
  if dry "$@" >/dev/null 2>&1; then fail "$desc（本应失败）"; else pass "$desc"; fi
}
must_fail "未知参数"        --bogus-option
must_fail "swap 小于 64M"   --swap-size 16M
must_fail "非法 swap 大小"  --swap-size abc
must_fail "system-floor 非法" --system-floor xyz
must_fail "--swap-size 缺参"  --swap-size

# system-floor 低于 64M 应被夹到 64M 而不是报错
OUT_LOW=$(dry --system-floor 16M)
if grep -q "system.min=64M" <<<"$OUT_LOW"; then pass "system-floor 16M 被夹到 64M"; else fail "system-floor 下限夹取" "$(grep 'system.min' <<<"$OUT_LOW")"; fi

# ---------------------------------------------------------------------------
group "T5 幂等性（同一环境两次 dry-run 输出一致）"
# ---------------------------------------------------------------------------
A=$(dry | sed -E 's/[0-9]{8}-[0-9]{6}//g; s/磁盘 [0-9]+M/磁盘 X/g')
B=$(dry | sed -E 's/[0-9]{8}-[0-9]{6}//g; s/磁盘 [0-9]+M/磁盘 X/g')
if [[ $A == "$B" ]]; then pass "两次输出一致"; else fail "两次输出不一致" "$(diff <(echo "$A") <(echo "$B") | head -5)"; fi

# ---------------------------------------------------------------------------
if (( DO_LEGACY )); then
group "T6 旧方案清理（会临时改 /etc，结束自动恢复）"
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  skip "需要 root"
else
  BAK=/tmp/ssh-reserve-t6-bak
  rm -rf "$BAK"; mkdir -p "$BAK"
  cp -a /usr/lib/systemd/system/ssh.service /etc/sysctl.conf /etc/systemd/system.conf "$BAK/" 2>/dev/null

  # 注入旧方案
  sed -i '/^\[Service\]$/a OOMScoreAdjust=-1000\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99\nCPUWeight=1000\nMemoryMin=32M' \
    /usr/lib/systemd/system/ssh.service 2>/dev/null
  printf '\nvm.swappiness=10\nvm.panic_on_oom=1\nkernel.panic=60\n' >>/etc/sysctl.conf
  mkdir -p /etc/modules-load.d; echo softdog >/etc/modules-load.d/softdog.conf
  printf '\nRuntimeWatchdogSec=60s\n' >>/etc/systemd/system.conf

  bash "$INSTALL" --clean-legacy >/tmp/t6.$$ 2>&1
  RC=$?

  [[ $RC -eq 0 ]] && pass "clean-legacy 退出码 0" || fail "clean-legacy 退出码 $RC" "$(tail -3 /tmp/t6.$$)"
  grep -qE '^(CPUSchedulingPolicy|CPUSchedulingPriority)=' /usr/lib/systemd/system/ssh.service \
    && fail "ssh.service 仍有 rr/99" || pass "ssh.service 的 rr/99 已移除"
  grep -qE '^[[:space:]]*vm\.panic_on_oom[[:space:]]*=' /etc/sysctl.conf \
    && fail "sysctl.conf 仍有 panic_on_oom" || pass "sysctl.conf 的 panic_on_oom 已注释"
  [[ -f /etc/modules-load.d/softdog.conf ]] && fail "softdog.conf 仍存在" || pass "softdog.conf 已移除"
  grep -qE '^[[:space:]]*RuntimeWatchdogSec=' /etc/systemd/system.conf \
    && fail "system.conf 仍有 RuntimeWatchdogSec" || pass "RuntimeWatchdogSec 已停用"

  # 恢复
  for f in ssh.service sysctl.conf system.conf; do
    [[ -f $BAK/$f ]] || continue
    case $f in
      ssh.service) cp -a "$BAK/$f" /usr/lib/systemd/system/ssh.service ;;
      *)           cp -a "$BAK/$f" "/etc/$f" ;;
    esac
  done
  systemctl daemon-reload 2>/dev/null
  sysctl --system >/dev/null 2>&1
  rm -f /tmp/t6.$$
  pass "测试环境已恢复"
fi
fi

# ---------------------------------------------------------------------------
if (( DO_FULL )); then
group "T7 真实安装 + 自动回滚"
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  skip "需要 root"
else
  if bash "$INSTALL" >/tmp/t7.$$ 2>&1; then
    pass "install 退出码 0"
    # 关键值校验
    probe() {
      local d=$1 actual=$2 expect=$3
      if [[ $actual == "$expect" ]]; then pass "$d = $expect"; else fail "$d" "实际=$actual 期望=$expect"; fi
    }
    CG=/sys/fs/cgroup/system.slice/ssh.service
    probe "sshd memory.min"    "$(cat $CG/memory.min 2>/dev/null)" "33554432"
    probe "sshd memory.max"    "$(cat $CG/memory.max 2>/dev/null)" "536870912"
    probe "sshd swap.max"      "$(cat $CG/memory.swap.max 2>/dev/null)" "0"
    probe "sshd cpu.weight"    "$(cat $CG/cpu.weight 2>/dev/null)" "10000"
    probe "system.slice min"   "$(cat /sys/fs/cgroup/system.slice/memory.min 2>/dev/null)" "100663296"
    probe "watchdog state"     "$(cat /sys/class/watchdog/watchdog0/state 2>/dev/null)" "active"
    probe "watchdog timeout"   "$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null)" "1800"
    probe "ssh 状态"           "$(systemctl is-active ssh 2>/dev/null)" "active"
    probe "earlyoom 状态"      "$(systemctl is-active earlyoom 2>/dev/null)" "active"
    probe "ssh-reserve 命令"   "$([[ -x /usr/local/bin/ssh-reserve ]] && echo ok)" "ok"
    # 没有残留的旧限制
    [[ -f /etc/systemd/system/heavy.slice ]] && fail "heavy.slice 不该存在" || pass "heavy.slice 未生成"
    # stderr 必须干净
    if grep -qE 'value too great|command not found|No such file' /tmp/t7.$$; then
      fail "安装输出含错误" "$(grep -E 'value too great|command not found|No such file' /tmp/t7.$$ | head -2)"
    else
      pass "安装输出无错误行"
    fi
  else
    fail "install 退出码非 0" "$(tail -5 /tmp/t7.$$)"
  fi
  rm -f /tmp/t7.$$
fi
fi

# ---------------------------------------------------------------------------
printf '\n%s========================================%s\n' "$B" "$N"
printf '  通过 %s%d%s   失败 %s%d%s   跳过 %s%d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if (( FAIL > 0 )); then
  printf '\n  失败的用例:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  printf '\n%s结论: 不可发版%s\n' "$R" "$N"
  exit 1
fi
printf '\n%s结论: 全部通过，可以发版%s\n' "$G" "$N"
