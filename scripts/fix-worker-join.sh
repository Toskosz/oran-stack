#!/usr/bin/env bash
# Reset orphaned w1 join state and re-run provision with updated worker role.
set -euo pipefail

REPO_ROOT="$(cd "${1:-$(pwd)}" && pwd)"
INVENTORY="${INVENTORY:-$REPO_ROOT/ansible/inventories/hosts.ini}"

if [[ ! -f "$INVENTORY" ]]; then
  echo "Missing inventory: $INVENTORY" >&2
  exit 1
fi

WORKER_ROLE="$REPO_ROOT/ansible/roles/kubeadm_worker/tasks/main.yml"
cat > "$WORKER_ROLE" << 'EOF'
---
# kubeadm_worker/tasks/main.yml
# Runs on worker nodes. Joins the cluster using the token/hash generated
# by the control-plane role, then waits for the node to become Ready.

- name: Ensure node name resolves in /etc/hosts
  lineinfile:
    path: /etc/hosts
    line: "127.0.1.1 {{ inventory_hostname }}"
    regexp: "^127\\.0\\.1\\.1 {{ inventory_hostname }}$"
    state: present

- name: Check if node has kubelet configuration
  stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf

- name: Check if node is registered in the cluster
  command: kubectl get node {{ inventory_hostname }}
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  delegate_to: "{{ groups['control_plane'][0] }}"
  register: _node_in_cluster
  changed_when: false
  failed_when: false

- name: Reset orphaned worker join state
  command: kubeadm reset -f
  when:
    - kubelet_conf.stat.exists
    - _node_in_cluster.rc != 0

- name: Join cluster
  command: "{{ hostvars[groups['control_plane'][0]]['join_command'] }} --node-name={{ inventory_hostname }}"
  when: _node_in_cluster.rc != 0
  register: _kubeadm_join
  failed_when: _kubeadm_join.rc != 0

- name: Wait for worker node to register with the API server
  command: kubectl get node {{ inventory_hostname }}
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  delegate_to: "{{ groups['control_plane'][0] }}"
  register: _worker_registered
  retries: 30
  delay: 10
  until: _worker_registered.rc == 0
  changed_when: false

- name: Wait for worker node to become Ready
  command: >
    kubectl get node {{ inventory_hostname }}
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  delegate_to: "{{ groups['control_plane'][0] }}"
  register: worker_ready
  retries: 30
  delay: 10
  until: worker_ready.stdout == "True"
  changed_when: false
EOF

echo "==> Resetting orphaned join state on w1 (if any)"
ansible -i "$INVENTORY" w1 -b -m command -a "kubeadm reset -f"

echo "==> Re-running provision.yml"
ansible-playbook "$REPO_ROOT/ansible/playbooks/provision.yml" -i "$INVENTORY"

echo "==> Cluster nodes:"
export KUBECONFIG="$REPO_ROOT/kubeconfig"
kubectl get nodes -o wide
