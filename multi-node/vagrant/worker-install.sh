#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# The endpoint the worker node should use to contact controller nodes (https://ip:port)
# In HA configurations this should be an external DNS record or loadbalancer in front of the control nodes.
# However, it is also possible to point directly to a single control node.
export CONTROLLER_ENDPOINT=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.4.6_coreos.0

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube

# The IP address of the cluster DNS service.
# This must be the same DNS_SERVICE_IP used when configuring the controller nodes.
export DNS_SERVICE_IP=10.3.0.10

# Whether to use Calico for Kubernetes network policy.
export USE_CALICO=false

# Determines the container runtime for kubernetes to use. Accepts 'docker' or 'rkt'.
export CONTAINER_RUNTIME=docker

# Determine the version of CNI to install
export CNI_VER="v0.3.0"

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

# -------------

function init_config {
    local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO' 'USE_CALICO' )

    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function download_kubelet {
    local K8S_VER=${1%%_*}
    local CNI_VER=$2

    echo "Downloading kubelet..."
    mkdir -p /opt/bin
    mkdir -p /opt/cni/bin
    curl -s -L -k -o /opt/bin/kubelet "https://storage.googleapis.com/kubernetes-release/release/${K8S_VER}/bin/linux/amd64/kubelet"
    chmod +x /opt/bin/kubelet
    ls -al /opt/bin
    echo "Downloading cni...."
    curl -L -k "https://github.com/containernetworking/cni/releases/download/${CNI_VER}/cni-${CNI_VER}.txz"| xz -d | tar xvf - -C /opt/cni/bin/
}

function init_templates {
    local TEMPLATE=/etc/systemd/system/kubelet.service
    local uuid_file="/var/run/kubelet-pod.uuid"
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/vol-plugins
ExecStartPre=/usr/bin/mkdir -p /var/log/containers
ExecStartPre=/usr/bin/mkdir -p /var/lib/kubelet
ExecStartPre=/usr/bin/mkdir -p /run/kubelet
ExecStart=/opt/bin/kubelet \
        --hostname-override=${ADVERTISE_IP} \
        --cni-conf-dir=/etc/kubernetes/cni/net.d \
        --network-plugin=cni \
        --register-node=true \
        --allow-privileged=true \
        --pod-manifest-path=/etc/kubernetes/manifests \
        --cluster-dns=${DNS_SERVICE_IP} \
        --cluster-domain=cluster.local \
        --require-kubeconfig=true \
        --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
        --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
        --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
	--volume-plugin-dir=/etc/kubernetes/vol-plugins
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    fi

    local TEMPLATE=/etc/systemd/system/splunk-forwarder.service
    if [ ! -f $TEMPLATE ]; then
	echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Splunk Universal Forwarder (running in RKT FLY container)

[Service]
Slice=machine.slice
Restart=always
RestartSec=10s
LimitNOFILE=40000
LimitNPROC=1048576

ExecStartPre=/usr/bin/mkdir --parents /var/log-collection /opt/splunk/etc /opt/splunk/var
ExecStartPre=-/usr/bin/rkt rm --uuid-file=/var/lib/coreos/splunk-forwarder.uuid
ExecStart=/usr/bin/rkt run \
	--stage1-from-dir=stage1-fly.aci \
	--uuid-file-save=/var/lib/coreos/splunk-forwarder.uuid \
	--insecure-options=image docker://splunk/universalforwarder:latest \
	--environment=SPLUNK_START_ARGS="--accept-license --answer-yes" \
	--environment=SPLUNK_USER="root" \
	--environment=SPLUNK_FORWARD_SERVER_ARGS="10.3.0.136:9997" \
	--volume volume-opt-splunk-etc,kind=host,source=/opt/splunk/etc \
	--volume volume-opt-splunk-var,kind=host,source=/opt/splunk/var \
	--volume applogs,kind=host,source=/var/log-collection \
	--mount volume=applogs,target=/applogs \
	--exec="/bin/bash" -- -c "env; ls -al /sbin/entrypoint.sh;chmod +x /sbin/entrypoint.sh;ls -al /sbin/entrypoint.sh; /sbin/entrypoint.sh start-service"
ExecStop=-/usr/bin/rkt stop --uuid-file=/var/lib/coreos/splunk-forwarder.uuid

[Install]
WantedBy=multi-user.target
EOF
    fi

    local TEMPLATE=/etc/systemd/system/calico-node.service
    if [ "${USE_CALICO}" = "true" ] && [ ! -f "${TEMPLATE}" ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Calico per-host agent
Requires=network-online.target
After=network-online.target

[Service]
Slice=machine.slice
Environment=CALICO_DISABLE_FILE_LOGGING=true
Environment=HOSTNAME=${ADVERTISE_IP}
Environment=IP=${ADVERTISE_IP}
Environment=FELIX_FELIXHOSTNAME=${ADVERTISE_IP}
Environment=CALICO_NETWORKING=false
Environment=NO_DEFAULT_POOLS=true
Environment=ETCD_ENDPOINTS=${ETCD_ENDPOINTS}
ExecStart=/usr/bin/rkt run --inherit-env --stage1-from-dir=stage1-fly.aci \
--volume=modules,kind=host,source=/lib/modules,readOnly=false \
--mount=volume=modules,target=/lib/modules \
--volume=dns,kind=host,source=/etc/resolv.conf,readOnly=true \
--mount=volume=dns,target=/etc/resolv.conf \
--trust-keys-from-https quay.io/calico/node:v0.19.0
KillMode=mixed
Restart=always
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    fi

    local TEMPLATE=/etc/kubernetes/worker-kubeconfig.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    server: ${CONTROLLER_ENDPOINT}
    certificate-authority: /etc/kubernetes/ssl/ca.pem
users:
- name: kubelet
  user:
    client-certificate: /etc/kubernetes/ssl/worker.pem
    client-key: /etc/kubernetes/ssl/worker-key.pem
contexts:
- context:
    cluster: local
    user: kubelet
  name: kubelet-context
current-context: kubelet-context
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
  annotations:
    rkt.alpha.kubernetes.io/stage1-name-override: coreos.com/rkt/stage1-fly
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - proxy
    - --master=${CONTROLLER_ENDPOINT}
    - --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: "ssl-certs"
    - mountPath: /etc/kubernetes/worker-kubeconfig.yaml
      name: "kubeconfig"
      readOnly: true
    - mountPath: /etc/kubernetes/ssl
      name: "etc-kube-ssl"
      readOnly: true
    - mountPath: /var/run/dbus
      name: dbus
      readOnly: false
  volumes:
  - name: "ssl-certs"
    hostPath:
      path: "/usr/share/ca-certificates"
  - name: "kubeconfig"
    hostPath:
      path: "/etc/kubernetes/worker-kubeconfig.yaml"
  - name: "etc-kube-ssl"
    hostPath:
      path: "/etc/kubernetes/ssl"
  - hostPath:
      path: /var/run/dbus
    name: dbus
EOF
    fi

    local TEMPLATE=/etc/flannel/options.env
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
FLANNELD_IFACE=$ADVERTISE_IP
FLANNELD_ETCD_ENDPOINTS=$ETCD_ENDPOINTS
EOF
    fi

    local TEMPLATE=/etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf.conf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF
    fi

    local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
[Service]
EnvironmentFile=/etc/kubernetes/cni/docker_opts_cni.env
EOF
    fi

    local TEMPLATE=/etc/kubernetes/cni/docker_opts_cni.env
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
DOCKER_OPT_BIP=""
DOCKER_OPT_IPMASQ=""
EOF
    fi

    local TEMPLATE=/etc/kubernetes/cni/net.d/10-calico.conf
    if [ "${USE_CALICO}" = "true" ] && [ ! -f "${TEMPLATE}" ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
    "name": "calico",
    "type": "flannel",
    "delegate": {
        "type": "calico",
        "etcd_endpoints": "$ETCD_ENDPOINTS",
        "log_level": "none",
        "log_level_stderr": "info",
        "hostname": "${ADVERTISE_IP}",
        "policy": {
            "type": "k8s",
            "k8s_api_root": "${CONTROLLER_ENDPOINT}:443/api/v1/",
            "k8s_client_key": "/etc/kubernetes/ssl/worker-key.pem",
            "k8s_client_certificate": "/etc/kubernetes/ssl/worker.pem"
        }
    }
}
EOF
    fi

    local TEMPLATE=/etc/kubernetes/cni/net.d/10-flannel.conf
    if [ "${USE_CALICO}" = "false" ] && [ ! -f "${TEMPLATE}" ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
    "name": "podnet",
    "type": "flannel",
    "delegate": {
        "isDefaultGateway": true
    }
}
EOF
    fi

}

init_config
download_kubelet ${K8S_VER} ${CNI_VER}
init_templates

systemctl stop update-engine; systemctl mask update-engine

systemctl daemon-reload

if [ $CONTAINER_RUNTIME = "rkt" ]; then
        systemctl enable load-rkt-stage1
        systemctl enable rkt-api
fi

systemctl enable flanneld; systemctl start flanneld
systemctl enable kubelet; systemctl start kubelet
systemctl enable splunk-forwarder; systemctl start splunk-forwarder

if [ $USE_CALICO = "true" ]; then
        systemctl enable calico-node; systemctl start calico-node
fi

