#!/bin/bash

getDir(){
	dir=`echo $0 | grep "^/"`
	if test "${dir}"; then	# test 变量。 dir 为空字符串("") 则为false，否则为true
		dirname $0
	else
		dirname `pwd`/$0
	fi
}

CURDIR=`getDir`	# 当前路径

DISPLAYPORT_SH=$CURDIR/script/svcinfo/display_port.sh

GAME_CONFIG=config/main_node
CROSS_CONFIG=config/cross_node

echo "选择题:"
select w in 展示游戏服占用端口 展示跨服占用端口 展示游戏服cpu使用率
do
	case $w in
		展示游戏服占用端口)
			sh $DISPLAYPORT_SH $GAME_CONFIG
			break
			;;
		展示跨服占用端口)
			sh $DISPLAYPORT_SH $CROSS_CONFIG
			break
			;;
	esac
done



