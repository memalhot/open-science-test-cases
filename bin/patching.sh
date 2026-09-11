oc patch nodefeaturediscovery nfd-instance -n openshift-nfd --type=json \
    -p='[{"op":"remove","path":"/spec/operand/image"},{"op":"remove","path":"/spec/operand/servicePort"}]' \
    --as system:admin

oc patch nodefeaturediscovery nfd-instance -n openshift-nfd \
    --type merge -p '{"spec":{"enableTaints":true}}' \
    --as system:admin

oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  --type merge \
  -p '{"spec":{"dashboardConfig":{"disableHardwareProfiles":false}}}' \
  --as system:admin

oc annotate storageclass pure-fb-nfsv4 \
  --as system:admin \
  --overwrite \
  "opendatahub.io/sc-config={\"displayName\":\"pure-fb-nfsv4\",\"isEnabled\":true,\"isDefault\":true,\"lastModified\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"accessModeSettings\":{\"ReadWriteOnce\":true,\"ReadWriteMany\":true,\"ReadOnlyMany\":false,\"ReadWriteOncePod\":false}}"