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
| `--swap-size SIZE` | swap 大小，默认 `auto` = `clamp(内存, 2G, 4G)`；也可显式 `512M` / `2G` / `4G` / `1T` |
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

## 从旧版"保活"方案迁移

如果你之前手工做过一套 ssh 保活（直接改 `ssh.service`、往 `/etc/sysctl.conf` 加参数、装 `softdog`），
建议先清理再装。一条命令：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@v1.3.0/install.sh | sudo bash --clean-legacy
```

`--clean-legacy` 只做清理，不改其它任何东西；清理前会备份到 `/var/backups/ssh-reserve/`。

### 旧方案里有两处会帮倒忙

**① `CPUSchedulingPolicy=rr` + `CPUSchedulingPriority=99`**

给 sshd 配实时调度，看着像"最高优先级"，实际是**整机卡死的捷径**：

- `rr/99` 会饿死同 CPU 上的所有普通进程，包括 systemd、journald
- 登录后的 shell 会**继承**这个策略，在里面跑一条死循环就够把机器弄死
- 一旦生效，CFS 的 `CPUWeight` 完全失效（实时调度不走权重分配）

**② `vm.panic_on_oom=1`**

内存耗尽时直接 panic 重启整机，和"保住 SSH"的目标正好相反 —— 你想让 SSH 活着，
结果 SSH 被重启带走，还要等 panic timeout。而且它让内核放弃了 OOM killer
挑选受害进程的能力：哪怕只差几十 MB，也可能是整机重启而不是杀掉一个吃内存的进程。

### 各项处理方式

| 旧配置 | 处理 |
|---|---|
| `CPUSchedulingPolicy=rr` / `CPUSchedulingPriority=99` | **移除**，并用 `restart`（不是 `reload`）让它真正失效 |
| `vm.panic_on_oom=1` | 注释掉，恢复默认 0 |
| `OOMScoreAdjust=-1000` / `CPUWeight=1000` / `MemoryMin=32M` | 由 drop-in 接管，调整为 10000 / 96M |
| `/etc/sysctl.conf` 的 `vm.swappiness=10` | 注释掉，改用 `/etc/sysctl.d/99-ssh-reserve.conf` 的 20 |
| `kernel.panic=60` | 注释掉，避免和无意义的重启耦合 |
| `softdog` + `RuntimeWatchdogSec=60s` | 移除（理由见下） |
| `ShutdownWatchdogSec=10min` | **保留**，关机卡住时硬重启是有用的 |
| `EARLYOOM_ARGS="-m 4 -s 5"` | 覆盖为 `-m 5,2 -s 100,100` |
| fstab 缺 `pri=`（显示成负数 PRIO） | 自动补成 `sw,pri=10` |

### 为什么 softdog 起不到兜底作用

软件看门狗靠内核定时器喂狗。**内核真死锁时，定时器本身也停了**，狗不会叫；
反过来，systemd 因为 journald 阻塞、cgroup 操作卡顿之类的软故障超过 60 秒，
它又会**误判成死机直接重启整机**。对"低价 VPS、重启一次要很久"的场景，
这是负收益。真正的硬兜底是云控制台的强制重启，不是 softdog。

### 为什么 `/etc/sysctl.conf` 必须清理

`sysctl --system` 的读取顺序是 `sysctl.d/*.conf` → `sysctl.conf` 在前，
`/etc/sysctl.conf` **最后读**，后读的覆盖先读的。实测：

```
sysctl.d 里写 vm.swappiness = 20            → 生效 20
再往 /etc/sysctl.conf 加 vm.swappiness=10   → 生效 10   ← 被静默覆盖
```

所以旧方案写在 `sysctl.conf` 的参数会盖掉新配置，必须处理，否则你以为装好了其实没生效。

---

## 容器 / 小硬盘环境（LXC、Docker、K8s pod）

这些环境里 swap 通常开不起来，原因不止一个：

- 容器没有 `CAP_SYS_ADMIN`，`swapon` 直接失败
- 宿主机把 `memory.swap.max` 设成 0 或没下放 swap 控制器
- 根文件系统是只读层或镜像层，写不了几 GB 的文件

**脚本会自动识别并跳过 swap**，只做 ssh 资源预留，不中断：

```
ok 容器环境: lxc（swap 将默认跳过，cgroup 设置可能受宿主限制）
!! 容器环境（lxc）：swap 通常不可用，跳过
!! 确需尝试请显式指定：--swap-size 2G
```

硬盘不够时同样优雅降级：

```
==> swap（自动：内存 1922M → clamp(2G,4G)，文件 /swapfile）
  ok 文件系统: ext4
!! 磁盘不足：需要 2304M，剩余 191M
!! 跳过 swap，继续做 ssh 资源预留 —— swap 只是缓冲，预留不依赖它
```

只有**你显式指定 `--swap-size` 且磁盘放不下**时才会报错退出，因为那属于明确要求但做不到。

### 手动关闭

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/keweiya/ssh-reserve@v1.2.0/install.sh | sudo bash --no-swap
```

`--no-swap` 只表示"本次不创建/修改 swap"，**不会**删除已有的 swap 文件或 `/etc/fstab` 条目。

### 容器里 cgroup 可能设不上

容器内 `/sys/fs/cgroup` 常是只读挂载，`memory.min` / `CPUWeight` 写不进去。
脚本会读回实际值来判断，而不是写进去就当成功：

```
!! sshd cgroup: memory.min 未生效（容器内 cgroup 多为只读，属预期）
!!   仍然生效的保护：Nice=-10 / OOMScoreAdjust=-1000 / IO 优先级 / Restart=always
```

这种情况下降级后的保护里，`oom_score_adj=-1000` 和 `nice=-10` 是**进程属性**，
不受 cgroup 只读限制，对"ssh 连不上"依然有效；少掉的是内存侧的硬保留。

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

## swap 怎么定大小

默认 `auto`，规则是 `clamp(RAM, 2G, 4G)`：

| 内存 | auto 结果 | 说明 |
|---|---|---|
| ≤ 2 GB | **2 GB** | 小机器给足缓冲 |
| 4 GB | **4 GB** | = RAM |
| ≥ 8 GB | **4 GB** | 封顶 |

### 为什么不是传统教科书的 2×

- **swap 是回收区，不是内存扩展。** 它的作用是给内存压力一个缓冲，
  让内核回收和 earlyoom 有时间反应，而不是让进程无限跑下去。
- **给太多会拖长抖动窗口。** 1.9 GB 内存配 4 GB swap，一旦工作集超过 RAM，
  系统会持续在磁盘和内存之间换页，`wa` 飙高，**ssh 反而更卡** —— 正是要避免的情况。
- **大 swap 还会推迟 earlyoom 介入**，等于削弱了保护。
- 容量从来不是瓶颈，带宽才是。nvme 上 2 GB 和 4 GB 的随机读写性能一样。

实测这台 1.9 GB 机器（做过多次内存压测）：

```
累计 swap out : 18160 MiB
累计 swap in  : 15557 MiB
当前占用      : 23.5 MiB
实时 si/so    : 0 / 0
```

swap 确实在压力时吸收了大量匿名页，但 2 GB 的容量足够周转。

### 什么情况该显式调

| 场景 | 做法 |
|---|---|
| 有休眠需求（笔记本 / `systemctl hibernate`） | `--swap-size` 设为 **≥ 内存** |
| Java 大堆 / Elasticsearch / 数据库 | 反而建议降 `swappiness` 或关 swap，**不是加大** |
| 容器宿主机 | 往往禁用 swap，避免破坏 cgroup 内存隔离 |
| 内存 ≥ 8 GB 但 swap 只有 512 MB | `--swap-size 4G`，让冷页有地方去 |

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
