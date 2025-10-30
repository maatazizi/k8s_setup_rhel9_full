#!/bin/bash
# ==========================================================
# Bare-Metal Kubernetes Setup on RHEL 9.6 (Steps 1–9)
# With Error Handling and UTF-8 Output
# ==========================================================
# Author : Mohd Azizi Shamsuddin
# Version: 1.2
# ==========================================================

set -e  # Stop on first unhandled error

# -------- Helper Functions --------
check_status() {
  if [ $? -ne 0 ]; then
    echo "? [ERROR] $1"
    exit 1
  else
    echo "? [OK] $2"
  fi
}

#pause() {
#  read -p "Press [Enter] to continue..."
#}

# -------- 1. Declare Versions --------
echo "?? STEP 1: Declare Versions"

export KUBE_VERSION="1.34.1"
export CONTAINERD_VERSION="2.1.4"
export RUNC_VERSION="1.3.1"
export CNI_VERSION="1.8.0"
export ARCH="amd64"

echo "Using:"
echo "  - Kubernetes: $KUBE_VERSION"
echo "  - containerd: $CONTAINERD_VERSION"
echo "  - runc: $RUNC_VERSION"
echo "  - CNI: $CNI_VERSION"


# -------- 2. Prepare System --------
#echo "?? STEP 2: System Preparation"
#sudo dnf -y update
#check_status "Failed to update packages" "System updated"

# Kernel modules
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter
check_status "Failed to load kernel modules" "Kernel modules loaded"

# Sysctl params
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null
check_status "Failed to apply sysctl parameters" "Sysctl parameters applied"

# Disable swap
sudo swapoff -a && sudo sed -i '/swap/d' /etc/fstab
check_status "Failed to disable swap" "Swap disabled"

# SELinux
sudo setenforce 0 || true
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
check_status "Failed to set SELinux permissive" "SELinux set to permissive"


# -------- 3. Install containerd + runc --------
echo "?? STEP 3: Install containerd & runc"
cd /tmp

wget -q https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz
check_status "Failed to download containerd" "containerd package downloaded"

sudo tar -C /usr/local -xzf containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz
check_status "Failed to extract containerd" "containerd extracted"

wget -q https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64
check_status "Failed to download runc" "runc downloaded"
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
check_status "Failed to install runc" "runc installed"

sudo mkdir -p /etc/containerd
sudo /usr/local/bin/containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
check_status "Failed to configure containerd" "containerd configured"

# systemd service
sudo tee /etc/systemd/system/containerd.service >/dev/null <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
check_status "Failed to start containerd" "containerd running"


# -------- 4. Install CNI Plugins --------
echo "?? STEP 4: Install CNI Plugins"
curl -sLO https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
check_status "Failed to download CNI plugins" "CNI downloaded"

sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
check_status "Failed to install CNI plugins" "CNI plugins installed"


# -------- 5. Install kubeadm / kubelet / kubectl --------
echo "?? STEP 5: Install kubeadm / kubelet / kubectl"

cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
check_status "Failed to install kubeadm/kubelet/kubectl" "Kubernetes binaries installed"

sudo systemctl enable --now kubelet
check_status "Failed to start kubelet" "kubelet running"


# -------- 6. Master Firewall --------
echo "?? STEP 6: Configure Master Firewall"
read -p "Is this MASTER node? (y/n): " MASTER
if [[ "$MASTER" =~ ^[Yy]$ ]]; then
  sudo firewall-cmd --permanent --add-port=6443/tcp
  sudo firewall-cmd --permanent --add-port=2379-2380/tcp
  sudo firewall-cmd --permanent --add-port=10250/tcp
  sudo firewall-cmd --permanent --add-port=10251/tcp
  sudo firewall-cmd --permanent --add-port=10252/tcp
  sudo firewall-cmd --reload
  check_status "Failed to configure master firewall" "Master firewall configured"
fi

# -------- 7. Worker Firewall --------
echo "?? STEP 7: Configure Worker Firewall"
read -p "Is this WORKER node? (y/n): " WORKER
if [[ "$WORKER" =~ ^[Yy]$ ]]; then
  sudo firewall-cmd --permanent --add-port=10250/tcp
  sudo firewall-cmd --permanent --add-port=30000-32767/tcp
  sudo firewall-cmd --reload
  check_status "Failed to configure worker firewall" "Worker firewall configured"
fi

read -p "Disable firewall completely? (y/n): " DISABLEFW
if [[ "$DISABLEFW" =~ ^[Yy]$ ]]; then
  sudo systemctl disable --now firewalld.service
  check_status "Failed to disable firewall" "Firewall disabled"
fi

echo "==========================================================="
echo "? Kubernetes setup (Steps 1–7) completed successfully."
echo "Next step: kubeadm init (Step 8 onwards)"
echo "==========================================================="





# ==========================================================
# STEP 8A: Initialize Kubernetes Control Plane (Master Only)
# ==========================================================
echo "🔧 STEP 8A: Initialize Kubernetes Control Plane"

# Only proceed if admin.conf not found
if [ ! -f /etc/kubernetes/admin.conf ]; then
  echo "⚙️  admin.conf not found — cluster not initialized yet."
  read -p "Do you want to initialize this node as MASTER (control-plane)? (y/n): " INIT_MASTER

  if [[ "$INIT_MASTER" =~ ^[Yy]$ ]]; then
    echo "🚀 Running kubeadm init --pod-network-cidr=10.244.0.0/16 ..."
    sudo kubeadm init --pod-network-cidr=10.244.0.0/16
    check_status "Failed to initialize Kubernetes control-plane" "Control-plane initialized"

    echo "📂 Copying kubeconfig to current user..."
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    export KUBECONFIG=/etc/kubernetes/admin.conf
    check_status "Failed to configure kubeconfig" "Kubeconfig ready"

    echo "✅ Control-plane successfully initialized."
  else
    echo "⚠️  Skipping kubeadm init — ensure cluster already initialized."
  fi
else
  echo "ℹ️  Control-plane already initialized. Skipping kubeadm init."
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi








# ==========================================================
# STEP 8: Deploy Flannel CNI (Master Only)
# ==========================================================
echo "🔧 STEP 8: Deploy Flannel CNI Network Plugin"

# Pastikan kubectl guna kubeconfig betul (terutama bila run sebagai root)
if [ "$(id -u)" -eq 0 ] && [ -f /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

read -p "Is this the MASTER (control-plane) node? (y/n): " IS_MASTER
if [[ "$IS_MASTER" =~ ^[Yy]$ ]]; then
  read -p "Do you want to install Flannel CNI on the MASTER node? (y/n): " INSTALL_FLANNEL
  if [[ "$INSTALL_FLANNEL" =~ ^[Yy]$ ]]; then
    echo "📡 Using kubeconfig from: $KUBECONFIG"
    echo "🚀 Applying Flannel CNI manifest..."
    kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml --validate=false
    check_status "Failed to deploy Flannel CNI" "Flannel CNI applied"

    echo "⏳ Waiting 30 seconds for Flannel pods to initialize..."
    sleep 30
    kubectl get pods -n kube-system
    echo "✅ Flannel CNI installed successfully on MASTER node."
  else
    echo "⚠️  Skipping Flannel installation on MASTER node."
  fi
else
  echo "ℹ️  This is a WORKER node — skipping Flannel installation."
fi


echo "==========================================================="
echo "🎉 Kubernetes Networking setup (Flannel only) complete!"
echo "You can now join workers and deploy workloads."
echo "==========================================================="
