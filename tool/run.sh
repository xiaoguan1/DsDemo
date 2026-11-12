#!/bin/bash

#注意：UID范围可以修改，也存在UID≥1000的系统用户，应查阅/etc/login.defs中的UID_MIN。
COMMON_UID_MIN=`awk '/^UID_MIN/ {print $2}' /etc/login.defs`
if [ "$UID" -lt $COMMON_UID_MIN ]; then
	echo "必须普通用户启动引擎"
	exit
fi

getDir(){
	dir=`echo $0 | grep "^/"`
	if test "${dir}"; then	# test 变量。 dir 为空字符串("") 则为false，否则为true
		dirname $0
	else
		dirname `pwd`/$0
	fi
}

CURDIR=`getDir`	# 当前路径

# 默认编译lua的路径
LUADIR=$CURDIR/../skynet/3rd/lua

# 默认编译skynet引擎的路径
SKYNETDIR=$CURDIR/../skynet/

# 一般来说是 /home/game/ShareDemo/GameDemo/tool/.
cd $CURDIR/..

# lua ./charvar/agent/var_name.lua
# lua ./charvar/gameserver/var_name.lua
# lua ./charvar/activity/var_name.lua

START_SH=$CURDIR/script/start.sh
STOP_SH=$CURDIR/script/stop.sh
HOTUPDATE_SH=$CURDIR/script/hot_update.sh

GAME_CONFIG=./config/main_node	# 游戏服启动配置


echo "选择题:"
select w in 重启游戏服 启动游戏服 关闭游戏服 热更游戏服 启动跨服 编译并启动游戏 编译协议
do
	case $w in
		启动游戏服)
			sh $START_SH $GAME_CONFIG
			break
			;;
		关闭游戏服)
			sh $STOP_SH $GAME_CONFIG
			break
			;;
		启动跨服)
			./skynet/skynet ./config/cross_node &
			break
			;;
		重启游戏服)
			sh $STOP_SH $GAME_CONFIG
			sh $START_SH $GAME_CONFIG
			break
			;;
		热更游戏服)
			sh $HOTUPDATE_SH $GAME_CONFIG
			break
			;;
		编译并启动游戏)
			# cd $LUADIR
			# make linux		# 编译lua

			# cd $SKYNETDIR
			# make linux		# 编译skynet

			# cd $RUNDIR/..
			# ./skynet/skynet ./etc/main_node
			break
			;;
		编译协议)
			sh $CURDIR/script/gen_proto.sh
			break
			;;
	esac
done
