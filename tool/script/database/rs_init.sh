#!/bin/bash

### 1.尝试初始化副本集的db目录
###	2.尝试初始化管理副本集日志的crontab和logrotate
### 3.尝试初始化域名/etc/hosts

# 注意：UID范围可以修改，也存在UID≥1000的系统用户，应查阅/etc/login.defs中的UID_MIN。
COMMON_UID_MIN=`awk '/^UID_MIN/ {print $2}' /etc/login.defs`
if [ "$UID" -lt $COMMON_UID_MIN ]; then
	echo "必须以普通用户身份初始化副本集的日志管理设置"
	exit
fi

userName=`whoami`
userGroup=`groups $userName | awk '{print $3}'`

RsEnvs=`ls ./script/database/rs_env`
RsDbDir=$HOME/rsDb

logRotDir=$HOME/rsLogrot
logRotFile=$logRotDir/$userName
logRotStatus=$logRotDir/logrotate.status

# ----------- 尝试副本集节点进程的数据文件夹 -----------
if [ ! -d $RsDbDir ]; then
	mkdir $RsDbDir
fi

if [ ! -d $logRotDir ]; then
	mkdir $logRotDir
fi

if [ ! -f $logRotStatus ]; then
	touch $logRotStatus
fi

if [ ! -f $logRotFile ]; then
	touch $logRotFile && chmod 644 $logRotFile	# 创建并设置权限

	# 插入内容
	cat > $logRotFile <<EOF
$RsDbDir/*/mongod.log {
	daily
	maxsize 1M
	rotate 7
	compress
	delaycompress
	missingok
	notifempty
	create 640 $userName $userGroup
	postrotate
		# 获取当前日志文件的端口号（从路径中提取）
		port=\$(basename "\$(dirname "\$1")")

		# 发送 logRotate 命令到对应端口的实例。此外 mongodb 的版本不同 mongo 和 mongosh 的支持也不同
		mongoshPath=`which mongosh >/dev/null 2>&1 && which mongosh || echo ""`
		mongoPath=`which mongo >/dev/null 2>&1 && which mongo || echo ""`
		if command -v "\$mongoshPath" >/dev/null 2>&1; then
			"\$mongoshPath" --quiet --eval "db.adminCommand({ logRotate: 1 })" 127.0.0.1:\$port/admin 2>/dev/null || echo "mongosh failed for port \$port" >> $logRotDir/logrotate_errors.log
		elif command -v "\$mongoPath" >/dev/null 2>&1; then
			"\$mongoPath" --quiet --eval "db.adminCommand({ logRotate: 1 })" 127.0.0.1:\$port/admin 2>/dev/null || echo "mongo failed for port \$port" >> $logRotDir/logrotate_errors.log
		else
			echo "No MongoDB client for port \$port" >> $logRotDir/logrotate_errors.log
		fi
	endscript
}
EOF

	echo "create $logRotFile finish!"
fi

for rsName in $RsEnvs; do
	port=$(echo "$rsName" | awk -F'-' '{print $2}' | awk -F '.' '{print $1}')
	portDir="$RsDbDir"/"$port"
	if [ ! -d $portDir ]; then
		mkdir $portDir
	fi
	if [ ! -d $portDir/data ]; then
		mkdir $portDir/data
	fi
done

userCron=$(crontab -l 2>/dev/null)   # 当前用户的所有crontab信息，（ 2>/dev/null 忽略错误信息）
# echo "$userCron"		# 必须携带双引号

logrotCmd="/usr/sbin/logrotate -s $logRotStatus -v $logRotFile"
cronCmd="0 2 * * * "$logrotCmd" > /dev/null 2>> $logRotDir/logrotate_errors.log"  # 放弃正常输出，而错误输出则重定向到log文件中

# 检测当前用户是否存在日志管理任务
isExist=$(echo "$userCron" | grep "$logrotCmd")

if [ -z "$isExist" ]; then
	# 在crontab中未找到相关的定时任务，需要插入!!!
	logRotTemp=$logRotDir/"$userName"_temp

	echo "$userCron" > "$logRotTemp"
	echo "$cronCmd" >> $logRotTemp
	crontab $logRotTemp

	rm -f $logRotTemp
	echo "finish init crontab logrotate cmd!!!"
fi

## ------- 初始化/etc/hosts
hostsFile=/etc/hosts
ipAddr=`hostname -I`
echo `cat $hostsFile | grep "$ipAddr" | grep `