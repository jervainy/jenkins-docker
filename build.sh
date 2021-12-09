#!/bin/sh

docker build --build-arg NODEJS_URL=https://nodejs.org/dist/v16.13.1/node-v16.13.1-linux-arm64.tar.xz \
            --build-arg TARGETARCH=amd64 \
             -t jenkins:tag .
