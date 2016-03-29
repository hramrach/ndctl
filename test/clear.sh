#!/bin/bash -x
DEV=""
NDCTL="./ndctl"
BUS="-b nfit_test.0"
BUS1="-b nfit_test.1"
json2var="s/[{}\",]//g; s/:/=/g"
rc=77

set -e

err() {
	echo "test/clear: failed at line $1"
	exit $rc
}

eval $(uname -r | awk -F. '{print "maj="$1 ";" "min="$2}')
if [ $maj -lt 4 ]; then
	echo "kernel $maj.$min lacks clear poison support"
	exit $rc
elif [ $maj -eq 4 -a $min -lt 6 ]; then
	echo "kernel $maj.$min lacks clear poison support"
	exit $rc
fi

set -e
trap 'err $LINENO' ERR

# setup (reset nfit_test dimms)
modprobe nfit_test
$NDCTL disable-region $BUS all
$NDCTL zero-labels $BUS all
$NDCTL enable-region $BUS all

rc=1

# create pmem
dev="x"
json=$($NDCTL create-namespace $BUS -t pmem -m raw)
eval $(echo $json | sed -e "$json2var")
[ $dev = "x" ] && echo "fail: $LINENO" && exit 1
[ $mode != "raw" ] && echo "fail: $LINENO" && exit 1

# check for expected errors in the middle of the namespace
read sector len < /sys/block/$blockdev/badblocks
[ $((sector * 2)) -ne $((size /512)) ] && echo "fail: $LINENO" && exit 1
if dd if=/dev/$blockdev of=/dev/null iflag=direct bs=512 skip=$sector count=$len; then
	echo "fail: $LINENO" && exit 1
fi

size_raw=$size
sector_raw=$sector

# convert pmem to memory mode
json=$($NDCTL create-namespace -m memory -f -e $dev)
eval $(echo $json | sed -e "$json2var")
[ $mode != "memory" ] && echo "fail: $LINENO" && exit 1

# check for errors relative to the offset injected by the pfn device
read sector len < /sys/block/$blockdev/badblocks
[ $((sector_raw - sector)) -ne $(((size_raw - size) / 512)) ] && echo "fail: $LINENO" && exit 1

# check that writing clears the errors
if ! dd of=/dev/$blockdev if=/dev/zero oflag=direct bs=512 seek=$sector count=$len; then
	echo "fail: $LINENO" && exit 1
fi

if read sector len < /sys/block/$blockdev/badblocks; then
	# fail if reading badblocks returns data
	echo "fail: $LINENO" && exit 1
fi

$NDCTL disable-region $BUS all
$NDCTL disable-region $BUS1 all
modprobe -r nfit_test

exit 0
