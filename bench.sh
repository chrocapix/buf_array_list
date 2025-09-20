#!/bin/zsh

set -euo pipefail

lo=100
hi=100_000_000
count=100

host=$1
dir=/tmp/bench$$
mkdir dat/$2

ssh $1 mkdir -p $dir
scp zig-out/bin/buf_array_list $host:$dir

for bs in 8 16 32 64; do
	for algo in std buf; do
		echo "$algo u$bs"
		# ssh $host $dir/buf_array_list $lo $hi $count -u$bs --$algo >dat/$2/$algo[1]$bs
		if [[ $host == localhost ]] then
			ssh $host taskpolicy -b $dir/buf_array_list $lo $hi $count -u$bs --$algo >dat/$2/$algo[1]$bs
		else
			ssh $host taskset -c 0 $dir/buf_array_list $lo $hi $count -u$bs --$algo >dat/$2/$algo[1]$bs
		fi
		# scp $host:$dir/$algo[1]$bs dat/$2
	done
	sort -sg dat/$2/{s,b}$bs | while read n s && read n b; do
		echo $n $s $b
	done >dat/$2/sb$bs
done


