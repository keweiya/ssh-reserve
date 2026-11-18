#!/usr/bin/env bash
# =============================================================================
#  ssh-reserve 卸载
#
#  用法：
#    bash uninstall.sh                  # 撤销 ssh 预留改动，保留 swap
#    bash uninstall.sh --remove-swap    # 连 swap 一起删（谨慎）
#    bash uninstall.sh --keep-earlyoom  # 保留 earlyoom
#    bash uninstall.sh --from DIR       # 指定备份目录（默认取最近一次）
#
#  行为：
#    - 停用并删除 ssh-rescue.service
#    - 用备份还原被覆盖的文件；没有备份的（本脚本新增的）直接删除
#    - 安全校验通过后才 reload sshd，校验失败则拒绝 reload
# =============================================================================
set -Eeuo pipefail

REMOVE_SWAP=0
KEEP_EARLYOOM=0
BACKUP_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --remove-swap)    REMOVE_SWAP=1; shift ;;
    --keep-earlyoom)  KEEP_EARLYOOM=1; shift ;;
    --from)           BACKUP_DIR=${2:?--from 需要目录}; shift 2 ;;
    --from=*)         BACKUP_DIR=${1#*=}; shift ;;
    -h|--help)        sed -n '3,16p' "$0" | sed 's/^#  \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then echo "需要 root" >&2; exit 1; fi

SSHD_BIN=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)

if [[ -z $BACKUP_DIR ]]; then
  BACKUP_DIR=$(ls -1d /var/backups/ssh-reserve/*/ 2>/dev/null | sort | tail -1 || true)
  BACKUP_DIR=${BACKUP_DIR%/}
fi

echo "备份目录: ${BACKUP_DIR:-（无）}"

restore_or_remove() {
  local target=$1
  local bname=""
  if [[ -n $BACKUP_DIR ]]; then
    bname="$BACKUP_DIR/$(printf '%s' "${target#/}" | tr '/' '@')"
  fi
  if [[ -n $bname && -f $bname ]]; then
    mkdir -p "$(dirname "$target")"
    cp -a "$bname" "$target"
    echo "  还原 $target"
  else
    rm -f "$target"
    echo "  删除 $target"
  fi
}

echo
echo "== 1/6 停止救援实例 =="
systemctl disable --now ssh-rescue.service 2>/dev/null || true
rm -f /run/sshd-rescue.pid

echo
echo "== 2/6 还原 / 删除配置文件 =="
restore_or_remove /etc/systemd/system/ssh-rescue.service
restore_or_remove /etc/systemd/system/ssh.service.d/50-ssh-reserve.conf
restore_or_remove /etc/systemd/system/system.slice.d/50-ssh-reserve.conf
restore_or_remove /etc/systemd/system/user.slice.d/50-ssh-reserve.conf
restore_or_remove /etc/systemd/system/heavy.slice
restore_or_remove /etc/ssh/sshd_config.d/99-ssh-reserve.conf
restore_or_remove /etc/sysctl.d/99-ssh-reserve.conf
restore_or_remove /etc/systemd/journald.conf.d/50-ssh-reserve.conf
restore_or_remove /usr/local/bin/heavy
if [[ -f /usr/local/bin/heavy ]]; then chmod +x /usr/local/bin/heavy; fi
# 清理空目录
rmdir /etc/systemd/system/ssh.service.d 2>/dev/null || true
rmdir /etc/systemd/system/system.slice.d 2>/dev/null || true
rmdir /etc/systemd/system/user.slice.d 2>/dev/null || true
rmdir /etc/systemd/journald.conf.d 2>/dev/null || true

echo
echo "== 3/6 sshd 配置校验 =="
if "$SSHD_BIN" -t; then
  echo "  校验通过"
  SSHD_OK=1
else
  echo "  校验失败！先修 /etc/ssh/sshd_config 再 reload，当前 sshd 仍在跑旧配置" >&2
  SSHD_OK=0
fi

echo
echo "== 4/6 重新加载 systemd / sysctl =="
systemctl daemon-reload
sysctl --system >/dev/null 2>&1 || true
systemctl restart systemd-journald 2>/dev/null || true
if [[ $SSHD_OK -eq 1 ]]; then
  systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

echo
echo "== 5/6 earlyoom =="
if (( KEEP_EARLYOOM )); then
  echo "  按要求保留"
else
  systemctl disable --now earlyoom.service 2>/dev/null || true
  rm -f /etc/default/earlyoom
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y earlyoom >/dev/null 2>&1 || true
  fi
  echo "  已卸载"
fi

echo
echo "== 6/6 swap =="
if (( REMOVE_SWAP )); then
  SWAP_FILE=/swapfile
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$SWAP_FILE"; then
    swapoff "$SWAP_FILE" && echo "  swapoff $SWAP_FILE"
  fi
  rm -f "$SWAP_FILE" && echo "  删除 $SWAP_FILE"
  if [[ -f /etc/fstab ]]; then
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    # 删除我们加的注释行与对应条目
    awk -v f="$SWAP_FILE" '
      /^# ssh-reserve: persistent swap$/ {getline; next}
      $1==f && $3=="swap" {next}
      {print}
    ' /etc/fstab > /tmp/fstab.new && mv /tmp/fstab.new /etc/fstab
    echo "  清理 /etc/fstab"
  fi
else
  echo "  保留 swap（要用 --remove-swap 才删）"
fi

echo
echo "卸载完成。当前状态："
for u in ssh ssh-rescue earlyoom; do
  printf "  %-12s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null || echo inactive)"
done
swapon --show 2>/dev/null | sed 's/^/  /' || true
