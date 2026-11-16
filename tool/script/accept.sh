#!/bin/bash
# 无缝世界 M1 一键验收脚本（Linux）
# 用法: sh tool/script/accept.sh [实体数] [帧数] [步幅]
#   缺省: 500 实体 / 100 帧 / 步幅 10
#   验收标准: 帧均耗时 < 20ms
# 退出码: 0 = 验收通过, 1 = 验收失败

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

N=${1:-500}
FRAMES=${2:-100}
STEP=${3:-10}
TMP_CONFIG=./config/world_node_accept
TMP_LOG=./log/accept.log

# 防重复起服（含上次验收残留实例）
if [ -n "`ps -ef | grep 'skynet' | grep 'config/world_node' | grep -v grep | awk '{print $2}'`" ]; then
	echo "已有 world_node 实例在运行，请先停止: sh tool/script/stop.sh ./config/world_node"
	exit 1
fi

# 生成验收配置：打开 perf_auto 并覆盖压测参数
sed -e "s/perf_auto = false/perf_auto = true/" \
	-e "s/perf_n = [0-9]*/perf_n = $N/" \
	-e "s/perf_frames = [0-9]*/perf_frames = $FRAMES/" \
	-e "s/perf_step = [0-9]*/perf_step = $STEP/" \
	./config/world_node > $TMP_CONFIG

mkdir -p ./log

echo "开始 M1 验收: 实体数=$N 帧数=$FRAMES 步幅=$STEP"
echo "起服中..."

# stdbuf 强制行缓冲，保证报告实时落盘（skynet 前台运行）
stdbuf -oL -eL ./skynet/skynet $TMP_CONFIG > $TMP_LOG 2>&1 &
SKYNET_PID=$!

# 最多等 120 秒出报告
REPORTED=0
for i in $(seq 1 120); do
	if grep -q "验收(帧均<20ms)" $TMP_LOG 2>/dev/null; then
		REPORTED=1
		break
	fi
	sleep 1
done

# 打印压测报告段
sed -n '/=== perf report ===/,/验收/p' $TMP_LOG

kill $SKYNET_PID 2>/dev/null
rm -f $TMP_CONFIG

if [ $REPORTED -eq 0 ]; then
	echo "ACCEPT FAIL: 120 秒内未产出压测报告，请查看 log/accept.log"
	exit 1
fi

if grep -q "验收(帧均<20ms): PASS" $TMP_LOG; then
	echo "ACCEPT PASS"
	exit 0
else
	echo "ACCEPT FAIL: 帧均耗时 >= 20ms"
	exit 1
fi
