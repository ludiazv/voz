#!/bin/bash

scp dist/voz-Debug-arm-linux-gnueabihf.tar.gz root@172.32.0.2:/home/root/voz.tar.gz
ssh root@172.32.0.2 tar xvf /home/root/voz.tar.gz
