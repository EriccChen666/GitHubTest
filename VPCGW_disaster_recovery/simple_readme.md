# 容灾 TCP 连通性监控 快速使用

**前提：** 两端都要装 `nc`（`yum install nmap-ncat` / `apt install netcat-openbsd`），用 root 执行。

```
[CLI 探测端] --tcp_monitor--> 映射IP:映射端口 --(服务映射)--> [RS:RS端口] rs_listener
```

## 1. RS 端（被探测的服务器）：起监听

```bash
mkdir -p /opt/tcpmon && cp rs_listener.sh setup_rs_cron.sh /opt/tcpmon/ && chmod +x /opt/tcpmon/*.sh
cd /opt/tcpmon
./setup_rs_cron.sh add -k vpc -p <RS端口>      # 物理网络服务映射把 vpc 换成 underlay
```

## 2. CLI 端（探测机）：起探测

```bash
mkdir -p /opt/tcpmon && cp tcp_monitor.sh setup_tcp_cron.sh /opt/tcpmon/ && chmod +x /opt/tcpmon/*.sh
cd /opt/tcpmon
./setup_tcp_cron.sh add -k vpc -t <映射IP> -p <映射端口>    # 指定源 IP 时加 -S <源IP>
```

`add` 会马上在后台启动，同时写入 crontab：开机自启，每分钟检查一次，进程没了就重新拉起。设备重启后也会自动恢复。

## 3. 管理（两端用法一样）

```bash
./setup_rs_cron.sh  list   /   ./setup_tcp_cron.sh list    # 查看任务和进程
./setup_rs_cron.sh  del -k vpc -p <RS端口>                  # 删除任务并停止进程
./setup_tcp_cron.sh del -k vpc -t <映射IP> -p <映射端口>
```

## 4. 看结果

日志位置（可用 `-d <目录>` 修改）：

| 设备 | 目录 | 文件 | 内容 |
|---|---|---|---|
| CLI 端 | `/var/log/tcp_monitor/` | `tcp_<kind>_<user>_<映射IP>_<映射端口>_YYYYMMDD.log` | 每日全量：启动环境信息、每次失败 `FAIL`、每 60s 汇总 `SUMMARY` |
| CLI 端 | `/var/log/tcp_monitor/` | `outage_<kind>_<user>_<映射IP>_<映射端口>.log` | 只记中断：`OUTAGE START / ONGOING / END` |
| RS 端 | `/var/log/rs_listener/` | `rs_<kind>_<user>_<RS端口>_YYYYMMDD.log` | 每日全量：连接接入 `ACCEPT`、每 60s 汇总 `SUMMARY` |

```bash
cat /var/log/tcp_monitor/outage_*.log    # CLI 端：中断记录（开始、结束时间和持续时长）
tail -f /var/log/tcp_monitor/tcp_*.log   # CLI 端：实时探测日志
tail -f /var/log/rs_listener/rs_*.log    # RS 端：监听日志
```

## 5. 判定规则

每秒探测一次，连续失败 3 次记为中断开始（`OUTAGE START`），第一次成功记为中断结束（`OUTAGE END`）。中断期间每 60 秒记一条 `OUTAGE ONGOING`，表示仍在中断。

> 完整参数和排查说明见 `README.md`。
