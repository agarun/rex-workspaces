# A fake dev server: records that it started and that Ctrl-C reached it.
name=$1 out=$2
echo "$name" >> "$out/started.log"
trap 'echo "$name" >> "$out/interrupted.log"; exit 130' INT
while :; do sleep 0.2; done
