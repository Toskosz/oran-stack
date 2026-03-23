Here is the full translation of the document formatted into Markdown for your agent:
Documentation

O-RAN Architecture: Implementation of the CU/DU Split with E2 Integration to the Near-RT RIC in Distinct Virtual Machines


Letícia Brito, 242039381  Dep. Ciência da Computação - Universidade de Brasília (UnB) O-RAN UnB 242039381@aluno.unb.br

1. Introduction

This report documents the evolution of the O-RAN testbed following the separation phase between the VM-RAN and the VM-RIC. In the first phase, the objective was to enable E2 communication between a monolithic gNB and the Near-RT RIC running in distinct virtual machines. In the stage described in this report, the architecture was evolved to a scenario with a split between the CU and DU, while keeping the RIC in a separate VM. The experiment was conducted with srsRAN Project, Open5GS, and O-RAN SC Near-RT RIC, executed in Docker containers [O-RAN Alliance 2021]. The goal was to replace the monolithic gNB with two explicit functions:

CU (Central Unit), executed by the srscu binary.


DU (Distributed Unit), executed by the srsdu binary.


At the end of the experiment, the following interfaces were validated:

F1 between DU and CU.


N2 between CU and AMF.


E2 between DU and Near-RT RIC.


Additionally, a virtual radio interface based on ZMQ was maintained for communication with the legacy UE. However, the RU was not disaggregated from the DU: in the testbed, the RU functionality remained incorporated into the srsdu process.

2. Objective

The objective of this experiment is to implement and validate, in a virtualized environment, a disaggregated 5G architecture with a CU/DU split [Software Radio Systems (SRS) 2024a], preserving the DU's connection to the Near-RT RIC through the E2 interface and the CU's connection to the 5G core through the N2 interface. More specifically, the goals were to:

Compile the srscu and srsdu binaries from the srsRAN_Project repository [Software Radio Systems (SRS) 2024b].


Create a Docker image containing the split binaries.


Configure the cu.yml and du.yml files.


Spin up two distinct containers for the CU and DU.


Validate the F1 interface between DU and CU.


Validate the N2 interface between CU and AMF.


Enable E2 on the DU and validate the E2 interface with the RIC in the separate VM.


3. Testbed Architecture

The implemented architecture follows the functional separation model defined by 3GPP, known as the Option 2 split, where the division occurs between the PDCP and RLC layers [3GPP 2023]. Figure 1 presents the final architecture of the environment.


Figure 1. Final testbed architecture with CU/DU split, 5G core, and Near-RT RIC in distinct VMs.

VM-RAN (192.168.72.100)


srsue_5g_zmq flows via ZMQ to srs_du (DU + RU).


srs_du flows via F1 to srs_cu.


srs_cu flows via N2 to Open5GS.


VM-RIC (192.168.72.104)


srs_du connects via E2 to ric_e2term.


ric_e2term flows to ric_e2mgr, then to ric_submgr, then to ric_rtmgr_sim, and finally to xApps.


In the implemented architecture:

The UE communicates with the DU via a virtual radio interface based on ZMQ.


The DU connects to the CU via the F1 interface.


The CU connects to the Open5GS AMF via the N2 interface.


The DU connects to the Near-RT RIC via the E2 interface using SCTP on port 36421.


3.1.
Implemented Interfaces
ZMQ: Virtual radio interface between the legacy UE and srsdu. In this experiment, the RU functionality remained embedded in the DU.


F1: Interface between DU and CU. The experiment used F1-C and F1-U over an IP network within the VM-RAN.


N2: Interface between CU and 5G core AMF.


NG-U: User plane between CU and UPF, handled by srscu.


E2: Interface between DU and Near-RT RIC.


4. Experimental Environment

The primary IP addresses used were:

VM-RAN: 192.168.72.100


VM-RIC: 192.168.72.104


AMF: 172.22.0.10


UE ZMQ: 172.22.0.34


CU: 172.22.0.50


DU: 172.22.0.51


E2Term: 172.22.0.210


The PLMN and TAC used were inherited from the Open5GS environment:

MCC = 001


MNC = 01


PLMN 00101


TAC = 1


5. srsRAN Project Preparation

Initially, a working directory was created to compile a specific image containing the split.


Listing 1. Initial split directory structure.


Bash


mkdir -p /home/leticia.brito/srsran_split
cd /home/leticia.brito/srsran_split
git clone https://github.com/srsran/srsRAN_Project.git


During the inspection of the project targets, the following directories were identified:


Listing 2. Verifying the presence of CU and DU applications in the repository.


Bash


cd /home/leticia.brito/srsran_split/srsRAN_Project
find -maxdepth 3 -type d | grep -E '/apps/(cu|du)$'
find -maxdepth 3 -type f | grep -E '/configs/.*(cu|du|split|f1)'


Next, the project was configured and compiled locally. It was necessary to install basic compilation dependencies, including pkg-config, which had caused an error in the first cmake attempt.


Listing 3. Installing dependencies for srsRAN Project build.


Bash


apt update
apt install -y \
pkg-config \
build-essential \
cmake \
ninja-build \
git \
libsctp-dev \
libyaml-cpp-dev \
libmbedtls-dev \
libzmq3-dev \
libfftw3-dev \
librohc-dev


After that, the project was compiled:


Listing 4. Local configuration and compilation of the srsRAN Project.


Bash


cd /home/leticia.brito/srsran_split/srsRAN_Project
rm -rf build
cmake -B build
cmake --build build -j"$(nproc)"


The generated binaries were verified with:


Listing 5. Verification of the generated binaries.


Bash


find build -type f | grep -E 'srscu|srsdu|srscucp|srscuup|gnb$'


As a result, the following binaries were found:

build/apps/cu/srscu


build/apps/du/srsdu


build/apps/cu_cp/srscucp


build/apps/cu_up/srscuup


build/apps/gnb/gnb


6. Docker Image Creation for the Split

To encapsulate the split binaries, a specific Dockerfile was created.


Listing 6. File /home/leticia.brito/srsran_split/Dockerfile.


Dockerfile


FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
pkg-config \
build-essential \
cmake \
ninja-build \
git \
libsctp-dev \
libyaml-cpp-dev \
libmbedtls-dev \
libzmq3-dev \
libfftw3-dev \
iproute2 \
net-tools \
iputils-ping \
tcpdump \
curl \
nano \
&& rm -rf /var/lib/apt/lists/*
WORKDIR /opt
COPY srsRAN_Project /opt/srsRAN_Project
WORKDIR /opt/srsRAN_Project
RUN cmake -B build
RUN cmake --build build -j"$(nproc)"
RUN test -f /opt/srsRAN_Project/build/apps/cu/srscu
RUN test -f /opt/srsRAN_Project/build/apps/du/srsdu
RUN cp /opt/srsRAN_Project/build/apps/cu/srscu /usr/local/bin/srscu
RUN cp /opt/srsRAN_Project/build/apps/du/srsdu /usr/local/bin/srsdu
RUN cp /opt/srsRAN_Project/build/apps/gnb/gnb /usr/local/bin/gnb || true
WORKDIR /mnt/srsran_split
CMD ["/bin/bash"]


Because the build/local directory caused a CMake cache conflict when copied into the image, a .dockerignore file was created:


Listing 7. File /home/leticia.brito/srsran_split/.dockerignore.


Plaintext


srsRAN_Project/build
srsRAN_Project/.git


The image was then built with:


Listing 8. Docker image build for the split.


Bash


cd /home/leticia.brito/srsran_split
docker build --no-cache -t docker_srsran_split .


Finally, the binaries available inside the image were validated:


Listing 9. Validation of the created image.


Bash


docker run --rm -it docker_srsran_split sh -lc \
'find / -type f \( -name "srscu" -o -name "srsdu" -o -name "gnb" \) 2>/dev/null'


7. Modified Configuration Files

The split phase required the creation and editing of four main files:

configs/cu.yml


configs/du.yml


docker-compose-split.yml


logs/ (directory for log persistence)


7.1. cu.yml File

The cu.yml file was created to define the connection of the CU with the AMF and the DU.


Listing 10. File /home/leticia.brito/srsran_split/configs/cu.yml.


YAML


cu_cp:
  amf:
    addr: 172.22.0.10
    bind_addr: 172.22.0.50
    supported_tracking_areas:
      tac: 1
      plmn_list:
        - plmn: "00101"
          tai_slice_support_list:
            - sst: 1
  f1ap:
    bind_addr: 172.22.0.50
cu_up:
  f1u:
    bind_port: 2153
    peer_port: 2153
    socket:
  ngu:
    bind_addr: 172.22.0.50
log:
  filename: /mnt/srsran_split/cu.log
  all_level: info


During testing, the file underwent significant adjustments:

The cell_cfg block was removed from the CU, as it caused a parsing error.


The all_level was corrected to info.


Port 2153 was adopted for F1-U to avoid conflicts with NG-U.


7.2. du.yml File

The du.yml file centralized the configurations for F1, E2, and virtual radio via ZMQ.


Listing 11. File /home/leticia.brito/srsran_split/configs/du.yml.


YAML


f1ap:
  cu_cp_addr: 172.22.0.50
  bind_addr: 172.22.0.51
f1u:
  bind_port: 2153
  peer_port: 2153
  socket:
    bind_addr: 172.22.0.51
e2:
  enable_du_e2: true
  addr: 192.168.72.104
  port: 36421
  bind_addr: 172.22.0.51
  e2sm_kpm_enabled: true
  e2sm_rc_enabled: true
ru_sdr:
  device_driver: zmq
  device_args: tx_port=tcp://172.22.0.51:2000, rx_port=tcp://172.22.0.34:2001, base_srate=23.04e6
  srate: 23.04
  tx_gain: 75
  rx_gain: 75
cell_cfg:
  dl_arfcn: 368500
  band: 3
  channel_bandwidth_MHz: 20
  common_scs: 15
  plmn: "00101"
  tac: 1
  pci: 1
  pdcch:
    dedicated:
      ss2_type: common
      dci_format_0_1_and_1_1: false
    common:
      ss0_index: 0
      coreset0_index: 13
  pdsch:
    mcs_table: qam64
  pusch:
    mcs_table: qam64
  prach:
    prach_config_index: 1
log:
  filename: /mnt/srsran_split/du.log
  all_level: info


This file underwent incremental adjustments:

Defining the CU address in cu_cp_addr.


Separating F1-U on port 2153.


Including the e2 section pointing to the VM-RIC.


Using the virtual radio ru_sdr with device_driver=zmq.


7.3. docker-compose-split.yml File

Two independent containers were defined for the split.


Listing 12. File /home/leticia.brito/srsran_split/docker-compose-split.yml.


YAML


services:
  srs_cu:
    container_name: srs_cu
    image: docker_srsran_split
    command: ["/usr/local/bin/srscu", "-c", "/mnt/srsran_split/configs/cu.yml"]
    volumes:
      - ./configs:/mnt/srsran_split/configs
      - ./logs:/mnt/srsran_split/logs
    networks:
      docker_open5gs_default:
        ipv4_address: 172.22.0.50
  srs_du:
    container_name: srs_du
    image: docker_srsran_split
    command: ["/usr/local/bin/srsdu", "-c", "/mnt/srsran_split/configs/du.yml"]
    volumes:
      - ./configs:/mnt/srsran_split/configs
      - ./logs:/mnt/srsran_split/logs
    networks:
      docker_open5gs_default:
        ipv4_address: 172.22.0.51
networks:
  docker_open5gs_default:
    external: true


8. CU/DU Split Execution

After creating the configuration files, it was necessary to stop the monolithic container srsgnb_zmq:


Listing 13. Stopping the monolithic gNB.


Bash


docker stop srsgnb_zmq
docker rm srsgnb_zmq


The logs directory was created with:


Listing 14. Creating the logs directory.


Bash


mkdir -p /home/leticia.brito/srsran_split/logs


Then, the split was launched:


Listing 15. Bringing up the CU/DU split.


Bash


cd /home/leticia.brito/srsran_split
docker compose -f docker-compose-split.yml up -d


The initial validation of the running containers was done by:


Listing 16. Verifying the containers.


Bash


docker ps -a
docker logs --tail 100 srs_cu
docker logs --tail 100 srs_du


9. Debugging and Applied Corrections

Throughout the deployment, several syntax and port errors occurred, which were resolved iteratively.

9.1.
Issues Encountered in the CU
The primary errors observed in srs_cu were:

Parse error in cell_cfg.


Invalid all_level value.


UDP port 2152 conflict between NG-U and F1-U.


These issues were resolved by:

Removing the cell_cfg block from cu.yml.


Correcting all_level: info.


Redefining F1-U to port 2153.


9.2.
Interface Validation
Connectivity between containers was verified with:


Listing 17. IP connectivity tests between elements.


Bash


docker exec -it srs_du ping -c 3 172.22.0.50
docker exec -it srs_cu ping -c 3 172.22.0.10
docker exec -it srs_du ping -c 3 172.22.0.34
docker exec -it srsue_5g_zmq ping -c 3 172.22.0.51


The opening of ZMQ ports was checked with:


Listing 18. Validation of ZMQ link TCP connections.


Bash


docker exec -it srsue_5g_zmq sh -lc 'netstat -ltnp 2>/dev/null; netstat -tanp 2>/dev/null | grep 200'
docker exec -it srs_du sh -lc 'netstat -ltnp 2>/dev/null; netstat -tanp 2>/dev/null | grep 200'


10. F1 and N2 Interface Validation

The F1 interface validation was observed in the du.log file, where success messages for the F1 Setup procedure appeared:


Listing 19. Commands used to inspect F1 and DU logs.


Bash


tail -n 100 /home/leticia.brito/srsran_split/logs/du.log
grep -Ei 'f1|setup|du-f1' /home/leticia.brito/srsran_split/logs/du.log


In the logs, equivalent messages were observed such as:

F1-C: TNL connection to CU-CP accepted


F1 Setup: Sending F1 Setup Request


F1 Setup: Procedure completed successfully


The validation of N2 between the CU and AMF was observed in the Open5GS AMF:


Listing 20. Verification of N2 association in the AMF.


Bash


docker logs amf 2>&1 | grep -Ei 'ngap|gNB|sctp|amf|connection'


The output indicated the acceptance of the gNB/CU by the AMF:

gNB-N2 accepted [172.22.0.50]


[Added] Number of gNBs is now 1


11. DU Integration to the Near-RT RIC via E2

After validating F1 and N2, the e2 section was enabled in du.yml. Since the RIC was on another VM, the E2 addr was configured with the VM-RIC's IP:

addr: 192.168.72.104


port: 36421


The DU was restarted using:


Listing 21. DU restart after enabling E2.


Bash


docker rm -f srs_du
cd /home/leticia.brito/srsran_split
docker compose -f docker-compose-split.yml up -d srs_du


The DU logs were then filtered to confirm E2:


Listing 22. Inspection of DU E2 logs.


Bash


grep -Ei 'e2|ric|setup sctp' /home/leticia.brito/srsran_split/logs/du.log | tail -n 50


The RIC logs were also checked:


Listing 23. Verification of DU association in the RIC.


Bash


docker logs -f ric_e2term 2>&1 | egrep -i "ranName|e2setup|sctp|error|warn|gnb|du"
docker logs -f ric_rtmgr_sim
curl -s http://172.22.0.211:3800/v1/nodeb/states


As a result, it was possible to observe:

In du.log: E2 Setup procedure successful


In ric_rtmgr_sim: association of the node gnbd_001_001_00019b_0


In /v1/nodeb/states: node gnbd_001_001_00019b_0 connectionStatus: CONNECTED


12. Results Obtained

The experiment demonstrated that the CU/DU split was successfully implemented and that the DU was capable of integrating into the Near-RT RIC on a separate virtual machine. The final validated architecture was:

F1: DU connected to the CU.


N2: CU connected to the AMF.


E2: DU connected to the Near-RT RIC.


ZMQ: Virtual radio link between the legacy UE and DU.


It is important to emphasize that:

The RU was not separated from the DU.


The environment explicitly implemented the CU/DU split.


The RU functionality remained integrated into srsdu, using ru_sdr with ZMQ.


13. Conclusion

This report documented, step-by-step, the implementation of the CU/DU split with the srsRAN Project in a virtualized environment, as well as the integration of the DU to the Near-RT RIC executing on another virtual machine. The sequence of commands and modifications presented enables the reproduction of the experiment by other users, provided the same IP addressing logic and Docker network topology are preserved.

The main results were:

Compilation and packaging of the srscu and srsdu binaries.


Creation of independent containers for CU and DU.


Validation of the F1 interface between DU and CU.


Validation of the N2 interface between CU and AMF.


Validation of the E2 interface between DU and Near-RT RIC.


Confirmation of the CONNECTED state of the E2 node corresponding to the DU in the RIC inventory.


Thus, the environment evolved from a monolithic gNB to a disaggregated architecture, more aligned with the O-RAN paradigm, preserving the potential to execute future experimental phases, such as xApps in the RIC and the adoption of a UE compatible with the new srsRAN Project stack.

References

[3GPP 2023] 3GPP (2023). NG-RAN Architecture Description (TS 38.401). Defines CU/DU architecture and F1 interface.


[O-RAN Alliance 2021] O-RAN Alliance (2021). O-RAN Architecture Description. General O-RAN Architecture.


[Software Radio Systems (SRS) 2024a] Software Radio Systems (SRS) (2024a). srsRAN Project CU/DU Split Architecture. Accessed in 2026.


[Software Radio Systems (SRS) 2024b] Software Radio Systems (SRS) (2024b). srsRAN Project Documentation. Accessed in 2026.
