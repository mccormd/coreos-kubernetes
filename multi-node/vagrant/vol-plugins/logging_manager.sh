#!/bin/bash

# Copyright 2016 David McCormick, Zopa.com
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Configuration VARS
# RUN_LOOP_DELAY seconds - the amount of time to wait before starting another run.
# VOLUME_PATH: The location of the local sparse volumes and meta-data

# Defaults
DEFAULT_PATH=/var/lib/kubelet/bounded-local

DEFAULT_LOGGING_PATH=/var/log/splunk

[[ -z "${VOLUME_PATH}" ]] && VOLUME_PATH=${DEFAULT_PATH}
[[ ! -e "${VOLUME_PATH}" ]] && mkdir -p ${VOLUME_PATH}
[[ -z "${LOGGING_PATH}" ]] && LOGGING_PATH=${DEFAULT_LOGGING_PATH}
[[ ! -e "${LOGGING_PATH}" ]] && mkdir -p ${LOGGING_PATH}

ismounted() {
        local MNTPATH=$1

        local MOUNT=`findmnt -n ${MNTPATH} 2>/dev/null | cut -d' ' -f1`
        [[ "${MOUNT}" == "${MNTPATH}" ]]
        return $?
}

while true; do
        echo "$(date +'%Y/%m/%d %H:%M:%S') Running logging manager and clean up..."
        for VOL in ${VOLUME_PATH}/*
        do
                [[ "${VOL}" =~ \*$ ]] && break

                SHORTVOL=${VOL%%/sparse-volume}
                SHORTVOL=${VOL##*/}
                MNTPATH=$(cat ${VOL}/mountpath)
                if ismounted $MNTPATH; then
                        # check for the splunk logging symlinks
                        PODPATH=${MNTPATH%%/volumes/*}
                        echo "Examining pod directories under $PODPATH"
                        NAMESPACE=""
                        PODNAME=""
                        [[ -f "${PODPATH}/volumes/kubernetes.io~downward-api/podinfo/namespace" ]] && NAMESPACE=$(cat "${PODPATH}/volumes/kubernetes.io~downward-api/podinfo/namespace")
                        [[ -f "${PODPATH}/volumes/kubernetes.io~downward-api/podinfo/podname" ]] && PODNAME=$(cat "${PODPATH}/volumes/kubernetes.io~downward-api/podinfo/podname")
                        if [[ -n "${NAMESPACE}" && -n "${PODNAME}" ]]; then
                                mkdir -p ${LOGGING_PATH}/_namespace_${NAMESPACE}
                                LINKNAME="_namespace_${NAMESPACE}/pod_${PODNAME}"
                        else
                                LINKNAME=${PODPATH##*/}
                        fi
                        [[ ! -d "$(dirname $LINKNAME)" ]] && mkdir $(dirname $LINKNAME)

                        echo "Symlink name is $LINKNAME"
                        if [[ ! -h ${LOGGING_PATH}/${LINKNAME} ]]; then
                                echo "Creating logging symlink ${LOGGING_PATH}/${LINKNAME}"
                                echo "ln -s ${MNTPATH} ${LOGGING_PATH}/${LINKNAME}"
                                #ln -s ${MNTPATH} ${LOGGING_PATH}/${LINKNAME}
                        fi
                fi
        done

        # exit loop if RUN_LOOP_DELAY not set
        [[ -z "${RUN_LOOP_DELAY}" ]] && break
        sleep ${RUN_LOOP_DELAY}
done

exit 0

