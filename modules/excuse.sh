#!/bin/bash
#host=bofh.jeffballard.us
#port=666
#grep excuse < /dev/tcp/$host/$port | sed 's/Your excuse is: //'

sort -R excuses.txt | head -n 1
