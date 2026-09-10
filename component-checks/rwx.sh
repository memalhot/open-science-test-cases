#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-mm-test}"
PVC_NAME="${PVC_NAME:-rwx-test}"
STORAGE_CLASS="${STORAGE_CLASS:-pure-fb-nfsv4}"
SIZE="${SIZE:-1Gi}"

POD1="rwx-test-1"
POD2="rwx-test-2"

echo "Using namespace: $NAMESPACE"
echo "Using storage class: $STORAGE_CLASS"

echo
echo "Creating RWX PVC..."

cat <<EOF | oc apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: ${SIZE}
  storageClassName: ${STORAGE_CLASS}
EOF

echo
echo "Waiting for PVC to bind..."
oc wait \
  --for=jsonpath='{.status.phase}'=Bound \
  pvc/"$PVC_NAME" \
  -n "$NAMESPACE" \
  --timeout=120s

echo
echo "Creating test pods..."

cat <<EOF | oc apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD1}
spec:
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sh", "-c"]
      args:
        - |
          echo "hello from pod 1" > /shared/pod1.txt
          sleep infinity
      volumeMounts:
        - name: shared
          mountPath: /shared
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD2}
spec:
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sh", "-c"]
      args:
        - |
          echo "hello from pod 2" > /shared/pod2.txt
          sleep infinity
      volumeMounts:
        - name: shared
          mountPath: /shared
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF

echo
echo "Waiting for pods to become Ready..."

oc wait \
  --for=condition=Ready \
  pod/"$POD1" \
  -n "$NAMESPACE" \
  --timeout=180s

oc wait \
  --for=condition=Ready \
  pod/"$POD2" \
  -n "$NAMESPACE" \
  --timeout=180s

echo
echo "Pod placement:"
oc get pods "$POD1" "$POD2" \
  -n "$NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'

echo
echo "Files visible from pod 1:"
oc exec -n "$NAMESPACE" "$POD1" -- sh -c '
  ls -l /shared
  echo
  echo "pod1.txt:"
  cat /shared/pod1.txt
  echo
  echo "pod2.txt:"
  cat /shared/pod2.txt
'

echo
echo "Writing shared-test.txt from pod 1..."
oc exec -n "$NAMESPACE" "$POD1" -- \
  sh -c 'echo "written by pod 1" > /shared/shared-test.txt'

echo
echo "Reading shared-test.txt from pod 2..."
RESULT="$(oc exec -n "$NAMESPACE" "$POD2" -- cat /shared/shared-test.txt)"

echo "Result: $RESULT"

if [[ "$RESULT" == "written by pod 1" ]]; then
  echo
  echo "SUCCESS: RWX storage is working."
  echo "Both pods can access the same filesystem."
else
  echo
  echo "FAIL: pod 2 did not see the expected content."
  exit 1
fi