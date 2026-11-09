#!/bin/sh
set -eu
# Named volumes start as root-owned when the image has no populated directory.
# Prepare only the mounted directories, then run RocketMQ as its image user.
mkdir -p /home/rocketmq/logs/rocketmqlogs /home/rocketmq/store
chown 3000:3000 /home/rocketmq/logs /home/rocketmq/logs/rocketmqlogs /home/rocketmq/store
exec su -m -s /bin/sh rocketmq -c 'export HOME=/home/rocketmq; export PATH="$JAVA_HOME/bin:$PATH"; exec "$@"' -- rocketmq "$@"
