#!/bin/bash

config=$1		# 进程pid的配置文件
if [ "X$config" = "X" ]; then
	echo "hot update fail, please input config"
	exit
fi

McsPort=`cat $config | grep "mcs_port" | awk '{print $3}' | tr -d '\r\n'`
if [ "X$McsPort" = "X" ]; then
	echo "$config not find mcs_port!"
	exit
fi

skynetPid=`ps -ef | grep $config | grep 'skynet' | awk '{print $2}'`
if [ "X$skynetPid" = "X" ]; then
	echo "skynet config=\"$config\" not find pid!"
	exit
fi

# echo $config $McsPort $skynetPid
wget -q -O - "http://127.0.0.1:$McsPort/hot_update"


