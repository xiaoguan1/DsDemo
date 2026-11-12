#! /bin/bash

getDir(){
	dir=`echo $0 | grep "^/"`
	if test "${dir}"; then	# test 变量。 dir 为空字符串("") 则为false，否则为true
		dirname $0
	else
		dirname `pwd`/$0
	fi
}

RUNDIR=`getDir`	# 当前路径

LUA=$RUNDIR/../../skynet/3rd/lua/lua # lua
GENPROTO=$RUNDIR/../../protocol/gen_proto.lua # 编译协议文件的逻辑代码

$LUA $GENPROTO

# echo $RUNDIR
# echo $LUA
# echo $GENPROTO