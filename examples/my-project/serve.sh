#!/bin/sh
name=${1:-server}
port=${2:-3000}
trap 'echo "$name: stopped"; exit 0' INT TERM
echo "$name: listening on http://localhost:$port (pretend)"
while :; do
  sleep 3
  echo "$name: $(date +%H:%M:%S) GET / 200"
done
