# ssh-reserve

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-systemd%20%7C%20cgroup%20v2-informational)](https://github.com/keweiya/ssh-reserve)
[![Swap](https://img.shields.io/badge/swap-2G%20by%20default-green)](https://github.com/keweiya/ssh-reserve)

**小服务器跑重活之后 SSH 连不上？一条命令给 sshd 预留 CPU / 内存，并加 2G swap 兜底。**

针对 2C / 2G 这类小云主机：编译、构建、爬虫、压测把机器压满之后，`ssh` 不是密码错，而是 TCP 都慢、banner 都要等十几秒、或者直接 `Connection timed out`。

`ssh-reserve` 用 cgroup v2 给 sshd 做资源预留，再用 swap + earlyoom 兜底，让负载打满时依然**连得上、登得进**。

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@main/install.sh | sudo bash
```

默认创建 **2G swap**，其余自动按机器内存/核数调参。支持 `--dry-run` 先看再做。

---

## 为什么 ssh 会连不上

不是因为 sshd 缺 CPU。真实原因按出现频率排：

| 原因 | 机制 | 表现 |
|---|---|---|
| **内存打满导致 fork 失败** | sshd 每接一个连接要 `fork()`，内存不足时 `fork: Cannot allocate memory` | 能 ping 通，但连不上或连上立刻断 |
| **sshd 被换出到 swap** | 内存紧张时 sshd 的页被换出，登录时 swap-in 要几十秒 | 卡在 `Connection established` 之后不动 |
| **磁盘 IO 打满** | sshd 认证要读 `/etc/passwd`、写 `wtmp`/`journald`，IO 排队时进程进 `D` 状态 | 登录 hang，`ps` 里 sshd 是 `D` |
| **连接风暴挤死 sshd** | `MaxStartups 30:30:100` 允许 100 个 preauth 进程，每个 4–6M | 被爆破时 sshd 自己吃掉 500M |
| **内核 OOM 挑错人** | 没有 `oom_score_adj` 保护，OOM killer 可能选中关键进程 | 服务莫名消失 |

CPU 排在最后：cgroup 权重足够解决，而且 sshd 本身几乎不吃 CPU。

---

## 它做什么

四层保护，逐层兜底：

```
① swap（默认 2G）
   └─ 给内存压力一个缓冲，避免直接走到 OOM

② sshd 的 cgroup 配额（cgroup v2）
   ├─ CPUWeight=10000       与重负载争抢时抢占优先权（默认 100）
   ├─ Nice=-10              认证路径延迟更低
   ├─ IOWeight=10000        磁盘打满时不卡在 D 状态
   ├─ MemoryMin=96M         memory.min 是硬保留，回收碰不到
   ├─ MemorySwapMax=0       禁止换出，不卡 swap-in
   ├─ OOMScoreAdjust=-1000  内核 OOM 永不选它
   └─ OOMPolicy=continue    一次 cgroup OOM 不停整个 unit

③ slice 层额度
   ├─ system.slice  memory.min=640M    父层额度，让 ② 成为绝对保护
   ├─ user.slice    CPUQuota=150%      登录 shell 落这里，留 0.5 核给系统
   └─ heavy.slice   重活隔离区，超额在这里被节流

④ earlyoom
   └─ 内存 ≤5% 时 SIGTERM，≤2% 时 SIGKILL
      永不选 sshd / systemd，优先选编译工具链
```

> **v1.1.0 起移除了早期的"救援 sshd 实例"（第二个端口 2222）。**
> 原因很直接：ssh 连不上是资源问题，多开一个端口解决不了，反而多一个爆破入口；
> 而且它和主实例共用同一份 `sshd_config`，配置改错时一样起不来。
> 旧版本装过的实例会在安装时自动清理。

---

## 安装

### 一行（推荐）

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@main/install.sh | sudo bash
```

> `raw.githubusercontent.com` 在某些网络环境下会被边缘节点缓存较久（实测有拿到过几个前版本的），
> jsDelivr 镜像刷新快得多。要完全可复现就用固定 tag 版本：
>
> ```bash
> curl -fsSL https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@v1.0.1/install.sh | sudo bash
> ```

### 先看再做

```bash
curl -fsSL -o install.sh https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@main/install.sh
sudo bash install.sh --dry-run
sudo bash install.sh
```

### 指定 swap 大小

```bash
sudo bash install.sh --swap-size 4G
sudo bash install.sh --swap-size 512M
sudo bash install.sh --no-swap          # 完全不动 swap
```

### 参数

| 参数 | 说明 |
|---|---|
| `--swap-size SIZE` | swap 大小，默认 `2G`（支持 `512M` / `2G` / `4G` / `1T`） |
| `--swap-file PATH` | swap 文件位置，默认 `/swapfile` |
| `--no-swap` | 不创建/修改 swap |
| `--no-earlyoom` | 不安装 earlyoom |
| `--no-slice` | 不设置 slice 层 CPU/内存上限 |
| `--no-kernel` | 不改内核参数 |
| `--force` | 覆盖非 swap 的已存在文件 |
| `--dry-run` | 只打印，不落盘 |
| `--uninstall` | 卸载 |

---

## 实测数据

环境：AWS 2 vCPU / 1922 MiB / 2 GiB swap，Debian 12，systemd 252，cgroup v2。

压测方式：`heavy.slice` 内 4 个进程跑满 CPU + 分配 900 MiB，受 `CPUQuota=150%` 与 `MemoryMax` 约束。

| 指标 | 空闲 | 压测中 |
|---|---|---|
| MemAvailable | 770 MiB | **60 MiB (3.14%)** |
| ssh banner 延迟（主端口） | 19 ms | 35 / 58 / 91 ms |
| sshd `memory.events` `low/high/max/oom_kill` | 0 | **全部为 0** |
| sshd `memory.current` | 9 MiB | 9 MiB（`memory.min=96M` 未被回收） |
| 服务存活 | — | ssh / earlyoom **全部 active** |

earlyoom 介入实测：

```
mem avail: 55 of 1922 MiB (2.87%)
low memory! at or below SIGTERM limits
sending SIGTERM to process 160193 uid 0 "python3": badness 826, VmRSS 951 MiB
process exited after 0.1 seconds
mem avail: 998 of 1922 MiB (51.95%)
```

杀掉的是压测进程，sshd 和业务进程未被选中。

复验：

```bash
sudo bash verify.sh
```

---

## 日常用法

### 跑重活：塞进 heavy.slice

```bash
heavy make -j16                    # 编译
heavy bash                         # 受管制的交互 shell
heavy --unit=b1 npm run build      # 指定 unit 名，便于 systemctl stop b1
systemd-run --slice=heavy.slice --scope -t bash   # 等价写法
```

超额部分由 `heavy.slice` 的 `CPUQuota` / `MemoryMax` 节流，不会传染给 sshd。

### 登录

```bash
ssh -p <主端口> root@host
```

只有主 sshd 一个端口。真正的保险是云控制台的 VNC / 串口控制台，不是再开一个 sshd。

### 常用检查

```bash
systemctl status ssh earlyoom
systemctl show ssh -p MemoryCurrent -p MemoryMin -p MemoryMax -p CPUWeight
grep -E "^(low|high|max|oom_kill)" /sys/fs/cgroup/system.slice/ssh.service/memory.events
journalctl -u earlyoom -n 20 -o cat
```

---

## 排障

**改完 ssh 配置后连不上**

```bash
# 先通过云控制台 VNC / 串口进入
/usr/sbin/sshd -t              # 验语法
systemctl status ssh
journalctl -u ssh -n 50
```

**sshd 一直被 cgroup 节流**

```bash
grep -E "^(low|high|max|oom_kill)" /sys/fs/cgroup/system.slice/ssh.service/memory.events
```

`high` 持续增长 → 调高 `MemoryHigh`；`oom_kill` 出现 → 检查 `MaxStartups` 是否被调回去了。

**earlyoom 杀错了进程**

```bash
journalctl -u earlyoom -n 30 -o cat | grep "sending SIG"
```

把对应进程名加进 `/etc/default/earlyoom` 的 `--avoid` 正则，`systemctl restart earlyoom`。

**登录后 shell 被限得太狠**

```bash
systemctl set-property user.slice CPUQuota=200%   # 立即生效，重启后回落
```

---

## 卸载

```bash
sudo bash uninstall.sh                  # 撤销改动，保留 swap
sudo bash uninstall.sh --remove-swap    # 连 swap 一起删
sudo bash uninstall.sh --keep-earlyoom  # 保留 earlyoom
```

卸载会先用备份还原被覆盖的文件，没有备份的（脚本新增的）直接删除；`sshd -t` 校验通过后才 reload，校验失败则保留旧配置继续跑。

备份位置：`/var/backups/ssh-reserve/<时间戳>/`

---

## 兼容性

| 项目 | 要求 |
|---|---|
| 系统 | 任何 systemd 发行版（Debian 12 / Ubuntu 22.04+ / Rocky 9 / Alma 9 / openEuler） |
| cgroup | **v2**（`memory.min` / `cpu.weight` 需要）；v1 系统自动降级为 `nice` + IO 优先级 + swap + earlyoom |
| 权限 | root |
| SSH | OpenSSH 8.1+（`PerSourceMaxStartups` 需要） |

参数全部按机器内存和核数推导，1G / 2G / 4G / 8G 机器都能用：

| 机器 | sshd `memory.min` | system.slice `min` | user.slice `CPUQuota` |
|---|---|---|---|
| 1 GB | 64M | 384M | 75% |
| 2 GB | 96M | 634M | 150%（2 核） |
| 4 GB | 128M | 1351M | 300%（4 核） |

---

## 相关取舍

**为什么 `Nice=-10` 而不是 `-20`**：登录后的 shell 会继承该值，`-20` 会让用户的命令压制系统进程，反而放大问题。

**为什么 `OOMPolicy=continue`**：默认 `stop` 会让一次 cgroup 内 OOM 停掉整个 `ssh.service`，这正是"服务莫名消失"的来源。

**为什么 `MemorySwapMax=0`**：sshd 只有 10M 左右，禁掉换出成本极低，但能彻底避免登录卡在 swap-in。

**为什么不给 `system.slice` 设 `CPUQuota`**：限制系统服务会在关键时刻连 `systemd-journald` 都饿死，反而放大问题。

**为什么 earlyoom 用 `-s 100,100`**：`-m` / `-s` 是 AND 语义，swap 一直充足时 earlyoom 在内存只剩 3% 也不会动手。把 swap 条件设为恒真，才能真正按内存判断。

---

## 许可

MIT
