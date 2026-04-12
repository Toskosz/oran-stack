#!/usr/bin/env bash
# =============================================================================
# gcp-vm-bootstrap.sh
# GCP instance startup script — runs once as root when the VM first boots.
#
# Installs:
#   - VirtualBox 7.x (with nested virtualisation kernel modules)
#   - Vagrant 2.4.x
#   - Ansible (via pip, latest stable)
#   - Docker (for building images)
#   - git, curl, wget, jq, python3
#
# Clones the oran-stack repo into /home/<first-non-root-user>/oran-stack
# and writes a sentinel file when done so the Ansible playbook can poll.
# =============================================================================
set -euo pipefail
exec > /var/log/oran-bootstrap.log 2>&1

echo "[bootstrap] Starting at $(date)"

# ── Identify the login user (the one gcloud creates via OS Login or metadata) ─
# On GCE Ubuntu the default user is named after the gcloud account.
# Fall back to the first sudoer that is not root.
LOGIN_USER=$(getent passwd | awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}')
LOGIN_HOME=$(eval echo "~${LOGIN_USER}")
echo "[bootstrap] Login user: ${LOGIN_USER} (home: ${LOGIN_HOME})"

# ── System update ─────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# ── Base tools ────────────────────────────────────────────────────────────────
apt-get install -y -qq \
  curl wget git jq unzip gnupg lsb-release \
  ca-certificates apt-transport-https \
  python3 python3-pip python3-venv \
  linux-headers-"$(uname -r)" \
  build-essential dkms

# ── VirtualBox 7.x ───────────────────────────────────────────────────────────
echo "[bootstrap] Installing VirtualBox..."
wget -qO /etc/apt/trusted.gpg.d/oracle-virtualbox.asc \
  https://www.virtualbox.org/download/oracle_vbox_2016.asc
echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/oracle-virtualbox.asc] \
  https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" \
  > /etc/apt/sources.list.d/virtualbox.list
apt-get update -qq
apt-get install -y -qq virtualbox-7.0

# Add the login user to the vboxusers group
usermod -aG vboxusers "${LOGIN_USER}"

# ── VirtualBox Extension Pack (enables nested-virt features) ─────────────────
VBX_VER=$(VBoxManage --version | sed 's/r.*//')
echo "[bootstrap] Installing VirtualBox Extension Pack ${VBX_VER}..."
wget -qO /tmp/VBoxExtPack.vbox-extpack \
  "https://download.virtualbox.org/virtualbox/${VBX_VER}/Oracle_VM_VirtualBox_Extension_Pack-${VBX_VER}.vbox-extpack"
echo "y" | VBoxManage extpack install --replace /tmp/VBoxExtPack.vbox-extpack
rm /tmp/VBoxExtPack.vbox-extpack

# ── Vagrant ──────────────────────────────────────────────────────────────────
echo "[bootstrap] Installing Vagrant..."
VAGRANT_VERSION="2.4.1"
wget -qO /tmp/vagrant.deb \
  "https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_amd64.deb"
dpkg -i /tmp/vagrant.deb
rm /tmp/vagrant.deb

# ── Ansible (via pip into a venv, accessible system-wide via symlinks) ────────
echo "[bootstrap] Installing Ansible..."
python3 -m venv /opt/ansible-venv
/opt/ansible-venv/bin/pip install --quiet --upgrade pip
/opt/ansible-venv/bin/pip install --quiet ansible

# Symlink into /usr/local/bin so it is on PATH for all users
for bin in ansible ansible-playbook ansible-galaxy ansible-vault; do
  ln -sf /opt/ansible-venv/bin/${bin} /usr/local/bin/${bin}
done

# ── Docker (for building images) ──────────────────────────────────────────────
echo "[bootstrap] Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
usermod -aG docker "${LOGIN_USER}"

# ── Helm ─────────────────────────────────────────────────────────────────────
echo "[bootstrap] Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── kubectl ──────────────────────────────────────────────────────────────────
echo "[bootstrap] Installing kubectl..."
KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# ── Clone repo ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/x0tok/oran-stack.git"
REPO_DIR="${LOGIN_HOME}/oran-stack"

echo "[bootstrap] Cloning ${REPO_URL} -> ${REPO_DIR}..."
if [ -d "${REPO_DIR}/.git" ]; then
  echo "[bootstrap] Repo already cloned, pulling latest..."
  sudo -u "${LOGIN_USER}" git -C "${REPO_DIR}" pull --ff-only
else
  sudo -u "${LOGIN_USER}" git clone "${REPO_URL}" "${REPO_DIR}"
fi

# ── Install Ansible Galaxy collections ───────────────────────────────────────
echo "[bootstrap] Installing Ansible Galaxy collections..."
sudo -u "${LOGIN_USER}" ansible-galaxy collection install \
  -r "${REPO_DIR}/ansible/requirements.yml" \
  --collections-path "${LOGIN_HOME}/.ansible/collections"

# ── Sentinel file — signals bootstrap complete ────────────────────────────────
touch /var/lib/oran-bootstrap-done
echo "[bootstrap] Done at $(date)"
