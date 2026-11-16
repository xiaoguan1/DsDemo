#!/bin/bash
# 无缝世界节点启动脚本（Linux）
# 用法:
#   sh tool/script/start_world.sh           # 后台常规起服（监听 ws://0.0.0.0:30001）
#   sh tool/script/start_world.sh console   # 前台起服（Ctrl+C 停止，便于实时看日志）

getDir(){
	dir=`echo $0 | grep "^/"`
	if test "${dir}"; then
		dirname $0
	else
		dirname `pwd`/$0
	fi
}

CURDIR=`getDir`
cd $CURDIR/../..

WORLD_CONFIG=./config/world_node

if [ "X$1" = "Xconsole" ]; then
	echo "前台启动（Ctrl+C 停止）..."
	./skynet/skynet $WORLD_CONFIG
	exit
fi

sh tool/script/start.sh $WORLD_CONFIG
echo "起服完成。停止: sh tool/script/stop.sh ./config/world_node"
echo "一键验收: sh tool/script/accept.sh"
