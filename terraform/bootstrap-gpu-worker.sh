#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k8s-bootstrap.log) 2>&1

echo "=== GPU worker bootstrap start ==="

# Disable unattended upgrades
systemctl disable --now unattended-upgrades || true

# Pin kernel (critical for GPU driver stability)
apt-mark hold linux-image-$(uname -r) linux-headers-$(uname -r) || true

# Kernel params
tee /etc/sysctl.d/99-kubernetes.conf > /dev/null << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
modprobe overlay br_netfilter
sysctl --system

# Swap
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# containerd
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y && apt-get install -y containerd.io conntrack
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# kubeadm + kubelet + kubectl
K8S_VERSION="1.31"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# GPU-specific: kernel headers + nouveau blacklist
apt-get install -y linux-headers-$(uname -r)
echo "blacklist nouveau" | tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
echo "options nouveau modeset=0" | tee -a /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
update-initramfs -u 2>/dev/null || true

echo "=== GPU worker bootstrap complete ==="
