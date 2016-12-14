#!/bin/bash

# get latest version of the kubectl command...
if [[ -z "${KUBERNETES_VERSION}" ]]; then
  KUBERNETES_VERSION=$(curl -s -k -L https://storage.googleapis.com/kubernetes-release/release/stable.txt)
fi

BINNAME="kubectl"
case $(uname -s) in
   Darwin)
     echo "Downloading for Mac OS X"
     CODEBASE="darwin"
     ;;
   Linux)
     echo "Downloading for Linux"
     CODEBASE="linux"	
     ;;
   CYGWIN*|MINGW32*|MSYS*)
     echo "Downloading for Windows/Cygwin"
     CODEBASE="windows"	
     BINNAME="kubectl.exe"
     ;;
   *)
     echo "Sorry! Can't detect the OS... you will need to manually download."
     exit 1 
     ;;
esac

echo "Downloading https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/${CODEBASE}/amd64/${BINNAME}" 
curl -L -k https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/${CODEBASE}/amd64/${BINNAME} >${BINNAME}
chmod a+x ${BINNAME}

# resolve windows paths or leave as is
resolve_path() {
  local PATH=$1
  case ${CODEBASE} in
    windows) echo "$(/usr/bin/cygpath -w $PATH)"
      ;;
    *) echo "$PATH"
      ;;
  esac
}

echo "Setting up kubeconfig file..."
PWD=$(pwd)

./kubectl config set-cluster my-kube-cluster --server=https://172.17.4.101 --certificate-authority="$(resolve_path ${PWD}/ssl/ca.pem)"
./kubectl config set-credentials my-kube-admin --certificate-authority="$(resolve_path ${PWD}/ssl/ca.pem)" \
  --client-key="$(resolve_path ${PWD}/ssl/admin-key.pem)" \
  --client-certificate="$(resolve_path ${PWD}/ssl/admin.pem)"
./kubectl config set-context default-kube --cluster=my-kube-cluster --user=my-kube-admin
./kubectl config use-context default-kube

echo "done"
