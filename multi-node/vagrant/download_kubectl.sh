#!/bin/bash

curl -s -L -k https://storage.googleapis.com/kubernetes-release/release/v1.4.6/bin/windows/amd64/kubectl.exe >kubectl.exe
chmod a+x kubectl.exe
