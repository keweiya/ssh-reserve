#!/usr/bin/env bash
# =============================================================================
#  ssh-reserve — 小服务器 SSH 资源预留 + swap 一键部署
#
#  解决的问题：机器跑重活（编译/构建/爬虫/压测）之后 ssh 连不上 ——
#  不是密码错，是 TCP 都慢或者直接 timeout。
#
#  做四件事：
#    1. swap 兜底（默认 2G）
#    2. 给 sshd 预留 CPU / 内存 / IO（cgroup v2）
#    3. 给 sshd 一条独立救援通道（第二个 sshd 实例）
#    4. earlyoom 在内核 OOM 之前先杀"该杀的"
#
#  用法：
#    bash install.sh                     # 默认：2G swap + 全套预留
#    bash install.sh --swap-size 4G      # 指定 swap 大小
#    bash install.sh --no-swap           # 完全不动 swap
#    bash install.sh --dry-run           # 只打印要做什么，不落盘
#    bash install.sh --uninstall         # 卸载（同 uninstall.sh）
#    bash install.sh --help
#
#  一行安装：
#    curl -fsSL https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@main/install.sh | sudo bash
#
#  版本: 1.0.0    许可: MIT
# =============================================================================
set -Eeuo pipefail

VERSION="1.2.1"

# 管道安装（curl | bash）时本地没有脚本文件，安装结束后要把它们落到这里，
# 并提供 ssh-reserve 管理命令，否则提示里的 verify.sh / uninstall.sh 跑不通。
RAW_BASE="https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@main"
SSH_RESERVE_LIB=${SSH_RESERVE_LIB:-/usr/local/lib/ssh-reserve}
SWAP_PRI=10

# ----------------------------------------------------------------------------
# 默认参数
# ----------------------------------------------------------------------------
SWAP_SIZE="auto"        # auto = clamp(RAM, 2G, 4G)；也可显式给 2G / 4G / 512M
SWAP_EXPLICIT=0         # 用户是否显式指定过 --swap-size
CONTAINER=""            # 容器类型，空 = 非容器
SWAP_FILE="/swapfile"
DO_SWAP=1
DO_EARLYOOM=1
DO_KERNEL=1
DO_SLICE=1
DRY_RUN=0
FORCE=0
ACTION="install"
CG_V2=0

# ----------------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=
fi

log()  { printf '%s[ssh-reserve]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  xx %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }

run() {
  if (( DRY_RUN )); then printf '%s    $ %s%s\n' "$C_D" "$*" "$C_0"; return 0; fi
  "$@"
}

# 写配置文件：内容从 stdin 读，先写临时文件再原子替换
put() {
  local target=$1 perm=${2:-644} tmp
  if (( DRY_RUN )); then
    printf '%s    [dry-run] %s%s\n' "$C_D" "$target" "$C_0"
    sed 's/^/      /'
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  tmp=$(mktemp "${target}.XXXXXX")
  cat >"$tmp"
  chmod "$perm" "$tmp"
  mv -f "$tmp" "$target"
  ok "写入 $target"
}

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
ssh-reserve — 小服务器 SSH 资源预留 + swap 一键部署

  --swap-size SIZE    swap 大小，默认 auto（clamp(内存, 2G, 4G)）
                      也可显式指定：512M / 2G / 4G / 1T
  --swap-file PATH    swap 文件位置，默认 /swapfile
  --no-swap           不创建/修改 swap
  --no-earlyoom       不安装 earlyoom
  --no-slice          不设置 slice 层的 CPU/内存上限
  --no-kernel         不改内核参数
  --force             覆盖（非 swap 的）已存在文件
  --dry-run           只打印不执行
  --uninstall         卸载
  -h, --help          显示帮助

示例：
  bash install.sh                       # 2G swap + 全套
  bash install.sh --swap-size 4G        # 4G swap
  bash install.sh --no-swap --dry-run   # 不动 swap，先看会做什么
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --swap-size)     SWAP_SIZE=${2:?--swap-size 需要参数}; SWAP_EXPLICIT=1; shift 2 ;;
    --swap-size=*)   SWAP_SIZE=${1#*=}; SWAP_EXPLICIT=1; shift ;;
    --swap-file)     SWAP_FILE=${2:?--swap-file 需要参数}; shift 2 ;;
    --swap-file=*)   SWAP_FILE=${1#*=}; shift ;;
    --no-swap)       DO_SWAP=0; shift ;;
    # v1.1.0 起移除救援端口：问题在资源不足，多开端口解决不了。
    # 保留解析，避免用户复制旧命令时报"未知参数"。
    --rescue-port)   warn "v1.1.0 起已移除救援端口，忽略该参数"; shift 2 ;;
    --rescue-port=*) warn "v1.1.0 起已移除救援端口，忽略该参数"; shift ;;
    --no-rescue)     shift ;;
    --no-earlyoom)   DO_EARLYOOM=0; shift ;;
    --no-slice)      DO_SLICE=0; shift ;;
    --no-kernel)     DO_KERNEL=0; shift ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --uninstall)     ACTION="uninstall"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "未知参数: $1（--help 看用法）" ;;
  esac
done

if [[ $ACTION == uninstall ]]; then
  SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)
  if [[ -f $SELF_DIR/uninstall.sh ]]; then
    exec bash "$SELF_DIR/uninstall.sh"
  fi
  die "找不到 uninstall.sh；单独下载：https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@main/uninstall.sh"
fi

# ----------------------------------------------------------------------------
# 预检
# ----------------------------------------------------------------------------
stage_preflight() {
  step "预检"

  if [[ $EUID -ne 0 ]]; then die "需要 root 权限（sudo bash $0）"; fi
  ok "root"

  if [[ ! -d /run/systemd/system ]]; then die "这不是 systemd 系统，本脚本不适用"; fi
  ok "systemd $(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"

  local cg_type
  cg_type=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)
  if [[ $cg_type == cgroup2fs ]]; then
    CG_V2=1; ok "cgroup v2"
  else
    CG_V2=0
    warn "cgroup v1（$cg_type）：memory.min / cpu.weight 不可用，降级为 nice + IO 优先级 + swap + earlyoom"
  fi

  command -v systemd-analyze >/dev/null 2>&1 || warn "缺 systemd-analyze，跳过 unit 校验"

  SSHD_BIN=$(command -v sshd 2>/dev/null || true)
  if [[ -z $SSHD_BIN ]]; then SSHD_BIN=/usr/sbin/sshd; fi
  if [[ ! -x $SSHD_BIN ]]; then die "找不到 sshd 二进制"; fi
  ok "sshd: $SSHD_BIN"

  SSHD_CONFIG=/etc/ssh/sshd_config
  if [[ ! -f $SSHD_CONFIG ]]; then die "找不到 $SSHD_CONFIG"; fi
  SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
  SSHD_DROPIN=$SSHD_DROPIN_DIR/99-ssh-reserve.conf

  MAIN_PORTS=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')
  if [[ -z ${MAIN_PORTS// /} ]]; then MAIN_PORTS="22 "; fi
  ok "主监听端口: $MAIN_PORTS"

  BACKUP_DIR="/var/backups/ssh-reserve/$(date +%Y%m%d-%H%M%S)"
  if (( DRY_RUN )); then BACKUP_DIR="/tmp/ssh-reserve-dryrun"; fi
  ok "备份目录: $BACKUP_DIR"

  # 容器环境：LXC / Docker / Podman / K8s pod 里 swap 通常开不起来，
  # cgroup 资源限制也常常是只读的，需要提前识别并降级。
  CONTAINER=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    CONTAINER=$(systemd-detect-virt --container 2>/dev/null || true)
  fi
  if [[ $CONTAINER == none ]]; then CONTAINER=""; fi
  if [[ -z $CONTAINER && -f /.dockerenv ]]; then CONTAINER="docker"; fi
  if [[ -z $CONTAINER && -f /run/.containerenv ]]; then CONTAINER="podman"; fi
  if [[ -z $CONTAINER ]] && grep -qaE '(lxc|docker|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
    CONTAINER="container"
  fi
  if [[ -n $CONTAINER ]]; then
    ok "容器环境: $CONTAINER（swap 将默认跳过，cgroup 设置可能受宿主限制）"
  fi

  # 判断是不是在用管道跑：BASH_SOURCE 为 bash 或 /dev/fd/63 这类不可读路径
  SELF_PATH="${BASH_SOURCE[0]:-}"
  if [[ -z $SELF_PATH || ! -f $SELF_PATH ]]; then
    ok "检测到管道执行，安装后会把脚本落到 $SSH_RESERVE_LIB"
  fi
}

backup_file() {
  local f=$1
  if [[ ! -e $f ]]; then return 0; fi
  if (( DRY_RUN )); then return 0; fi
  mkdir -p "$BACKUP_DIR"
  cp -a "$f" "$BACKUP_DIR/$(printf '%s' "${f#/}" | tr '/' '@')"
}

# ----------------------------------------------------------------------------
# 按机器规模推导参数（1G / 2G / 4G / 8G 都合理）
# ----------------------------------------------------------------------------
derive_params() {
  MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  NPROC=$(nproc 2>/dev/null || echo 1)

  pct() { # pct TOTAL PERCENT MIN MAX
    local v=$(( $1 * $2 / 100 ))
    if (( v < $3 )); then v=$3; fi
    if (( v > $4 )); then v=$4; fi
    printf '%d' "$v"
  }

  # sshd 实际只用 10M 左右，预留约 10 倍余量应对 preauth 风暴
  SSHD_MEM_MIN=$(pct "$MEM_MB" 5 64 128)
  SSHD_MEM_LOW=$(( SSHD_MEM_MIN * 5 / 3 ))
  SSHD_MEM_HIGH=$(( SSHD_MEM_MIN * 16 / 3 ))
  SSHD_MEM_MAX=$(( SSHD_MEM_MIN * 8 ))

  # 父层：system.slice 的硬保留，让 sshd 的 memory.min 成为绝对保护
  SYSTEM_MEM_MIN=$(pct "$MEM_MB" 33 384 1536)
  SYSTEM_MEM_LOW=$(( SYSTEM_MEM_MIN * 6 / 5 ))

  # 普通登录会话天花板
  USER_MEM_HIGH=$(pct "$MEM_MB" 40 256 2048)
  USER_MEM_MAX=$(pct "$MEM_MB" 55 384 3072)

  # 重活隔离区
  HEAVY_MEM_HIGH=$(pct "$MEM_MB" 53 512 3072)
  HEAVY_MEM_MAX=$(pct "$MEM_MB" 65 640 4096)

  # CPU：2 核留约 1/4 给系统 => 150%；4 核 => 300%
  USER_CPU_QUOTA=$(( NPROC * 75 ))
  if (( USER_CPU_QUOTA < 50 )); then USER_CPU_QUOTA=50; fi

  # journald 限额：按磁盘容量算，小硬盘不能被日志吃掉一大块
  # 规则 min(200M, max(32M, 磁盘 3%))：1G 盘 → 32M，59G 盘 → 200M
  local disk_mb
  disk_mb=$(df -Pm /var/log 2>/dev/null | awk 'NR==2{print $2}')
  if [[ -z ${disk_mb:-} ]] || (( disk_mb < 64 )); then disk_mb=1024; fi
  JOURNAL_MB=$(( disk_mb * 3 / 100 ))
  if (( JOURNAL_MB < 32 ));  then JOURNAL_MB=32;  fi
  if (( JOURNAL_MB > 200 )); then JOURNAL_MB=200; fi
  JOURNAL_RUNTIME_MB=$(( JOURNAL_MB / 3 ))
  if (( JOURNAL_RUNTIME_MB < 16 )); then JOURNAL_RUNTIME_MB=16; fi

  # 内核
  MIN_FREE_KB=$(( MEM_MB * 5 * 1024 / 100 ))
  if (( MIN_FREE_KB < 32768 ));  then MIN_FREE_KB=32768;  fi
  if (( MIN_FREE_KB > 262144 )); then MIN_FREE_KB=262144; fi

  # preauth 并发上限：内存越小越保守
  # 绝对上限 × 6M 就是最坏情况下 preauth 占用的内存
  if (( MEM_MB < 2560 )); then
    MAX_STARTUPS="8:30:20"      # ≤2G：最坏 ~120M
  elif (( MEM_MB < 4096 )); then
    MAX_STARTUPS="12:30:30"     # 2~4G：最坏 ~180M
  else
    MAX_STARTUPS="16:30:50"     # ≥4G：最坏 ~300M
  fi

  ok "内存 ${MEM_MB}M / ${NPROC} 核"
  printf '%s    sshd      : min=%sM low=%sM high=%sM max=%sM swap=0%s\n' "$C_D" \
    "$SSHD_MEM_MIN" "$SSHD_MEM_LOW" "$SSHD_MEM_HIGH" "$SSHD_MEM_MAX" "$C_0"
  printf '%s    slices    : system.min=%sM  user(high=%sM,max=%sM,cpu=%s%%)%s\n' "$C_D" \
    "$SYSTEM_MEM_MIN" "$USER_MEM_HIGH" "$USER_MEM_MAX" "$USER_CPU_QUOTA" "$C_0"
  printf '%s    earlyoom  : mem<=5%% 时介入  ·  MaxStartups %s%s\n' "$C_D" \
    "$MAX_STARTUPS" "$C_0"
  printf '%s    journald  : 上限 %sM（磁盘 %sM）%s\n' "$C_D" \
    "$JOURNAL_MB" "$disk_mb" "$C_0"
}

# ----------------------------------------------------------------------------
# 1. swap
# ----------------------------------------------------------------------------
# auto: clamp(RAM, 2G, 4G)
# 小机器给足缓冲；4G 以上封顶 4G —— swap 是冷页回收区，不是内存扩展，
# 给太多会拖长抖动窗口、推迟 earlyoom 介入，反而让 ssh 更卡。
resolve_swap_mb() {
  local s=$1
  if [[ $s != auto ]]; then
    swap_mb_from_size "$s"
    return 0
  fi
  local mb=${MEM_MB:-2048}
  if (( mb < 2048 )); then mb=2048; fi
  if (( mb > 4096 )); then mb=4096; fi
  printf '%d' "$mb"
}

swap_mb_from_size() {
  local s=${1^^}
  case $s in
    *T) printf '%d' $(( ${s%T} * 1024 * 1024 )) ;;
    *G) printf '%d' $(( ${s%G} * 1024 )) ;;
    *M) printf '%d' $(( ${s%M} )) ;;
    *K) printf '%d' $(( ${s%K} / 1024 )) ;;
    *)  if [[ ! $s =~ ^[0-9]+$ ]]; then die "无效的 swap 大小: $1"; fi
        printf '%d' "$s" ;;
  esac
}

active_swap_mb() {
  swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null \
    | awk -v f="$1" '$1==f{printf "%d", $2/1048576}'
}

active_swap_used_mb() {
  swapon --show=NAME,USED --bytes --noheadings 2>/dev/null \
    | awk -v f="$1" '$1==f{printf "%d", $2/1048576}'
}

mem_avail_mb() {
  awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo
}

fstype_of() {
  findmnt -no FSTYPE --target "$1" 2>/dev/null \
    || stat -f -c %T "$1" 2>/dev/null \
    || echo unknown
}

fstab_has_swap() {
  awk -v f="$1" '!/^[[:space:]]*#/ && $1==f && $3=="swap"{found=1} END{exit !found}' /etc/fstab 2>/dev/null
}

add_fstab_swap() {
  backup_file /etc/fstab
  if (( DRY_RUN )); then
    printf '%s    $ echo "%s none swap sw,pri=%s 0 0" >> /etc/fstab%s\n' \
      "$C_D" "$SWAP_FILE" "$SWAP_PRI" "$C_0"
    return 0
  fi
  # 显式写 pri：不写的话内核会从 -1 开始递减自动分配，
  # swapon --show 里看起来像负数优先级，行为不可预期。
  printf '\n# ssh-reserve: persistent swap\n%s none swap sw,pri=%s 0 0\n' \
    "$SWAP_FILE" "$SWAP_PRI" >>/etc/fstab
  ok "已写入 /etc/fstab（pri=${SWAP_PRI}）"
}

stage_swap() {
  if (( ! DO_SWAP )); then warn "按要求跳过 swap（--no-swap）"; return 0; fi

  # 容器里 swap 基本开不起来（没有 CAP_SYS_ADMIN，或 cgroup memory.swap.max=0），
  # 默认直接跳过，不浪费时间也不吓人；确需尝试的用户显式给 --swap-size 即可。
  if (( ! SWAP_EXPLICIT )) && [[ -n ${CONTAINER:-} ]]; then
    warn "容器环境（${CONTAINER}）：swap 通常不可用，跳过"
    warn "确需尝试请显式指定：--swap-size 2G"
    return 0
  fi

  if [[ $SWAP_SIZE == auto ]]; then
    step "swap（自动：内存 ${MEM_MB}M → clamp(2G,4G)，文件 ${SWAP_FILE}）"
  else
    step "swap（目标 ${SWAP_SIZE}，文件 ${SWAP_FILE}）"
  fi

  local want_mb cur_mb avail_kb fs need_kb now_mb alloc_kb decl_kb
  want_mb=$(resolve_swap_mb "$SWAP_SIZE")
  if (( want_mb < 64 )); then die "swap 至少 64M"; fi

  cur_mb=$(active_swap_mb "$SWAP_FILE")
  cur_mb=${cur_mb:-0}

  # swap 文件内有 header，可用大小比声明值小 1M 左右，留 8M 容差，
  # 否则 2G 文件会被判成 2047M < 2048M 而每次安装都白白重建一遍。
  if (( cur_mb + 8 >= want_mb )); then
    ok "swap 已就绪: ${SWAP_FILE} = ${cur_mb}M（目标 ${want_mb}M，不动）"
    if fstab_has_swap "$SWAP_FILE"; then
      ok "/etc/fstab 已有条目，重启后仍在"
    else
      warn "$SWAP_FILE 未写入 /etc/fstab，重启后会丢失，正在补上"
      add_fstab_swap
    fi
    return 0
  fi

  if (( cur_mb > 0 )); then
    local used_mb avail_mb
    used_mb=$(active_swap_used_mb "$SWAP_FILE")
    used_mb=${used_mb:-0}
    avail_mb=$(mem_avail_mb)
    # swapoff 会把 swap 里的数据全部换回内存。可用内存不够时这一步会直接 OOM，
    # 所以必须先拦住，而不是让用户在重建 swap 时把机器搞死。
    if (( used_mb > avail_mb / 2 )); then
      die "swap 已用 ${used_mb}M，可用内存仅 ${avail_mb}M。swapoff 会把它全部换回内存，可能触发 OOM。先释放内存（或重启）后再重试"
    fi
    warn "现有 swap ${cur_mb}M < 目标 ${want_mb}M，将重建（已用 ${used_mb}M，可用内存 ${avail_mb}M）"
    run swapoff "$SWAP_FILE"
  fi

  if [[ -e $SWAP_FILE ]]; then
    if swaplabel "$SWAP_FILE" >/dev/null 2>&1; then
      ok "$SWAP_FILE 是 swap 文件，可覆盖"
    elif (( FORCE )); then
      warn "$SWAP_FILE 不是 swap 文件，--force 覆盖"
    else
      die "$SWAP_FILE 已存在且不是 swap 文件。换路径（--swap-file）或加 --force"
    fi
  fi

  fs=$(fstype_of "$(dirname "$SWAP_FILE")")
  ok "文件系统: $fs"

  need_kb=$(( want_mb * 1024 + 262144 ))
  avail_kb=$(df -Pk "$(dirname "$SWAP_FILE")" | awk 'NR==2{print $4}')
  if (( avail_kb < need_kb )); then
    if (( SWAP_EXPLICIT )); then
      die "磁盘不足：需要 $(( need_kb / 1024 ))M，$(dirname "$SWAP_FILE") 剩余 $(( avail_kb / 1024 ))M"
    fi
    warn "磁盘不足：需要 $(( need_kb / 1024 ))M，剩余 $(( avail_kb / 1024 ))M"
    warn "跳过 swap，继续做 ssh 资源预留 —— swap 只是缓冲，预留不依赖它"
    return 0
  fi
  ok "磁盘剩余 $(( avail_kb / 1024 ))M，足够"

  if (( DRY_RUN )); then
    printf '%s    $ fallocate -l %sM %s   # 失败自动回退 dd%s\n' "$C_D" "$want_mb" "$SWAP_FILE" "$C_0"
    printf '%s    $ chmod 600 %s && mkswap %s && swapon -p %s %s%s\n' \
      "$C_D" "$SWAP_FILE" "$SWAP_FILE" "$SWAP_PRI" "$SWAP_FILE" "$C_0"
    if fstab_has_swap "$SWAP_FILE"; then
      ok "/etc/fstab 已有条目，无需追加"
    else
      printf '%s    $ echo "%s none swap sw,pri=%s 0 0" >> /etc/fstab%s\n' \
        "$C_D" "$SWAP_FILE" "$SWAP_PRI" "$C_0"
    fi
    return 0
  fi

  dd_create() {
    rm -f "$SWAP_FILE"
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want_mb" status=none
  }

  if [[ $fs == btrfs* ]]; then
    # btrfs 上 swap 文件必须 no-COW 且非稀疏，fallocate 会生成洞导致 swapon 失败
    warn "btrfs：改用 dd（swap 文件不能有洞）"
    rm -f "$SWAP_FILE"
    touch "$SWAP_FILE"
    chattr +C "$SWAP_FILE" 2>/dev/null || true
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want_mb" status=none
  elif fallocate -l "${want_mb}M" "$SWAP_FILE" 2>/dev/null; then
    alloc_kb=$(du -k "$SWAP_FILE" | awk '{print $1}')
    decl_kb=$(( want_mb * 1024 ))
    if (( alloc_kb * 100 < decl_kb * 95 )); then
      warn "fallocate 生成的是稀疏文件，改用 dd"
      dd_create
    fi
  else
    warn "fallocate 不可用，改用 dd（${want_mb}M，稍慢）"
    dd_create
  fi

  chmod 600 "$SWAP_FILE"
  if ! mkswap "$SWAP_FILE" >/dev/null 2>&1; then
    warn "mkswap 失败，用 dd 重建后重试"
    dd_create
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
  fi
  if ! swapon -p "$SWAP_PRI" "$SWAP_FILE" 2>/dev/null; then
    die "swapon 失败，检查 dmesg | tail"
  fi

  if fstab_has_swap "$SWAP_FILE"; then
    ok "/etc/fstab 已有条目"
  else
    add_fstab_swap
  fi

  now_mb=$(active_swap_mb "$SWAP_FILE")
  now_mb=${now_mb:-0}
  if (( now_mb > 0 )); then
    ok "swap 生效: ${now_mb}M"
  else
    warn "swap 可能未生效，检查 dmesg | tail"
  fi
}

# ----------------------------------------------------------------------------
# 1.5 迁移：清理旧版本装过的救援 sshd 实例
#   问题在资源不足，多开一个端口解决不了，反而多一个爆破入口。
# ----------------------------------------------------------------------------
stage_migrate() {
  if [[ ! -f /etc/systemd/system/ssh-rescue.service ]]; then return 0; fi

  step "清理旧版遗留的救援 sshd 实例"
  if (( DRY_RUN )); then
    printf '%s    $ systemctl disable --now ssh-rescue && rm -f /etc/systemd/system/ssh-rescue.service%s\n' \
      "$C_D" "$C_0"
    return 0
  fi

  backup_file /etc/systemd/system/ssh-rescue.service
  systemctl disable --now ssh-rescue.service 2>/dev/null || true
  rm -f /etc/systemd/system/ssh-rescue.service /run/sshd-rescue.pid
  systemctl daemon-reload
  ok "已移除 ssh-rescue.service，主 sshd 未受影响"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    warn "本机 ufw 里可能残留旧的放行规则，按需清理：ufw status numbered"
  fi
  warn "云安全组里的旧端口规则也可以一并删掉"
}

# ----------------------------------------------------------------------------
# 2. sshd 的 cgroup 配额
# ----------------------------------------------------------------------------
stage_ssh_cgroup() {
  step "给 sshd 预留 CPU / 内存 / IO"
  backup_file /etc/systemd/system/ssh.service.d/50-ssh-reserve.conf

  if (( ! CG_V2 )); then
    warn "cgroup v1：只设 nice + IO 优先级 + OOM 保护"
    put /etc/systemd/system/ssh.service.d/50-ssh-reserve.conf <<EOF
# 由 ssh-reserve ${VERSION} 生成
[Unit]
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Nice=-10
IOSchedulingClass=best-effort
IOSchedulingPriority=0
OOMScoreAdjust=-1000
Restart=always
RestartSec=2s
TasksMax=8192
LimitNOFILE=65535
LimitCORE=0
EOF
    return 0
  fi

  put /etc/systemd/system/ssh.service.d/50-ssh-reserve.conf <<EOF
# 由 ssh-reserve ${VERSION} 生成 —— 手工改动会被 install.sh 覆盖
# 回滚: bash uninstall.sh
[Unit]
# StartLimit* 属于 [Unit] 段。写在 [Service] 会被静默忽略，
# 导致 sshd 短时间崩几次就被 start limit 锁死，再也起不来。
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
# CPU：与重负载争抢时抢占优先权（默认 100）
CPUWeight=10000
# 轻微 nice 加成。不用 -20：登录后的 shell 会继承该值，过高会压制系统进程
Nice=-10
# IO：磁盘打满时 sshd 不卡在 D 状态读 passwd / 写 wtmp
IOWeight=10000
IOSchedulingClass=best-effort
IOSchedulingPriority=0
# 内存：memory.min 是硬保留，回收碰不到这块
MemoryMin=${SSHD_MEM_MIN}M
MemoryLow=${SSHD_MEM_LOW}M
MemoryHigh=${SSHD_MEM_HIGH}M
MemoryMax=${SSHD_MEM_MAX}M
# 禁止换出：换出后登录会卡在 swap-in 上超时
MemorySwapMax=0
# 系统级 OOM 永不挑 sshd
OOMScoreAdjust=-1000
# 默认 stop 会因一次 cgroup OOM 停掉整个 unit
OOMPolicy=continue
TasksMax=8192
LimitNOFILE=65535
LimitNPROC=8192
LimitCORE=0
Restart=always
RestartSec=2s
CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
EOF
}

# ----------------------------------------------------------------------------
# 3. slice 层
# ----------------------------------------------------------------------------
stage_slice() {
  if (( ! DO_SLICE )); then warn "按要求跳过 slice 层（--no-slice）"; return 0; fi
  if (( ! CG_V2 )); then warn "cgroup v1：跳过 slice 层限额"; return 0; fi

  step "slice 层额度"

  backup_file /etc/systemd/system/system.slice.d/50-ssh-reserve.conf
  put /etc/systemd/system/system.slice.d/50-ssh-reserve.conf <<EOF
# 由 ssh-reserve ${VERSION} 生成
[Slice]
# 内存再紧，回收也不许拿走这 ${SYSTEM_MEM_MIN}M。
# sshd 的 memory.min 只有在父层有额度时才是绝对保护。
MemoryMin=${SYSTEM_MEM_MIN}M
MemoryLow=${SYSTEM_MEM_LOW}M
EOF

  backup_file /etc/systemd/system/user.slice.d/50-ssh-reserve.conf
  put /etc/systemd/system/user.slice.d/50-ssh-reserve.conf <<EOF
# 由 ssh-reserve ${VERSION} 生成
[Slice]
# 登录后的 shell 由 pam_systemd 移到 session-*.scope，落在这里。
# 必须在这里设硬上限，才能给 sshd 留出 CPU。
CPUWeight=50
IOWeight=50
# ${NPROC} 核机器最多 ${USER_CPU_QUOTA}%，余量留给 sshd / 内核
CPUQuota=${USER_CPU_QUOTA}%
MemoryHigh=${USER_MEM_HIGH}M
MemoryMax=${USER_MEM_MAX}M
MemorySwapMax=1024M
TasksMax=8192
EOF

  backup_file /etc/systemd/system/heavy.slice
  put /etc/systemd/system/heavy.slice <<EOF
# 由 ssh-reserve ${VERSION} 生成
# 用法: heavy make -j16   /   systemd-run --slice=heavy.slice --scope -t bash
[Slice]
CPUWeight=20
CPUQuota=${USER_CPU_QUOTA}%
IOWeight=10
MemoryHigh=${HEAVY_MEM_HIGH}M
MemoryMax=${HEAVY_MEM_MAX}M
MemorySwapMax=1536M
TasksMax=16384
EOF

  backup_file /usr/local/bin/heavy
  put /usr/local/bin/heavy 755 <<'HEAVYEOF'
#!/usr/bin/env bash
# 在受限 slice 里跑重活：heavy make -j16 / heavy bash
set -euo pipefail
SLICE=${HEAVY_SLICE:-heavy.slice}
if [[ $# -eq 0 ]]; then
  echo "usage: heavy [--unit=NAME] COMMAND [ARGS...]" >&2
  exit 2
fi
unit=""
if [[ $1 == --unit=* ]]; then
  unit=${1#--unit=}
  shift
fi
if [[ -z $unit ]]; then
  unit="heavy-$$"
fi
exec systemd-run --quiet --pipe --wait --collect \
  --slice="$SLICE" --unit="$unit" \
  --property=IOWeight=10 --property=TasksMax=16384 -- "$@"
HEAVYEOF
  if (( ! DRY_RUN )); then chmod +x /usr/local/bin/heavy; fi
}

# ----------------------------------------------------------------------------
# 4. 救援 sshd 实例（必须在改主配置之前起来）
# ----------------------------------------------------------------------------
# 当前正在跑的救援实例实际监听哪个端口。重装时用它来保持端口稳定，
# 否则脚本会把自己的进程当成"端口被占用"，每重跑一次就往后挪一格。
# ----------------------------------------------------------------------------
# 5. sshd 抗连接风暴
# ----------------------------------------------------------------------------
stage_sshd_harden() {
  step "sshd 抗连接风暴"
  backup_file "$SSHD_DROPIN"

  put "$SSHD_DROPIN" <<EOF
# 由 ssh-reserve ${VERSION} 生成
# 未认证连接每个约 4~6M 常驻。放开并发等于让连接风暴打死 sshd 自己。
MaxStartups ${MAX_STARTUPS}
# 单源最多 2 个未认证位：爆破拿不到坑位
PerSourceMaxStartups 2
PerSourceNetBlockSize 32:128
# 缩短 preauth 存活时间 = 缩短内存占用时间
LoginGraceTime 20
MaxAuthTries 3
MaxSessions 20
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
UseDNS no
GSSAPIAuthentication no
EOF

  if (( DRY_RUN )); then return 0; fi

  if ! "$SSHD_BIN" -t >/tmp/sshd-t.$$ 2>&1; then
    warn "sshd 配置校验失败，回滚本文件"
    local b
    b="$BACKUP_DIR/$(printf '%s' "${SSHD_DROPIN#/}" | tr '/' '@')"
    if [[ -f $b ]]; then
      cp -a "$b" "$SSHD_DROPIN"
    else
      rm -f "$SSHD_DROPIN"
    fi
    cat /tmp/sshd-t.$$ >&2
    rm -f /tmp/sshd-t.$$
    die "已回滚，主配置未被改动"
  fi
  rm -f /tmp/sshd-t.$$
  ok "sshd 配置校验通过"
}

# ----------------------------------------------------------------------------
# 6. 应用
# ----------------------------------------------------------------------------
stage_apply() {
  step "应用配置"
  if (( DRY_RUN )); then
    printf '%s    $ systemctl daemon-reload && systemctl reload ssh%s\n' "$C_D" "$C_0"
    return 0
  fi
  systemctl daemon-reload
  # reload 走 SIGHUP，不断已建立连接
  if systemctl reload ssh 2>/dev/null; then
    ok "ssh 已 reload（零中断）"
  else
    warn "reload 失败，尝试 restart"
    if ! systemctl restart ssh; then
      die "ssh 重启失败。用云控制台 VNC/串口登录后排查: journalctl -u ssh -n 50"
    fi
    ok "ssh 已 restart"
  fi
}

# ----------------------------------------------------------------------------
# 7. 内核参数
# ----------------------------------------------------------------------------
stage_kernel() {
  if (( ! DO_KERNEL )); then warn "按要求跳过内核参数（--no-kernel）"; return 0; fi
  step "内核参数"
  backup_file /etc/sysctl.d/99-ssh-reserve.conf
  put /etc/sysctl.d/99-ssh-reserve.conf <<EOF
# 由 ssh-reserve ${VERSION} 生成
# 预留空闲内存，避免分配路径进入 direct reclaim 同步扫页表（ssh 卡几十秒的主因）
vm.min_free_kbytes = ${MIN_FREE_KB}
# kswapd 提前到剩余 1.5% 时唤醒，而不是等进程分配时才同步回收
vm.watermark_scale_factor = 150
# 有 swap，保留少量换出能力；太高会让登录卡在 swap-in
vm.swappiness = 20
# 更积极地回收 dentry/inode，把内存让给进程实际占用
vm.vfs_cache_pressure = 100
# 限制脏页堆积，避免 writeback 瞬间打满磁盘 IO 把 sshd 拖进 D 状态
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
EOF
  if (( DRY_RUN )); then return 0; fi
  sysctl --system >/dev/null 2>&1 || true
  ok "已应用: min_free=$(sysctl -n vm.min_free_kbytes)KB swappiness=$(sysctl -n vm.swappiness)"
}

# ----------------------------------------------------------------------------
# 8. journald 限额
# ----------------------------------------------------------------------------
stage_journald() {
  step "journald 日志限额"
  backup_file /etc/systemd/journald.conf.d/50-ssh-reserve.conf
  put /etc/systemd/journald.conf.d/50-ssh-reserve.conf <<EOF
# 由 ssh-reserve ${VERSION} 生成
# 被爆破时 sshd 会狂写失败记录：吃内存、抖动磁盘、写满磁盘导致登录写不了 wtmp
[Journal]
SystemMaxUse=${JOURNAL_MB}M
SystemMaxFileSize=$(( JOURNAL_MB / 6 ))M
SystemMaxFiles=10
RuntimeMaxUse=${JOURNAL_RUNTIME_MB}M
RuntimeMaxFileSize=$(( JOURNAL_RUNTIME_MB / 4 ))M
RateLimitIntervalSec=30s
RateLimitBurst=5000
SyncIntervalSec=1m
EOF
  if (( DRY_RUN )); then return 0; fi
  if systemctl restart systemd-journald 2>/dev/null; then
    ok "journald 已重载"
  else
    warn "journald 重载失败"
  fi
}

# ----------------------------------------------------------------------------
# 9. earlyoom
# ----------------------------------------------------------------------------
stage_earlyoom() {
  if (( ! DO_EARLYOOM )); then warn "按要求跳过 earlyoom（--no-earlyoom）"; return 0; fi
  step "earlyoom（内核 OOM 之前先杀该杀的）"

  if ! command -v earlyoom >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      printf '%s    $ apt-get install -y earlyoom%s\n' "$C_D" "$C_0"
    elif command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom >/dev/null 2>&1 || warn "apt 安装 earlyoom 失败"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y earlyoom >/dev/null 2>&1 || warn "dnf 安装 earlyoom 失败"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y earlyoom >/dev/null 2>&1 || warn "yum 安装 earlyoom 失败"
    else
      warn "没有可用包管理器"
    fi
  fi

  if ! command -v earlyoom >/dev/null 2>&1; then
    warn "earlyoom 不可用，跳过"
    return 0
  fi

  backup_file /etc/default/earlyoom
  put /etc/default/earlyoom <<'EOF'
# 由 ssh-reserve 生成
# 只看内存（-s 100,100 让 swap 条件恒真）：老式 -m/-s 组合是 AND 语义，
# swap 一直充足时 earlyoom 在可用内存只剩 3% 也不会动手。
# --avoid  : 永不选 sshd 和系统核心
# --prefer : 优先选编译工具链
EARLYOOM_ARGS="-r 30 -m 5,2 -M 200000 -s 100,100 --avoid '^(sshd|sshd-session|systemd|systemd-journald|systemd-logind|systemd-udevd|systemd-resolved|dbus-daemon|init|kthreadd)$' --prefer '^(cc1plus|cc1|rustc|java|clang|gcc|ld|make|ninja|go|docker|containerd)(-.*)?$'"
EOF

  if (( DRY_RUN )); then return 0; fi
  systemctl enable earlyoom.service >/dev/null 2>&1 || true
  if systemctl restart earlyoom.service 2>/dev/null; then
    ok "earlyoom 已启动"
  else
    warn "earlyoom 启动失败"
  fi
}

# ----------------------------------------------------------------------------
# 10. 防火墙
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# 11. 把管理脚本落到本地（管道安装时尤其需要）
# ----------------------------------------------------------------------------
stage_persist() {
  step "把管理脚本留在本地"
  if (( DRY_RUN )); then
    printf '%s    [dry-run] %s/{install,uninstall,verify}.sh + /usr/local/bin/ssh-reserve%s\n' \
      "$C_D" "$SSH_RESERVE_LIB" "$C_0"
    return 0
  fi

  mkdir -p "$SSH_RESERVE_LIB"
  local f src local_dir missing=0
  local_dir=""
  if [[ -n ${SELF_PATH:-} && -f ${SELF_PATH:-} ]]; then
    local_dir=$(cd -- "$(dirname -- "$SELF_PATH")" 2>/dev/null && pwd || true)
  fi

  for f in install.sh uninstall.sh verify.sh; do
    src=""
    if [[ -n $local_dir && -f $local_dir/$f ]]; then
      src=$local_dir/$f
    fi
    if [[ -n $src ]]; then
      cp -f "$src" "$SSH_RESERVE_LIB/$f"
    elif command -v curl >/dev/null 2>&1; then
      if curl -fsSL "$RAW_BASE/$f" -o "$SSH_RESERVE_LIB/$f"; then :; else missing=1; fi
    else
      missing=1
    fi
    if [[ -f $SSH_RESERVE_LIB/$f ]]; then chmod +x "$SSH_RESERVE_LIB/$f"; fi
  done

  if (( missing )); then
    warn "部分脚本下载失败（网络？），已装好的配置不受影响"
  fi

  cat > /usr/local/bin/ssh-reserve <<'WRAPEOF'
#!/usr/bin/env bash
# ssh-reserve 管理入口
set -euo pipefail
D=${SSH_RESERVE_LIB:-/usr/local/lib/ssh-reserve}
cmd=${1:-help}
[[ $# -gt 0 ]] && shift || true
case $cmd in
  install)   exec bash "$D/install.sh" "$@" ;;
  uninstall) exec bash "$D/uninstall.sh" "$@" ;;
  verify)    exec bash "$D/verify.sh" "$@" ;;
  status)
    for u in ssh earlyoom; do
      printf '  %-12s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo n/a)"
    done
    swapon --show 2>/dev/null || true
    ;;
  help|-h|--help|*)
    cat <<'H'
ssh-reserve <command>

  install [--swap-size 2G] [--dry-run ...]   部署 / 重新应用配置
  uninstall [--remove-swap]                   卸载（默认保留 swap）
  verify                                      压测复验：负载下 ssh 还能不能连
  status                                      当前状态

脚本目录: /usr/local/lib/ssh-reserve
H
    ;;
esac
WRAPEOF
  chmod +x /usr/local/bin/ssh-reserve
  ok "脚本已落到 $SSH_RESERVE_LIB"
  ok "管理命令: ssh-reserve {install|uninstall|verify|status}"
}

# ----------------------------------------------------------------------------
# 12. 结果
# ----------------------------------------------------------------------------
stage_report() {
  step "结果"
  if (( DRY_RUN )); then warn "dry-run 结束，没有改动任何文件"; return 0; fi

  local unit st cg
  for unit in ssh earlyoom; do
    st=$(systemctl is-active "$unit" 2>/dev/null || true)
    if [[ $st == active ]]; then
      ok "$unit: active"
    else
      warn "$unit: ${st:-unknown}"
    fi
  done

  local mp=${MAIN_PORTS% }
  mp=${mp// /, }
  ok "sshd 监听端口：${mp}/tcp"

  if (( CG_V2 )); then
    cg=/sys/fs/cgroup/system.slice/ssh.service
    local v
    v=$(cat "$cg/memory.min" 2>/dev/null || echo 0)
    if (( v > 0 )); then
      ok "sshd cgroup: min=$(( v / 1048576 ))M max=$(( $(cat "$cg/memory.max" 2>/dev/null || echo 0) / 1048576 ))M cpu.weight=$(cat "$cg/cpu.weight" 2>/dev/null || echo '?') swap.max=$(cat "$cg/memory.swap.max" 2>/dev/null || echo '?')"
    else
      warn "sshd cgroup: memory.min 未生效（容器内 cgroup 多为只读，属预期）"
      warn "  仍然生效的保护：Nice=-10 / OOMScoreAdjust=-1000 / IO 优先级 / Restart=always"
    fi
    v=$(cat /sys/fs/cgroup/system.slice/memory.min 2>/dev/null || echo 0)
    if (( v > 0 )); then
      ok "system.slice: min=$(( v / 1048576 ))M"
    else
      warn "system.slice: MemoryMin 未生效（宿主未下放 memory 控制器）"
    fi
  fi

  swapon --show 2>/dev/null | sed 's/^/     /' || true

  printf '\n'
  log "备份在 $BACKUP_DIR"
  log "改坏了：ssh-reserve uninstall"
  log "压测复验：ssh-reserve verify"
  log "当前状态：ssh-reserve status"
}

# ----------------------------------------------------------------------------
main() {
  log "ssh-reserve ${VERSION}"
  if (( DRY_RUN )); then warn "DRY-RUN 模式：只打印，不落盘"; fi
  stage_preflight
  derive_params
  stage_swap
  stage_migrate
  stage_ssh_cgroup
  stage_slice
  stage_sshd_harden
  stage_apply
  stage_kernel
  stage_journald
  stage_earlyoom
  stage_persist
  stage_report
  printf '\n%s完成。%s\n' "$C_G" "$C_0"
}

main "$@"
