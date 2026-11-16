#!/bin/bash

config=$1		# 进程对应的配置文件
if [ "X$config" = "X" ]; then
	echo "stop skynet fail, please input config"
	exit
fi

skynetPid=`ps -ef | grep $config | grep 'skynet' | awk '{print $2}'`
if [ "X$skynetPid" = "X" ]; then
	echo "skynet config=\"$config\" not find pid!"
	exit
fi

kill $skynetPid

while true; do
	isLive=`ps -ef | grep $config | grep 'skynet' | awk '{print $2}'`
	if [ "X$isLive" = "X" ]; then
		echo "skynet config=\"$config\" stop finish!"
		exit
	else
		echo "$isLive pid stoping"
	fi
	sleep 1
done
