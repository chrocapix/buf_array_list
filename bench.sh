#!/bin/zsh

set -euo pipefail

lo=100
hi=100_000_000
count=1000

out=$1
mkdir $out

for bs in 8 16 32 64; do
	for i in {1..11}; do
		for algo in std buf; do
			echo "$algo opt u$bs"
			zig build -Doptimize=ReleaseFast run -- $lo $hi $count -u$bs --$algo \
				>>$out/$algo.u$bs.o
			echo >>$out/$algo.u$bs.o
			wc -l $out/$algo.u$bs.o
		done
	done
	cat $out/{std,buf}.u$bs.o | sort -gs | \
		while read n t1 && read n t2; do
			echo $n $t1 $t2
		done >$out/both.u$bs.o
done

for bs in 8 16 32 64; do
	for algo in std buf; do
		echo "$algo debug u$bs"
		zig build run -- $lo $hi $count -u$bs --$algo >$out/$algo.u$bs.d
	done
	cat $out/{std,buf}.u$bs.d | sort -gs | \
		while read n t1 && read n t2; do
			echo $n $t1 $t2
		done >$out/both.u$bs.d
done
