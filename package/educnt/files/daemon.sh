#!/bin/sh
# educnt 后台调度器
#
# - 每 30 分钟执行一次 educnt check（仅对掉线线路补登录）
# - check 失败（例如刚开机 WAN 还没拿到 IPv4）后 1 分钟重试，最多 5 次
# - 每天 04:30 ~ 04:59 之间执行一次 educnt reauth（逐条注销 + 重登 + 确认在线）
#
# 由 /etc/init.d/educnt 通过 procd 拉起，异常退出会被自动重启。

LAST_REAUTH=""
COUNT=0
CHECK_INTERVAL=30
CHECK_RETRY=0

while true; do
	TODAY=$(date +%Y-%m-%d)
	HM=$(date +%H:%M)

	case "$HM" in
	04:3[0-9]|04:4[0-9]|04:5[0-9])
		if [ "$LAST_REAUTH" != "$TODAY" ]; then
			/usr/bin/educnt reauth
			LAST_REAUTH=$TODAY
			COUNT=0
			CHECK_RETRY=0
		fi
		;;
	esac

	if [ $((COUNT % CHECK_INTERVAL)) -eq 0 ]; then
		/usr/bin/educnt check
		if [ $? -ne 0 ] && [ "$CHECK_RETRY" -lt 5 ]; then
			# 刚开机时 WAN 可能还没拿到 IPv4，失败后 1 分钟重试，最多 5 次
			CHECK_RETRY=$((CHECK_RETRY + 1))
			COUNT=$((CHECK_INTERVAL - 1))
		else
			CHECK_RETRY=0
		fi
	fi

	COUNT=$((COUNT + 1))
	sleep 60
done
