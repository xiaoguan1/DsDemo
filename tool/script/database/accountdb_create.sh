#!/bin/bash

dbname=$1

if [ "X$dbname" = "X" ]; then
	echo "input dbname"
	exit
fi

######################create db######################
mysql -hlocalhost -uroot -proot << EOF 2>/dev/null
DROP DATABASE if exists $dbname;
CREATE DATABASE $dbname default charset utf8mb4 COLLATE utf8mb4_general_ci;
EOF
[ $? -eq 0 ] && echo "create database: $dbname" || echo "exists database: $dbname";

######################create table######################
mysql -hlocalhost -uroot -proot $dbname << EOF 2>/dev/null
CREATE TABLE account (
	uid varchar(32) NOT NULL COMMENT '玩家uid（jlogin new_uid 生成，16字符）',
	phone varchar(32) NOT NULL COMMENT '手机号（唯一对应uid）',
	server_id int(11) NOT NULL COMMENT '创角时分配的user节点id',
	create_time int(11) NOT NULL COMMENT '创角时间',
	PRIMARY KEY (uid),
	UNIQUE KEY uk_phone (phone)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='账号表';
EOF
[ $? -eq 0 ] && echo "create table: account ok" || echo "exists table: account";
