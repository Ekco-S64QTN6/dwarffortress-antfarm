#!/bin/sh
cd "$(dirname "$0")/soundsense-rs"
exec ./soundsense-rs --gamelog ../../game/gamelog.txt
