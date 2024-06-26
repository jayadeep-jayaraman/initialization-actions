#!/bin/bash
#  Copyright 2015 Google, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
#  This initialization action installs Ganglia, a distributed monitoring system.

set -euxo pipefail

function err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
  return 1
}

function update_apt_get() {
  for ((i = 0; i < 10; i++)); do
    if apt-get update; then
      return 0
    fi
    sleep 5
  done
  return 1
}

function setup_ganglia_host() {
  # Install dependencies needed for Ganglia host
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    rrdtool \
    gmetad \
    ganglia-webfrontend || err 'Unable to install packages'

  ln -s /etc/ganglia-webfrontend/apache.conf /etc/apache2/sites-enabled/ganglia.conf
  sed -i "s/my cluster/${master_hostname}/" /etc/ganglia/gmetad.conf
  sed -i '26s/ \$context_metrics \= \"\"\;/ \$context_metrics \= array\(\)\;/g' /usr/share/ganglia-webfrontend/cluster_view.php
  systemctl restart ganglia-monitor gmetad apache2
}

function remove_old_backports {
  # This script uses 'apt-get update' and is therefore potentially dependent on
  # backports repositories which have been archived.  In order to mitigate this
  # problem, we will remove any reference to backports repos older than oldstable

  # https://github.com/GoogleCloudDataproc/initialization-actions/issues/1157
  oldstable=$(curl -s https://deb.debian.org/debian/dists/oldstable/Release | awk '/^Codename/ {print $2}');
  stable=$(curl -s https://deb.debian.org/debian/dists/stable/Release | awk '/^Codename/ {print $2}');

  matched_files="$(grep -rsil '\-backports' /etc/apt/sources.list*)"
  if [[ -n "$matched_files" ]]; then
    for filename in "$matched_files"; do
      grep -e "$oldstable-backports" -e "$stable-backports" "$filename" || \
        sed -i -e 's/^.*-backports.*$//' "$filename"
    done
  fi
}

function main() {
  local master_hostname=$(/usr/share/google/get_metadata_value attributes/dataproc-master)
  local cluster_name=$(/usr/share/google/get_metadata_value attributes/dataproc-cluster-name)

  OS=$(. /etc/os-release && echo "${ID}")
  if [[ ${OS} == debian ]] && [[ $(echo "${DATAPROC_IMAGE_VERSION} <= 2.1" | bc -l) == 1 ]]; then
    remove_old_backports
  fi

  update_apt_get || err 'Unable to update apt-get'
  apt-get install -y ganglia-monitor

  sed -e "/send_metadata_interval = 0 /s/0/5/" -i /etc/ganglia/gmond.conf
  sed -e "/name = \"unspecified\" /s/unspecified/${cluster_name}/" -i /etc/ganglia/gmond.conf
  sed -e '/mcast_join /s/^  /  #/' -i /etc/ganglia/gmond.conf
  sed -e '/bind /s/^  /  #/' -i /etc/ganglia/gmond.conf
  sed -e "/udp_send_channel {/a\  host = ${master_hostname}" -i /etc/ganglia/gmond.conf

  if [[ "$(hostname -s)" == "${master_hostname}" ]]; then
    # Setup Ganglia host only on the master node ("0"-master in HA mode)
    setup_ganglia_host || err 'Setting up Ganglia host failed'
  else
    # Configure non-host Ganglia nodes
    sed -e "/deaf = no /s/no/yes/" -i /etc/ganglia/gmond.conf
    sed -i '/udp_recv_channel {/,/}/d' /etc/ganglia/gmond.conf
    systemctl restart ganglia-monitor
  fi
}

main
