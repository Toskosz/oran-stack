# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# O-RAN Stack — Local kubeadm Cluster
#
# 2-node cluster: 1 control-plane (cp1) + 1 worker (w1)
# Network: private 192.168.56.0/24
#
# Sizing is configurable via environment variables.
# Lean defaults fit on a 16 GB host; override for cloud VMs:
#
#   CP_CPUS=4  CP_MEMORY=8192  W_CPUS=4  W_MEMORY=16384  vagrant up
#
# Defaults (16 GB host):
#   cp1: 2 vCPU / 4 GB  — control-plane only
#   w1:  4 vCPU / 6 GB  — runs all workloads
#   Total: 6 vCPU / 10 GB VM memory, ~6 GB free for host OS

CP_IP     = "192.168.56.10"
W_IP      = "192.168.56.11"
BOX       = "ubuntu/jammy64"

CP_CPUS   = (ENV["CP_CPUS"]   || 2).to_i
CP_MEMORY = (ENV["CP_MEMORY"] || 4096).to_i
W_CPUS    = (ENV["W_CPUS"]    || 4).to_i
W_MEMORY  = (ENV["W_MEMORY"]  || 6144).to_i

NODES = [
  { name: "cp1", ip: CP_IP, cpus: CP_CPUS, memory: CP_MEMORY },
  { name: "w1",  ip: W_IP,  cpus: W_CPUS,  memory: W_MEMORY  },
]

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  # Disable default /vagrant share — Ansible copies what it needs
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |node|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname = node[:name]

      vm.vm.network "private_network", ip: node[:ip]

      vm.vm.provider "virtualbox" do |vb|
        vb.name   = "oran-#{node[:name]}"
        vb.cpus   = node[:cpus]
        vb.memory = node[:memory]
        # Paravirtualized network for better throughput
        vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
        vb.customize ["modifyvm", :id, "--nictype2", "virtio"]
        # Required for nested virtualisation / SCTP on some hosts
        vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
      end

      vm.vm.provider "libvirt" do |lv|
        lv.cpus   = node[:cpus]
        lv.memory = node[:memory]
      end

      # Minimal shell bootstrap: ensure SSH key auth works for Ansible
      vm.vm.provision "shell", inline: <<~SHELL
        set -e
        # Ensure vagrant user can sudo without password (standard for ubuntu/jammy64)
        echo 'vagrant ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vagrant
        chmod 0440 /etc/sudoers.d/vagrant
        # Install Python3 for Ansible (ubuntu/jammy64 has it, but be explicit)
        apt-get update -qq
        apt-get install -y -qq python3 python3-apt
      SHELL
    end
  end
end
