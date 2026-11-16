#!/bin/bash
# 无缝世界节点运维脚本（M1：单节点 world_node）

getDir(){
	dir=`echo $0 | grep "^/"`
	if test "${dir}"; then
		dirname $0
	else
		dirname `pwd`/$0
	fi
}

CURDIR=`getDir`	# 当前脚本所在目录
cd $CURDIR/..

WORLD_CONFIG=./config/world_node

echo "选择题:"
select w in 启动世界 关闭世界 重启世界 一键验收
do
	case $w in
		启动世界)
			sh tool/script/start.sh $WORLD_CONFIG
			break
			;;
		关闭世界)
			sh tool/script/stop.sh $WORLD_CONFIG
			break
			;;
		重启世界)
			sh tool/script/stop.sh $WORLD_CONFIG
			sh tool/script/start.sh $WORLD_CONFIG
			break
			;;
		一键验收)
			sh tool/script/accept.sh
			break
			;;
	esac
done
