#!/bin/bash
# Operator & platform readiness checks for RHOAI 3.x.
#
# The RHOAI 2.x version of this lives in ./checks.sh. Run that one against a
# 2.x cluster: several things it requires were removed in 3.0 (ModelMesh,
# CodeFlare, the Service Mesh control plane) and several things 3.x requires
# did not exist in 2.x (the Data Science Gateway, Kubeflow Trainer), so each
# script reports a pile of meaningless failures against the other generation.
set -euo pipefail

PASSED=0
FAILED=0
SKIPPED=0

pass() { echo "PASS ($*)"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL ($*)" >&2; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP ($*)"; SKIPPED=$((SKIPPED + 1)); }

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

check_deployment() {
  local name="$1" namespace="$2" label="$3"

  echo ""
  echo "--- ${label}: ${name} (${namespace}) ---"

  local available
  available=$(oc get deployment "${name}" -n "${namespace}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

  if [[ "${available}" == "True" ]]; then
    pass "Available"
  else
    fail "Available=${available:-not found}"
  fi
}

# Same as check_deployment, but a missing Deployment is a SKIP rather than a
# FAIL. For operators RHOAI 3.x no longer depends on but that clusters
# upgraded from 2.x usually still have installed.
check_deployment_optional() {
  local name="$1" namespace="$2" label="$3" why="$4"

  echo ""
  echo "--- ${label}: ${name} (${namespace}) [optional] ---"

  local available
  available=$(oc get deployment "${name}" -n "${namespace}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

  if [[ "${available}" == "True" ]]; then
    pass "Available"
  elif [[ -z "${available}" ]]; then
    skip "not installed — ${why}"
  else
    fail "installed but Available=${available}"
  fi
}

check_pods_running() {
  local label_selector="$1" namespace="$2" description="$3"

  echo ""
  echo "--- ${description} (${namespace}, ${label_selector}) ---"

  local running_count
  running_count=$(oc get pods -n "${namespace}" -l "${label_selector}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

  if [[ "${running_count}" -gt 0 ]]; then
    pass "${running_count} pod(s) running"
  else
    fail "no running pods found"
  fi
}

check_csvs() {
  echo ""
  echo "=== ClusterServiceVersions ==="

  local csvs
  csvs=$(oc get csv -A -l '!olm.copiedFrom' \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")

  if [[ -z "${csvs}" ]]; then
    echo ""
    echo "--- ClusterServiceVersions ---"
    fail "no ClusterServiceVersions found"
    return
  fi

  while IFS='|' read -r ns name phase; do
    [[ -z "${name}" ]] && continue

    echo ""
    echo "--- CSV: ${name} (${ns}) ---"

    if [[ "${phase}" == "Succeeded" ]]; then
      pass "phase: Succeeded"
    else
      fail "phase: ${phase:-unknown}"
    fi
  done <<< "${csvs}"
}

# ---------------------------------------------------------------------------
# RHOAI platform
# ---------------------------------------------------------------------------

check_rhoai_version() {
  echo ""
  echo "--- RHOAI operator version ---"

  local csv major
  csv=$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -oE '^rhods-operator\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f2-)
  major="${csv%%.*}"

  if [[ -z "${csv}" ]]; then
    fail "no rhods-operator CSV found"
  elif [[ "${major}" == "3" ]]; then
    pass "rhods-operator ${csv}"
  else
    fail "rhods-operator ${csv} — this is the RHOAI 3.x script, run ./checks.sh instead"
  fi
}

check_dsc_phase() {
  echo ""
  echo "--- DataScienceCluster: phase ---"

  local phase
  phase=$(oc get datasciencecluster -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

  if [[ "${phase}" == "Ready" ]]; then
    pass "phase: Ready"
  else
    fail "phase: ${phase:-not found}"
  fi
}

# The DSCInitialization owns everything that is cluster-wide rather than
# per-component: the gateway, monitoring, the application namespaces. A DSC
# that reports Ready on top of a Degraded DSCI is still a broken install.
check_dsci_conditions() {
  echo ""
  echo "=== DSCInitialization ==="

  local cond want
  for cond in "Available:True" "ReconcileComplete:True" "Degraded:False" "Upgradeable:True"; do
    want="${cond##*:}"
    cond="${cond%%:*}"

    echo ""
    echo "--- DSCI: ${cond} ---"

    local status
    status=$(oc get dscinitialization -A \
      -o jsonpath="{.items[0].status.conditions[?(@.type==\"${cond}\")].status}" 2>/dev/null || echo "")

    if [[ "${status}" == "${want}" ]]; then
      pass "${cond}: ${status}"
    else
      fail "${cond}: ${status:-not found} (want ${want})"
    fi
  done

  # Observability is opt-in: the DSCI reports these False with reason
  # *NotConfigured when it simply was not asked for. Report, do not grade.
  echo ""
  echo "--- DSCI: observability (informational) ---"
  oc get dscinitialization -A -o jsonpath='{range .items[0].status.conditions[*]}{.type}{"="}{.status}{" ("}{.reason}{")"}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(MonitoringReady|MonitoringStackAvailable|TempoAvailable|AlertingAvailable)=' \
    | sed 's/^/  /' || echo "  (none reported)"
}

# RHOAI 3.x renamed and removed component conditions, so a bare
# "is <X>Ready True?" is wrong twice over: it fails on components the cluster
# was deliberately configured without, and it fails on components that no
# longer exist under that name. Grade against spec.components instead —
# Managed/Unmanaged must be Ready, Removed is a SKIP.
check_dsc_component() {
  local spec_key="$1" condition_type="$2" label="$3"

  echo ""
  echo "--- DSC Component: ${label} (${condition_type}) ---"

  local mgmt status
  mgmt=$(oc get datasciencecluster -A \
    -o jsonpath="{.items[0].spec.components.${spec_key}.managementState}" 2>/dev/null || echo "")
  status=$(oc get datasciencecluster -A \
    -o jsonpath="{.items[0].status.conditions[?(@.type==\"${condition_type}\")].status}" 2>/dev/null || echo "")

  case "${mgmt}" in
    Removed)
      skip "managementState: Removed"
      ;;
    "")
      skip "not present in spec.components.${spec_key} on this RHOAI build"
      ;;
    *)
      if [[ "${status}" == "True" ]]; then
        pass "${mgmt}, ${condition_type}: True"
      else
        fail "${mgmt} but ${condition_type}: ${status:-not found}"
      fi
      ;;
  esac
}

# Serving a model through the dashboard, the UIs, or any route at all goes
# through the Data Science Gateway in 3.x. It replaces the per-component
# routes (and, for KServe, the Service Mesh ingress) that 2.x used.
check_data_science_gateway() {
  echo ""
  echo "=== Data Science Gateway ==="

  echo ""
  echo "--- GatewayConfig: Ready ---"
  local gw_ready domain
  gw_ready=$(oc get gatewayconfig default-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  domain=$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}' 2>/dev/null || echo "")
  if [[ "${gw_ready}" == "True" ]]; then
    pass "Ready: True, domain: ${domain:-unset}"
  else
    fail "Ready: ${gw_ready:-not found}"
  fi

  echo ""
  echo "--- Gateway: data-science-gateway (openshift-ingress) Programmed ---"
  local programmed
  programmed=$(oc get gateway data-science-gateway -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [[ "${programmed}" == "True" ]]; then
    pass "Programmed: True"
  else
    fail "Programmed: ${programmed:-not found}"
  fi

  check_pods_running "app=kube-auth-proxy" "openshift-ingress" "Gateway auth proxy"

  echo ""
  echo "--- Gateway route reachable ---"
  local host code
  host=$(oc get route data-science-gateway -n openshift-ingress \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -z "${host}" ]]; then
    fail "no route data-science-gateway in openshift-ingress"
  else
    # Unauthenticated, so anything that is not a connection failure means the
    # gateway is serving: 200/302/403 are all fine, 000 and 5xx are not.
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/" 2>/dev/null || echo "000")
    if [[ "${code}" =~ ^(2|3|4)[0-9][0-9]$ ]]; then
      pass "https://${host}/ -> ${code}"
    else
      fail "https://${host}/ -> ${code:-no response}"
    fi
  fi
}

# The DSC conditions say a component reconciled; these say its controller is
# actually up. A controller that CrashLoopBackOffs after a successful
# reconcile leaves the DSC reporting Ready.
check_component_controllers() {
  echo ""
  echo "=== RHOAI Component Controllers ==="

  local ns="${RHOAI_APPS_NAMESPACE:-redhat-ods-applications}"

  check_deployment "rhods-dashboard"                      "${ns}" "Dashboard"
  check_deployment "workbenches-operator"                 "${ns}" "Workbenches"
  check_deployment "odh-notebook-controller-manager"      "${ns}" "Notebook controller"
  check_deployment "kserve-controller-manager"            "${ns}" "KServe"
  check_deployment "odh-model-controller"                 "${ns}" "ODH model controller"
  check_deployment "llmisvc-controller-manager"           "${ns}" "LLMInferenceService controller"
  check_deployment "kuberay-operator"                     "${ns}" "KubeRay"
  check_deployment "kubeflow-trainer-controller-manager"  "${ns}" "Kubeflow Trainer"
  check_deployment "data-science-pipelines-operator-controller-manager" "${ns}" "AI Pipelines"
  check_deployment "trustyai-service-operator-controller-manager"       "${ns}" "TrustyAI"
}

# Kueue is Unmanaged by default in 3.x: the Red Hat Kueue operator owns the
# controller and RHOAI only wires up queues. Grade the operator's controller,
# not the RHOAI component's DeploymentsAvailable condition — that one is
# False-by-design when RHOAI deploys nothing itself.
check_kueue() {
  echo ""
  echo "=== Kueue ==="

  check_deployment "kueue-controller-manager" "openshift-kueue-operator" "Kueue controller"

  echo ""
  echo "--- Kueue component: phase ---"
  local phase
  phase=$(oc get kueue -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [[ "${phase}" == "Ready" ]]; then
    pass "phase: Ready"
  else
    fail "phase: ${phase:-not found}"
  fi
}

# The serving CRDs the model-serving/ scripts submit against. A component can
# report Ready while the API you are about to post to is not served.
check_served_apis() {
  echo ""
  echo "=== Served APIs ==="

  local api
  for api in \
    "inferenceservices.serving.kserve.io:KServe InferenceService" \
    "llminferenceservices.serving.kserve.io:KServe LLMInferenceService" \
    "rayclusters.ray.io:KubeRay RayCluster" \
    "trainjobs.trainer.kubeflow.org:Kubeflow Trainer TrainJob" \
    "notebooks.kubeflow.org:Workbenches Notebook" \
    "hardwareprofiles.infrastructure.opendatahub.io:Hardware profiles" \
  ; do
    local crd="${api%%:*}" label="${api#*:}"

    echo ""
    echo "--- API: ${label} (${crd}) ---"
    if oc get crd "${crd}" >/dev/null 2>&1; then
      pass "served"
    else
      fail "CRD not found"
    fi
  done
}

# KServe's LLMInferenceService reports its optional add-ons as failed
# preconditions. Connectivity Link and LeaderWorkerSet are separate operators
# you install only if you want gateway-routed or wide-EP disaggregated
# serving, so a False here is a statement of fact, not a regression.
check_llmisvc_dependencies() {
  echo ""
  echo "--- LLMInferenceService optional dependencies (informational) ---"

  local out
  out=$(oc get datasciencecluster -A \
    -o jsonpath='{range .items[0].status.conditions[?(@.reason=="PreConditionFailed")]}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null || echo "")

  if [[ -z "${out}" ]]; then
    echo "  all LLMInferenceService dependencies satisfied"
  else
    echo "${out}" | sed 's/^/  /'
    echo "  (install Red Hat Connectivity Link / LeaderWorkerSet only if you need those paths)"
  fi
}

# ---------------------------------------------------------------------------
# Hardware
# ---------------------------------------------------------------------------

check_cluster_policy() {
  echo ""
  echo "--- GPU ClusterPolicy: state ---"

  local state
  state=$(oc get clusterpolicy -A -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "")

  if [[ "${state}" == "ready" ]]; then
    pass "state: ready"
  else
    fail "state: ${state:-not found}"
  fi
}

check_nfd_instance() {
  echo ""
  echo "--- NFD Instance: Available ---"

  local available
  available=$(oc get nodefeaturediscovery -A \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

  if [[ "${available}" == "True" ]]; then
    pass "Available: True"
  else
    fail "Available: ${available:-not found}"
  fi
}

check_gpu_node_labels() {
  echo ""
  echo "=== GPU Node Labels ==="

  local gpu_nodes
  gpu_nodes=$(oc get nodes -l nvidia.com/gpu.present=true \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "${gpu_nodes}" ]]; then
    echo ""
    echo "--- GPU Node Labels ---"
    fail "no nodes with nvidia.com/gpu.present=true found"
    return
  fi

  for node in ${gpu_nodes}; do
    echo ""
    echo "--- Node: ${node} ---"

    local nfd_ok=false
    if oc get node "${node}" -o jsonpath='{.metadata.labels}' 2>/dev/null \
        | grep -qE '"feature\.node\.kubernetes\.io/pci-10de\.present"|"feature\.node\.kubernetes\.io/pci-0302_10de\.present"'; then
      nfd_ok=true
    fi

    if ${nfd_ok}; then
      echo "  NFD label: present"
    else
      echo "  NFD label: MISSING (expected pci-10de.present or pci-0302_10de.present)" >&2
    fi

    local gpu_count
    gpu_count=$(oc get node "${node}" \
      -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}' 2>/dev/null || echo "")

    if ${nfd_ok} && [[ -n "${gpu_count}" ]]; then
      echo "  nvidia.com/gpu.count=${gpu_count}"
      pass "labelled"
    else
      [[ -z "${gpu_count}" ]] && echo "  nvidia.com/gpu.count: MISSING" >&2
      fail "labels incomplete"
    fi
  done
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

# OSSM 3 replaced the ServiceMeshControlPlane CR (maistra.io) with Istio
# (sailoperator.io), and RHOAI 3.x KServe no longer needs a mesh at all — it
# serves raw Deployments behind the Data Science Gateway. So: the operator
# must be healthy if installed, and any Istio CR that does exist must be
# healthy, but having neither is a supported configuration.
check_service_mesh() {
  echo ""
  echo "=== Service Mesh (OSSM 3) ==="

  check_deployment_optional "servicemesh-operator3" "openshift-operators" \
    "OpenShift Service Mesh 3" "RHOAI 3.x KServe serves raw Deployments and does not require a mesh"

  echo ""
  echo "--- Istio control plane (sailoperator.io) ---"
  if ! oc get crd istios.sailoperator.io >/dev/null 2>&1; then
    skip "Istio CRD not installed — no mesh on this cluster"
    return
  fi

  local istios
  istios=$(oc get istios -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null || echo "")

  if [[ -z "${istios}" ]]; then
    skip "no Istio CR — RHOAI 3.x does not create one"
    return
  fi

  while IFS='|' read -r name ready; do
    [[ -z "${name}" ]] && continue
    if [[ "${ready}" == "True" ]]; then
      pass "Istio/${name} Ready: True"
    else
      fail "Istio/${name} Ready: ${ready:-not found}"
    fi
  done <<< "${istios}"
}

# Leftovers from a 2.x cluster. Nothing depends on them in 3.x; they are
# reported so an upgraded cluster's empty knative-serving and istio-system
# namespaces do not look like a failed component.
report_rhoai2_leftovers() {
  echo ""
  echo "=== RHOAI 2.x Leftovers (informational) ==="
  echo ""

  local ns count
  for ns in knative-serving knative-eventing istio-system; do
    if oc get namespace "${ns}" >/dev/null 2>&1; then
      count=$(oc get pods -n "${ns}" -o name 2>/dev/null | wc -l)
      echo "  namespace ${ns}: present, ${count} pod(s)"
    else
      echo "  namespace ${ns}: absent"
    fi
  done

  echo ""
  echo "  Removed in RHOAI 3.x — do not expect these to pass:"
  echo "    ModelMeshServing   (removed; use KServe)"
  echo "    CodeFlare          (removed; use Kueue + KubeRay + Kubeflow Trainer)"
  echo "    TrainingOperator   (removed; use Kubeflow Trainer / TrainJob)"
  echo "    DataSciencePipelines -> renamed AIPipelines"
  echo "    ServiceMeshControlPlane (maistra.io) -> Istio (sailoperator.io), and not required"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "========================================="
echo "  RHOAI 3.x Operator & Platform Checks"
echo "========================================="

echo ""
echo "=== Operator Health ==="

check_rhoai_version
check_deployment "rhods-operator" "redhat-ods-operator" "Red Hat OpenShift AI"
check_deployment "nfd-controller-manager" "openshift-nfd" "Node Feature Discovery"
check_deployment "gpu-operator" "nvidia-gpu-operator" "NVIDIA GPU Operator"
check_deployment "nvidia-network-operator-controller-manager" "nvidia-network-operator" "NVIDIA Network Operator"
check_deployment "maintenance-operator-controller-manager" "nvidia-maintenance-operator" "NVIDIA Maintenance Operator"
check_deployment_optional "knative-openshift" "openshift-serverless" \
  "OpenShift Serverless" "RHOAI 3.x KServe defaults to raw deployment; Serverless is only needed for Knative-mode serving"

check_csvs

echo ""
echo "=== Configuration & Component Readiness ==="

check_dsc_phase
check_cluster_policy
check_nfd_instance

check_dsci_conditions

echo ""
echo "=== DataScienceCluster Components ==="

check_dsc_component "dashboard"      "DashboardReady"       "Dashboard"
check_dsc_component "workbenches"    "WorkbenchesReady"     "Workbenches"
check_dsc_component "aipipelines"    "AIPipelinesReady"     "AI Pipelines"
check_dsc_component "kserve"         "KserveReady"          "KServe"
check_dsc_component "ray"            "RayReady"             "Ray"
check_dsc_component "trainer"        "TrainerReady"         "Kubeflow Trainer"
check_dsc_component "trustyai"       "TrustyAIReady"        "TrustyAI"
check_dsc_component "kueue"          "KueueReady"           "Kueue"
check_dsc_component "modelregistry"  "ModelRegistryReady"   "Model Registry"
check_dsc_component "feastoperator"  "FeastOperatorReady"   "Feast"
check_dsc_component "llamastackoperator" "LlamaStackOperatorReady" "Llama Stack"

check_llmisvc_dependencies

check_component_controllers
check_kueue
check_served_apis
check_data_science_gateway

check_gpu_node_labels

echo ""
echo "=== Required Pods ==="

check_pods_running "app=nfd-worker" "openshift-nfd" "NFD Worker"
check_pods_running "app.kubernetes.io/component=nvidia-driver" "nvidia-gpu-operator" "NVIDIA GPU Driver"

echo ""
echo "=== Networking ==="

check_service_mesh

report_rhoai2_leftovers

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
