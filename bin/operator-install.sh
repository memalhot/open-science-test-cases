helm install rossoctl-operator \
  oci://ghcr.io/rossoctl/operator/operator-chart \
  --namespace rossoctl-system \
  --create-namespace \
  --set controllerManager.container.image.tag=0.3.0 \
  --kube-as-user=system:
  
