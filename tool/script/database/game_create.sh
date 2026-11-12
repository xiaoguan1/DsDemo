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
CREATE TABLE module (
	mod_name varchar(128) NOT NULL COMMENT '模块名',
	data LONGTEXT NOT NULL COMMENT '模块数据',
	PRIMARY KEY (mod_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
EOF
[ $? -eq 0 ] && echo "create table: module" || echo "exists table: module";


