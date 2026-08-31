oc patch nodefeaturediscovery nfd-instance -n openshift-nfd --type=json \
    -p='[{"op":"remove","path":"/spec/operand/image"},{"op":"remove","path":"/spec/operand/servicePort"}]' \
    --as system:admin