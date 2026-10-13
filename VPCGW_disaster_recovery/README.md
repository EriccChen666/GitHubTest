# 容灾连通性监控脚本 使用手册

一组纯 Bash 脚本，用来持续探测服务映射的 TCP 连通性，记录每次中断的开始、结束和持续时长。

---

## 1. 脚本一览

| 脚本 | 部署位置 | 作用 |
|---|---|---|
| `tcp_monitor.sh` | 探测端（CLI） | 持续探测 TCP 端口（VPC / 物理网络服务映射），记录中断时间段 |
| `setup_tcp_cron.sh` | 探测端（CLI） | 把 `tcp_monitor.sh` 注册到 crontab（开机自启 + 守护） |
| `rs_listener.sh` | 被探测端（RS） | 在 RS 上一直监听指定 TCP 端口，作为探测目标 |
| `setup_rs_cron.sh` | 被探测端（RS） | 把 `rs_listener.sh` 注册到 crontab，RS 重启后监听自动恢复 |

典型拓扑：

```
[CLI 探测端] --tcp_monitor--> VIP:VPORT --(服务映射)--> [RS:RS_PORT] rs_listener
```

---

## 2. 环境要求

- Linux + Bash 4.x
- `nc`（netcat）：`rs_listener.sh` **必须有**；`tcp_monitor.sh` 优先用 nc，没有时依次退回 `python3`、bash `/dev/tcp`
  - 安装：`yum install nmap-ncat` 或 `apt install netcat-openbsd`
- `timeout`（coreutils）：建议安装，用来保证 SYN 黑洞时探测不会卡住（没有时脚本会用 Bash 软超时代替）
- `crontab`：`setup_*_cron.sh` 需要
- 默认日志目录在 `/var/log/` 下，建议用 root 运行，否则请用 `-d` 指定一个有写权限的目录

部署（CLI 和 RS 都可以全量拷贝，按角色使用）：

```bash
mkdir -p /opt/tcpmon && cp *.sh /opt/tcpmon/ && chmod +x /opt/tcpmon/*.sh
```

> `setup_*_cron.sh` 会按**自身所在目录**去找对应的监控脚本，两者要放在同一目录。

---

## 3. TCP 端口监控：`tcp_monitor.sh` / `setup_tcp_cron.sh`

适用于 **VPC 私有网络服务映射**（`-k vpc`）和**物理网络服务映射**（`-k underlay`）。判断标准是能否和 `IP:PORT` 完成 TCP 三次握手，不依赖 ICMP。

### 3.1 直接运行

```bash
./tcp_monitor.sh -k <vpc|underlay> -t <目标> -p <端口> [选项]
```

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-k` | 映射类型 `vpc` / `underlay`，**必填** | - |
| `-t` | 目的地址（IPv4 / IPv6 / 域名），**必填** | - |
| `-p` | 目的 TCP 端口，**必填** | - |
| `-6` | 强制 IPv6（地址里带 `:` 时自动识别） | 自动 |
| `-d` | 日志目录 | `/var/log/tcp_monitor` |
| `-i` | 探测间隔（秒） | 1 |
| `-T` | 连续失败多少次判为中断 | 3 |
| `-w` | 单次连接超时（秒）；硬超时 = `-w` + 2s | 2 |
| `-S` | 源 IP | 自动 |

示例：

```bash
./tcp_monitor.sh -k vpc      -t 10.0.0.23    -p 3306
./tcp_monitor.sh -k underlay -t 172.16.5.8   -p 8080 -S 10.0.0.5
./tcp_monitor.sh -k vpc      -t 2400:da00::1 -p 443  -6
```

### 3.2 注册为常驻任务（推荐）

```bash
./setup_tcp_cron.sh add -k vpc -t 10.0.0.23 -p 3306                 # 添加并立即启动
./setup_tcp_cron.sh add -k underlay -t 172.16.5.8 -p 8080 -S 10.0.0.5
./setup_tcp_cron.sh del -k vpc -t 10.0.0.23 -p 3306                 # 删除任务并停止进程（不带 -S 时含所有源 IP 变体）
./setup_tcp_cron.sh list                                            # 查看 cron 任务和运行中的进程
```

`add` 支持 `tcp_monitor.sh` 的全部参数（`-6 -d -i -T -w -S`）。`kind + target + port (+ src)` 唯一确定一个任务，其中任意一项不同都算不同任务。

---

## 4. RS 端监听：`rs_listener.sh` / `setup_rs_cron.sh`

在 RS 上一直监听某个端口，给 `tcp_monitor.sh` 当探测目标。脚本启动时会自动识别本机 nc 的监听语法（`nc -l <port>` 或 `nc -l -p <port>`）。

### 4.1 直接运行

```bash
./rs_listener.sh -k <vpc|underlay> -p <端口> [选项]
```

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-k` | 映射类型 `vpc` / `underlay`，**必填** | - |
| `-p` | 监听端口，**必填** | - |
| `-6` | IPv6 监听 | IPv4 |
| `-b` | 只在指定的本机 IP 上监听 | 所有地址 |
| `-d` | 日志目录 | `/var/log/rs_listener` |
| `-m` | 有连接进来时回显的内容（支持 `\n` 等转义） | 不回显 |
| `-r` | 监听异常退出后多久重启（秒） | 1 |

示例：

```bash
./rs_listener.sh -k vpc      -p 3306
./rs_listener.sh -k underlay -p 8080 -b 10.0.0.23
./rs_listener.sh -k vpc      -p 443  -6
./rs_listener.sh -k vpc      -p 9000 -m "RS-OK\n"
```

### 4.2 注册为常驻任务（推荐）

```bash
./setup_rs_cron.sh add -k vpc -p 3306                     # 添加并立即启动
./setup_rs_cron.sh add -k underlay -p 8080 -b 10.0.0.23
./setup_rs_cron.sh del -k vpc -p 3306                     # 删除任务并停止进程（不带 -b 时含所有 bind 变体）
./setup_rs_cron.sh list                                   # 查看 cron 任务、进程，以及 ss -ltn 监听端口
```

`add` 支持 `rs_listener.sh` 的全部参数（`-6 -b -d -m -r`）。`kind + port (+ bind)` 唯一确定一个任务。

---

## 5. 常驻机制（两个 setup 脚本相同）

`add` 会往 crontab 写入 3 行，并立即在后台启动一个进程：

```
# TCP_MONITOR_TAG=<kind>:<target>:<port>[@src]   或   # RS_LISTENER_TAG=<kind>:<port>[@bind]
@reboot   <cmd> >/dev/null 2>&1      # 开机自启
* * * * * <cmd> >/dev/null 2>&1      # 每分钟检查一次，进程不在就拉起
```

- **单实例**：脚本用 pidfile（日志目录下的 `.tcp_<tag>.pid` / `.rs_<tag>.pid`）防止重复运行，并通过 `/proc/<pid>/cmdline` 核对进程，避免重启后 PID 被别的进程复用导致误判
- **重复 add 同一任务**：会覆盖旧记录，不会重复写入
- **del**：删除 crontab 记录，结束进程，清理 pidfile

---

## 6. 日志说明

### 6.1 文件命名

| 脚本 | 每日全量日志 | 中断事件日志 |
|---|---|---|
| tcp_monitor | `tcp_<kind>_<user>_<target>_<port>[_from_<src>]_YYYYMMDD.log` | `outage_<kind>_<user>_<target>_<port>[_from_<src>].log` |
| rs_listener | `rs_<kind>_<user>_<port>[_bind_<ip>]_YYYYMMDD.log` | - |

IPv6 地址中的 `:` 和 `/` 会替换成 `_`。

### 6.2 关键字

| 关键字 | 含义 |
|---|---|
| `START` / `ENV` | 启动信息：主机、内核、探测方式、解析 IP、路由、出接口、MTU、源 IP 校验结果、nc 监听语法 |
| `FAIL` | （tcp）单次探测失败（带 `miss` 连续失败次数和 `reason` 失败原因） |
| `OUTAGE START` | （tcp）连续失败次数达到阈值，判定中断；开始时间回溯到第一次失败 |
| `OUTAGE ONGOING` | （tcp）中断期间每 60s 记录一次，含已持续时长和最近一次失败原因 |
| `OUTAGE END` | （tcp）恢复，含 `start` / `end` / `duration` |
| `SUMMARY` | 每 60s 汇总。tcp：发送数、失败数、失败率、建连耗时 min/avg/max；rs：接入次数、监听重启次数 |
| `ACCEPT` | （rs）处理了一次连接 |
| `LISTEN RESTART` | （rs）监听没起来（端口被占用、权限不足或参数不兼容），稍后重试 |
| `state=IDLE` | （rs）本窗口内没有连接进来，上游可能有故障 |

常用查询：

```bash
cat  /var/log/tcp_monitor/outage_*.log                    # 所有中断记录
grep -h "OUTAGE END" /var/log/tcp_monitor/outage_*.log    # 每次中断的持续时长
tail -f /var/log/tcp_monitor/tcp_*_$(date +%Y%m%d).log    # 实时查看探测端
tail -f /var/log/rs_listener/rs_*_$(date +%Y%m%d).log     # 实时查看 RS 端
```

---

## 7. 常见问题

| 现象 | 排查方向 |
|---|---|
| 进程没起来，也没有日志 | 检查 `-d` 目录是否有写权限；pidfile 是否残留（`list` 查看，`del` 后重新 `add`） |
| `source_ip_check=WARN` | 本机没有 `-S` 指定的源 IP |
| rs 日志一直刷 `LISTEN RESTART` | 端口被占用（`ss -ltnp \| grep :<port>`）、端口 < 1024 但不是 root 运行，或 nc 版本不兼容 |
| rs 日志提示 `WARN 未能自动探明 nc 监听语法` | 换成 nmap-ncat 或 netcat-openbsd |
| tcp 日志提示 `WARN 系统无 timeout 命令` | 安装 coreutils，黑洞场景下探测会更及时 |
| 正常时偶尔出现单次 `FAIL refused` | rs_listener 每处理完一个连接都要重新 listen，中间有极短空窗；单次失败不会触发中断（阈值 `-T` 默认 3） |
