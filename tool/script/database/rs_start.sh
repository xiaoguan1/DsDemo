#!/bin/bash

#注意：UID范围可以修改，也存在UID≥1000的系统用户，应查阅/etc/login.defs中的UID_MIN。
COMMON_UID_MIN=`awk '/^UID_MIN/ {print $2}' /etc/login.defs`
if [ "$UID" -lt $COMMON_UID_MIN ]; then
	echo "必须普通用户启动副本集"
	exit
fi

sh ./script/database/rs_init.sh

rsList=`ls ./script/database/rs_env`
rsDb=$HOME/rsDb

# ----------- 启动副本集节点进程 -----------
for rsName in $rsList; do
	mPid=`ps -ef | grep $rsName | grep -v grep | awk '{print $2}'`
	if [ -z "$mPid" ] || [ "$mPid" -lt 0 ]; then
		# 启动rsName的mongod副本集进程
		mongod -f ./script/database/rs_env/"$rsName"
		echo -e "start $rsName finish\n"
	else
		echo -e "$rsName already start, pid:$mPid\n"
	fi	
done

echo "----- replSet cluster process start run finish -----"


# 把副本集的状态信息dump进status.log文件
mongo --host localhost --port 27018 --eval "rs.status()" > $rsDb/status.log

echo "----- replSet cluster status record finish -----"
