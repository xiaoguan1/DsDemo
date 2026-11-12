#!/bin/bash

config=$1		# 进程pid的配置文件
if [ "X$config" = "X" ]; then
	echo "stop skynet fail, please input config"
	exit
fi

skynetPid=`ps -ef | grep $config | grep 'skynet' | awk '{print $2}'`
if [ "X$skynetPid" != "X" ]; then
	echo "skynet config=\"$config\" already start started! pid:$skynetPid"
	exit
fi

./skynet/skynet $config &






