# for kagenti
helm install rossoctl-operator \
  oci://ghcr.io/rossoctl/operator/operator-chart \
  --namespace rossoctl-system \
  --create-namespace \
  --set controllerManager.container.image.tag=0.3.0 \
  --kube-as-user=system:

# for 

kubectl apply --server-side -k "github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.8.1"

oc set image deployment/training-operator  -n kubeflow training-operator=docker.io/kubeflow/training-operator:v1-04f9f13

oc rollout status deployment/training-operator -n kubeflow
  
