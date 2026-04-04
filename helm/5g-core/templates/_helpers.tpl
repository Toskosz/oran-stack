# ============================================================================
# _helpers.tpl — Shared template fragments for 5g-core
# ============================================================================
{{/*
Common environment variables injected into every Open5GS NF container.
These replace the x-open5gs-common-env YAML anchor from docker-compose.yml.
envsubst in entrypoint.sh reads these at container startup and writes the
final NF YAML configs under /open5gs/install/etc/open5gs/.
*/}}
{{- define "5g-core.commonEnv" -}}
- name: SKIP_MONGODB
  value: "true"
- name: MONGODB_URI
  value: {{ .Values.mongodb.uri | quote }}
- name: MCC
  value: {{ .Values.plmn.mcc | quote }}
- name: MNC
  value: {{ .Values.plmn.mnc | quote }}
- name: TAC
  value: {{ .Values.plmn.tac | quote }}
- name: AMF_REGION
  value: {{ .Values.amf.region | quote }}
- name: AMF_SET
  value: {{ .Values.amf.set | quote }}
- name: AMF_IP
  value: "0.0.0.0"
- name: AMF_SBI_PORT
  value: {{ .Values.amf.sbiPort | quote }}
- name: AMF_NGAP_PORT
  value: {{ .Values.amf.ngapPort | quote }}
- name: AMF_METRICS_PORT
  value: {{ .Values.amf.metricsPort | quote }}
- name: NRF_IP
  value: "nrf"
- name: NRF_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: SCP_IP
  value: "scp"
- name: SCP_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: SEPP_IP
  value: "sepp"
- name: SEPP_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: SMF_IP
  value: "0.0.0.0"
- name: SMF_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: SMF_GTP_C_PORT
  value: "2123"
- name: SMF_GTP_U_PORT
  value: "2152"
- name: SMF_PFCP_PORT
  value: "8805"
- name: SMF_METRICS_PORT
  value: {{ .Values.amf.metricsPort | quote }}
- name: SMF_SUBNET4
  value: {{ .Values.ue.subnet4 | quote }}
- name: SMF_SUBNET6
  value: {{ .Values.ue.subnet6 | quote }}
- name: UPF_IP
  value: "upf"
- name: UPF_GTP_U_PORT
  value: "2152"
- name: UPF_PFCP_PORT
  value: "8805"
- name: UPF_METRICS_PORT
  value: {{ .Values.amf.metricsPort | quote }}
- name: AUSF_IP
  value: "0.0.0.0"
- name: AUSF_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: UDM_IP
  value: "0.0.0.0"
- name: UDM_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: PCF_IP
  value: "0.0.0.0"
- name: PCF_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: PCF_METRICS_PORT
  value: {{ .Values.amf.metricsPort | quote }}
- name: NSSF_IP
  value: "0.0.0.0"
- name: NSSF_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: BSF_IP
  value: "0.0.0.0"
- name: BSF_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: UDR_IP
  value: "0.0.0.0"
- name: UDR_SBI_PORT
  value: {{ .Values.sbiPort | quote }}
- name: MME_GID
  value: {{ .Values.mme.gid | quote }}
- name: MME_CODE
  value: {{ .Values.mme.code | quote }}
- name: MME_S1AP_PORT
  value: {{ .Values.mme.s1apPort | quote }}
- name: MME_GTP_PORT
  value: {{ .Values.mme.gtpPort | quote }}
- name: MME_METRICS_PORT
  value: {{ .Values.mme.metricsPort | quote }}
- name: SGWC_GTP_PORT
  value: "2123"
- name: SGWC_PFCP_PORT
  value: "8805"
- name: SGWU_GTP_U_PORT
  value: "2152"
- name: SGWU_PFCP_PORT
  value: "8805"
- name: LOG_LEVEL
  value: {{ .Values.logLevel | quote }}
{{- end }}

{{/*
Common securityContext for privileged Open5GS NF containers.
All NFs in docker-compose.yml run with privileged:true + NET_ADMIN/SYS_ADMIN/NET_RAW.
For a lab, this is acceptable. In production, narrow these capabilities per-NF.
*/}}
{{- define "5g-core.privilegedSecurityContext" -}}
securityContext:
  privileged: true
  capabilities:
    add:
      - NET_ADMIN
      - SYS_ADMIN
      - NET_RAW
{{- end }}

{{/*
Common volume mounts for NF containers: configs (read-only) + log directory.
*/}}
{{- define "5g-core.nfVolumeMounts" -}}
- name: nf-configs
  mountPath: /open5gs/configs
  readOnly: true
- name: open5gs-logs
  mountPath: /var/log/open5gs
{{- end }}

{{/*
Common volumes for NF pods.
*/}}
{{- define "5g-core.nfVolumes" -}}
- name: nf-configs
  configMap:
    name: open5gs-nf-configs
- name: open5gs-logs
  emptyDir: {}
{{- end }}

{{/*
imagePullSecrets block.
*/}}
{{- define "5g-core.imagePullSecrets" -}}
imagePullSecrets:
  - name: {{ .Values.imagePullSecretName }}
{{- end }}
