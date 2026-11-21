#!/bin/bash

dbname=$1

if [ "X$dbname" = "X" ]; then
    echo "input dbname"
    exit;
fi

############################ insert into table ############################
mysql -hlocalhost -uroot -proot $dbname << EOF 2>/dev/null
insert into server_config(cluster_no, server_id, node_name, ipport, is_start_example) values
(1, 1,     'user', '127.0.0.1:32526', 0),
(1, 55001, 'play', '127.0.0.1:32527', 1),
(1, 55002, 'play', '127.0.0.1:32528', 1),
(1, 55003, 'play', '127.0.0.1:32529', 1);
EOF
[ $? -eq 0 ] && echo "insert table: server_config ok" || echo "insert table: server_config error";
