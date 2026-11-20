#!/bin/bash

config=$1
if [ "X$config" = "X" ]; then
	echo "please input config"
	exit
fi

skynetPid=`ps -ef | grep $config | grep 'skynet' | awk '{print $2}'`
if [ "X$skynetPid" = "X" ]; then
	echo "skynet config=\"$config\" not find pid"
	exit
fi

echo "skynet config=\"$config\" occupying port:"
lsof -Pan -i -a -p $skynetPid | awk 'NR>1 {printf "PID: %-8s 协议: %-5s 端口: %-10s 状态: %-12s\n", $2, $8, $9, $10}'
