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