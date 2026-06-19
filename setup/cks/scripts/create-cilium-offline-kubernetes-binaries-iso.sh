#!/bin/bash -x
# CKS Custom ISO Builder — Cilium (Offline Mode)
#
# Forked from: https://github.com/nulcell/homecloud/blob/3f5a40a3332084a4ff7bd5ae13fc3c70dce28d96/cloudstack/compute/cks/create-cilium-kubernetes-binaries-iso.sh
# License: Apache License, Version 2.0 (see original source)
#
# Key difference from the standard Cilium script:
#   All image digest pins (@sha256:...) are stripped from generated YAML manifests.
#   This allows fully offline deployment where Kubernetes cannot reach external
#   registries to verify digests against bundled image tarballs.
#
# Usage:
#   ./create-cilium-offline-kubernetes-binaries-iso.sh \
#     OUTPUT_PATH KUBERNETES_VERSION CNI_VERSION CRICTL_VERSION \
#     CILIUM_VERSION DASHBOARD_YAML_CONFIG BUILD_NAME [ARCH] [ETCD_VERSION]
#
# Example:
#   ./create-cilium-offline-kubernetes-binaries-iso.sh \
#     /tmp/ 1.34.2 1.8.0 1.34.0 1.18.2 \
#     https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml \
#     cks-v1.34.2-cilium-offline x86_64 3.5.0
#
# Note: The DASHBOARD_YAML_CONFIG parameter requires a full URL to the dashboard YAML file.
# It is NOT a version number — the script does not construct the URL from a version.
# Use the raw GitHub URL of the desired dashboard release, e.g.:
#   https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

set -e

if [ $# -lt 7 ]; then
    echo "Invalid input. Valid usage: ./create-cilium-offline-kubernetes-binaries-iso.sh OUTPUT_PATH KUBERNETES_VERSION CNI_VERSION CRICTL_VERSION CILIUM_VERSION DASHBOARD_YAML_CONFIG BUILD_NAME [ARCH] [ETCD_VERSION]"
    echo "eg: ./create-cilium-offline-kubernetes-binaries-iso.sh /tmp/ 1.34.2 1.8.0 1.34.0 1.18.2 https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml cks-v1.34.2-cilium-offline x86_64 3.5.0"
    echo "Note: DASHBOARD_YAML_CONFIG must be a full URL to the dashboard YAML file, not a version number."
    exit 1
fi

ARCH="amd64"
ARCH_SUFFIX="x86_64"
if [ -n "${8}" ]; then
  if [ "${8}" = "x86_64" ] || [ "${8}" = "amd64" ]; then
    ARCH="amd64"
    ARCH_SUFFIX="x86_64"
  elif [ "${8}" = "aarch64" ] || [ "${8}" = "arm64" ]; then
    ARCH="arm64"
    ARCH_SUFFIX="aarch64"
  else
    echo "ERROR: ARCH must be 'x86_64' or 'aarch64'. If the optional parameter ARCH is not set then 'x86_64' is used."
    exit 1
  fi
fi

RELEASE="v${2}"
VAL="1.18.0"
output_dir="${1}"
start_dir="$PWD"
iso_dir="/tmp/iso"
working_dir="${iso_dir}/"
mkdir -p "${working_dir}"
build_name="${7}-${ARCH_SUFFIX}.iso"
[ -z "${build_name}" ] && build_name="setup-${RELEASE}-${ARCH_SUFFIX}.iso"

# --- CNI Plugins ---
CNI_VERSION="v${3}"
echo "Downloading CNI ${CNI_VERSION}..."
cni_dir="${working_dir}/cni/"
mkdir -p "${cni_dir}"
cni_status_code=$(curl -L --write-out "%{http_code}\n" "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" -o "${cni_dir}/cni-plugins-${ARCH}.tgz")
if [[ ${cni_status_code} -eq 404 ]] ; then
  curl -L --write-out "%{http_code}\n" "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" -o "${cni_dir}/cni-plugins-${ARCH}.tgz"
fi

# --- CRI Tools ---
CRICTL_VERSION="v${4}"
echo "Downloading CRI tools ${CRICTL_VERSION}..."
crictl_dir="${working_dir}/cri-tools/"
mkdir -p "${crictl_dir}"
curl -L "https://github.com/kubernetes-incubator/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" -o "${crictl_dir}/crictl-linux-${ARCH}.tar.gz"

# --- Kubernetes Binaries ---
echo "Downloading Kubernetes tools ${RELEASE}..."
k8s_dir="${working_dir}/k8s"
mkdir -p "${k8s_dir}"
cd "${k8s_dir}"
curl -L --remote-name-all https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/{kubeadm,kubelet,kubectl}
kubeadm_file_permissions=`stat --format '%a' kubeadm`
chmod +x kubeadm

echo "Downloading kubelet.service ${RELEASE}..."
cd "${start_dir}"
kubelet_service_file="${working_dir}/kubelet.service"
touch "${kubelet_service_file}"
if [[ `echo "${2} $VAL" | awk '{print ($1 < $2)}'` == 1 ]]; then
  curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/kubelet.service" | sed "s:/usr/bin:/opt/bin:g" > ${kubelet_service_file}
else
  curl -sSL "https://raw.githubusercontent.com/shapeblue/cloudstack-nonoss/main/cks/kubelet.service" | sed "s:/usr/bin:/opt/bin:g" > ${kubelet_service_file}
fi

echo "Downloading 10-kubeadm.conf ${RELEASE}..."
kubeadm_conf_file="${working_dir}/10-kubeadm.conf"
touch "${kubeadm_conf_file}"
if [[ `echo "${2} $val" | awk '{print ($1 < $2)}'` == 1 ]]; then
  curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/10-kubeadm.conf" | sed "s:/usr/bin:/opt/bin:g" > ${kubeadm_conf_file}
else
  curl -sSL "https://raw.githubusercontent.com/shapeblue/cloudstack-nonoss/main/cks/10-kubeadm.conf" | sed "s:/usr/bin:/opt/bin:g" > ${kubeadm_conf_file}
fi

# --- Cilium CNI (via Helm) ---
CILIUM_VERSION="${5}"
echo "Generating Cilium manifests v${CILIUM_VERSION}..."
network_conf_file="${working_dir}/network.yaml"
helm repo add cilium https://helm.cilium.io/
helm template cilium cilium/cilium --version ${CILIUM_VERSION} \
  --namespace kube-system > ${network_conf_file} \
  --set kubeProxyReplacement=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# --- Kubernetes Dashboard ---
echo "Downloading dashboard..."
dashboard_conf_file="${working_dir}/dashboard.yaml"
curl -sSL "${6}" -o ${dashboard_conf_file}

# --- Cluster Autoscaler ---
AUTOSCALER_URL="https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/cloudstack/examples/cluster-autoscaler-standard.yaml"
echo "Downloading kubernetes cluster autoscaler ${AUTOSCALER_URL}"
autoscaler_conf_file="${working_dir}/autoscaler.yaml"
curl -sSL ${AUTOSCALER_URL} -o ${autoscaler_conf_file}

# --- CloudStack CCM (Cloud Provider) ---
PROVIDER_URL="https://raw.githubusercontent.com/apache/cloudstack-kubernetes-provider/main/deployment.yaml"
echo "Downloading kubernetes cloud provider ${PROVIDER_URL}"
provider_conf_file="${working_dir}/provider.yaml"
curl -sSL ${PROVIDER_URL} -o ${provider_conf_file}

# --- CloudStack CSI Driver ---
csi_conf_file="${working_dir}/manifest.yaml"
echo "Including CloudStack CSI Driver manifest"
wget https://github.com/cloudstack/cloudstack-csi-driver/releases/download/v3.0.0/snapshot-crds.yaml -O ${working_dir}/snapshot-crds.yaml
wget https://github.com/cloudstack/cloudstack-csi-driver/releases/download/v3.0.0/manifest.yaml -O ${csi_conf_file}

# ============================================================================
# Offline Fix: Strip digest pins from all YAML manifests
#
# Helm-generated Cilium manifests use image@sha256:... references.
# The bundled tarballs don't carry digest metadata in containerd,
# so Kubernetes cannot verify digests against external registries offline.
# Removing the @sha256:... suffix leaves tag-based refs that match
# what's already bundled in the ISO.
# ============================================================================
echo "Stripping image digest pins for offline compatibility..."
sed -i 's/@sha256:[a-f0-9]*//g' ${working_dir}/*.yaml

# --- Fetch Container Images ---
echo "Fetching k8s docker images..."
ctr -v
if [ $? -ne 0 ]; then
    echo "Installing containerd..."
    if [ -f /etc/redhat-release ]; then
      sudo yum -y remove docker-common docker container-selinux docker-selinux docker-engine
      sudo yum -y install lvm2 device-mapper device-mapper-persistent-data device-mapper-event device-mapper-libs device-mapper-event-libs
      sudo yum install -y http://mirror.centos.org/centos/7/extras/x86_64/Packages/container-selinux-2.107-3.el7.noarch.rpm
      sudo yum install -y containerd.io
    elif [ -f /etc/lsb-release ]; then
      sudo apt update && sudo apt install containerd.io -y
    fi
    sudo systemctl enable containerd && sudo systemctl start containerd
fi
mkdir -p "${working_dir}/docker"
output=`${k8s_dir}/kubeadm config images list --kubernetes-version=${RELEASE}`

# Don't forget about the yaml images !
for i in ${network_conf_file} ${dashboard_conf_file}
do
  images=`grep "image:" $i | cut -d ':' -f2- | tr -d ' ' | tr -d "'"`
  output=`printf "%s\n" ${output} ${images}`
done

# Don't forget about the other image !
autoscaler_image=`grep "image:" ${autoscaler_conf_file} | cut -d ':' -f2- | tr -d ' '`
output=`printf "%s\n" ${output} ${autoscaler_image}`

provider_image=`grep "image:" ${provider_conf_file} | cut -d ':' -f2- | tr -d ' '`
output=`printf "%s\n" ${output} ${provider_image}`

# Extract images from manifest.yaml and add to output
csi_images=`grep "image:" "${csi_conf_file}" | cut -d ':' -f2- | tr -d ' ' | tr -d "'"`
output=`printf "%s\n%s" "${output}" "${csi_images}"`

while read -r line; do
    echo "Downloading image $line ---"
    if [[ $line == kubernetesui* ]] || [[ $line == apache* ]] || [[ $line == weaveworks* ]]; then
      line="docker.io/${line}"
    fi
    if [[ $line == kong* ]]; then
      line="docker.io/library/${line}"
    fi
    line=$(echo $line | tr -d '"' | tr -d "'")
    sudo ctr image pull "$line"
    image_name=`echo "$line" | grep -oE "[^/]+$"`
    sudo ctr image export "${working_dir}/docker/$image_name.tar" "$line"
    sudo ctr image rm "$line"
done <<< "$output"

echo "Restore kubeadm permissions..."
if [ -z "${kubeadm_file_permissions}" ]; then
    kubeadm_file_permissions=644
fi
chmod ${kubeadm_file_permissions} "${working_dir}/k8s/kubeadm"

echo "Updating imagePullPolicy to IfNotPresent in yaml files..."
sed -i "s/imagePullPolicy:.*/imagePullPolicy: IfNotPresent/g" ${working_dir}/*.yaml

# Optional parameter ETCD_VERSION
if [ -n "${9}" ]; then
  etcd_dir="${working_dir}/etcd"
  mkdir -p "${etcd_dir}"
  ETCD_VERSION=v${9}
  wget -q --show-progress "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" -O ${etcd_dir}/etcd-linux-amd64.tar.gz
fi

echo "Building ISO..."
mkisofs -o "${output_dir}/${build_name}" -J -R -l "${iso_dir}"

rm -rf "${iso_dir}"

echo "Done. ISO created at: ${output_dir}/${build_name}"
