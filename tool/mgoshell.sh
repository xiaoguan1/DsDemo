#!/bin/bash

mPid=`ps -ef | grep mongodb | grep -v grep | awk '{print $2}'`

if [ "X$mPid" == "X" ]; then
	echo "请先启动 mongodb 服务"
	exit
fi

echo "mongodb pid = $mPid"

/opt/mongodb/bin/mongo --host localhost --port 27017
# 若想连接具体ip下的数据库可指定ip和端口。例如：连接jltx的数据库
# --host 192.168.0.94 --port 27017    
