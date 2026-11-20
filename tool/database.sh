#!/bin/bash
getDir(){
	dir=`echo $0 | grep "^/"`
	if test "${dir}"; then	# test 变量。 dir 为空字符串("") 则为false，否则为true
		dirname $0
	else
		dirname `pwd`/$0
	fi
}
path=`getDir`
echo $path

# 中心数据库脚本
centerdata_create=$path/script/database/centerdata_create.sh
centerdata_insert=$path/script/database/centerdata_insert.sh

# 数据库脚本
gamedata=$path/script/database/game_create.sh

echo "选择题:"
select w in 重置中心数据库 重置游戏数据库
do
	case $w in
		重置中心数据库)
			sh $centerdata_create centerdata
			sh $centerdata_insert centerdata
			break
			;;
		重置游戏数据库)
			DbName=`cat ../config/main_node | grep -E '\"server[0-9]+\",?' | grep -oP '\s*dbname\s*=\s*"\Kserver[0-9]+'`
			sh $gamedata $DbName
			break
			;;
	esac
done