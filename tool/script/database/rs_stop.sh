#!/bin/bash

#注意：UID范围可以修改，也存在UID≥1000的系统用户，应查阅/etc/login.defs中的UID_MIN。
COMMON_UID_MIN=`awk '/^UID_MIN/ {print $2}' /etc/login.defs`
if [ "$UID" -lt $COMMON_UID_MIN ]; then
	echo "必须普通用户启动副本集"
	exit
fi

# 副本集的启动配置
RS_ENV_PATH="./script/database/rs_env"
RS_ENV_FILES=`ls "$RS_ENV_PATH"`

# 副本集的数据目录
RS_DB_PATH=$HOME/rsDb

for name in $RS_ENV_FILES; do
	port=$(echo "$name" | awk -F'-' '{print $2}' | awk -F'.' '{print $1}')
	db_dir="$RS_DB_PATH"/"$port"
	pid_file="$db_dir"/data/mongod.lock

	if [ ! -f "$pid_file" ]; then
		# mongod.lock文件不存在，则直接跳过
		echo "$RS_ENV_PATH/$name not mongod.lock file!"
		continue
	fi

	db_pid=`cat "$pid_file"`
	if [ -n "$db_pid" ] && [ "$db_pid" -gt 0 ]; then
		mongod --shutdown -f "$RS_ENV_PATH/$name"
		echo -e "$RS_ENV_PATH/$name shutdown mongod $db_pid\n"
	else
		echo -e "$RS_ENV_PATH/$name already shutdown!\n"
	fi
done


echo "执行完毕"
