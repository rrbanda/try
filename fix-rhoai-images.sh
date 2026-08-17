#!/bin/bash
###############################################################################
# fix-rhoai-images.sh
#
# Quickest fix: copy ONLY the failing RHOAI 3.4.3 images from registry.redhat.io
# directly to the internal mirror using skopeo (no local disk needed).
#
# Prerequisites:
#   - Run on a machine that can reach BOTH:
#     1. registry.redhat.io (internet)
#     2. binaryrepo.nam.nsroot.net (internal)
#   - skopeo installed (or podman as fallback)
#   - Logged into both registries:
#     podman login registry.redhat.io
#     podman login binaryrepo.nam.nsroot.net
#
# Usage:
#   bash fix-rhoai-images.sh
###############################################################################

set -euo pipefail

MIRROR_REGISTRY="binaryrepo.nam.nsroot.net/docker-cto-dev-local/cti-svcs-orion-177398/rhoai-temp"

# These are the failing images from the cluster diagnostic (Step 3 output).
# Update this list with the actual output from:
#   oc get pods -n redhat-ods-applications -o jsonpath='{range .items[?(@.status.phase!="Running")]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
FAILING_IMAGES=(
"registry.redhat.io/rhoai/odh-dashboard-rhel9@sha256:1909a81998be53fe236a3f8c98965/f6ba0a9dcef74bb245f18ca047d5da421f"
"registry.redhat.io/rhoai/odh-data-science-pipelines-operator-controller-rhel9@sha256:REPLACE_WITH_ACTUAL_DIGEST"
"registry.redhat.io/rhoai/odh-feast-operator-rhel9@sha256:b4e5489388ceac8028b14f8d5315c34f842d1f6b20840a7d574338a93e0fa0af"
"registry.redhat.io/rhoai/odh-kserve-controller-rhel9@sha256:e046443ba557cb4c6c1dec0edb366752f7be0ba146caa2a341ee473c67443a99"
"registry.redhat.io/rhoai/odh-kf-notebook-controller-rhel9@sha256:c5448747dfb4d6c8c6169c65baa3c1e903c1b3d9c7d497bf45c65ee773481935"
"registry.redhat.io/rhoai/odh-kuberay-operator-controller-rhel9@sha256:2067376794zc887/be4738a5aa338d23a947e7d32748cb1bbb55fc637721312l"
"registry.redhat.io/rhoai/odh-llama-stack-k8s-operator-rhel9@sha256:9eb6767db203c1e10aabd695065777763346z2e148d0d40bc951f8c2d5229023"
"registry.redhat.io/rhoai/odh-kserve-llmisvc-controller-rhel9@sha256:049522704714bed687f646b660d3b872fce966d01579b3527cc92cdb6ba7bdd7"
"registry.redhat.io/rhoai/odh-mlflow-operator-rhel9@sha256:4bcfdd1bb9b0103aeb072315d9130644fd3f3eb24fa8f7752c7863a89c27df59b"
"registry.redhat.io/rhoai/odh-model-registry-operator-rhel9@sha256:ae7fec9f9ff4399069ac44397b88554d366ed1c3e4f1c1a37d02ef777974d6d6"
"registry.redhat.io/rhoai/odh-model-serving-api-rhel9@sha256:ef5837f9ddd7acd0376fd1386fdc2e2bde2e9fe4091aa6533df6207209309"
"registry.redhat.io/rhoai/odh-notebook-controller-rhel9@sha256:c90f6d78238893945c61e6d91fdef3b692d0360c91f105a6d4ad9b7cb4d4aa"
"registry.redhat.io/rhoai/odh-model-controller-rhel9@sha256:37be2ec73a8424182e903a605c4503f8e6c759a8cc105b1e2ca4ddafad1331dd3"
"registry.redhat.io/rhoai/odh-trustyai-service-operator-rhel9@sha256:5e0b249f7f4d3037fe9a4007cd8898b27a09269606lfb9b5ff02eb1efc7436389"
)

echo "============================================================"
echo "  RHOAI 3.4.3 Image Mirror Fix"
echo "  Target: ${MIRROR_REGISTRY}"
echo "  Images: ${#FAILING_IMAGES[@]}"
echo "============================================================"
echo ""

# Check if skopeo is available (preferred — no local storage needed)
if command -v skopeo &>/dev/null; then
  COPY_CMD="skopeo"
  echo "Using skopeo (direct registry-to-registry copy, no local disk needed)"
else
  COPY_CMD="podman"
  echo "skopeo not found, falling back to podman (requires local disk for pull/push)"
fi

echo ""
echo "--- Verifying registry access ---"
skopeo login --get-login registry.redhat.io &>/dev/null && echo "  registry.redhat.io: OK" || echo "  registry.redhat.io: NOT LOGGED IN — run: podman login registry.redhat.io"
skopeo login --get-login binaryrepo.nam.nsroot.net &>/dev/null && echo "  binaryrepo: OK" || echo "  binaryrepo: NOT LOGGED IN — run: podman login binaryrepo.nam.nsroot.net"
echo ""

SUCCESS=0
FAILED=0
SKIPPED=0

for IMAGE in "${FAILING_IMAGES[@]}"; do
  # Skip placeholder entries
  if [[ "${IMAGE}" == *"REPLACE_WITH"* ]]; then
    echo "SKIP: ${IMAGE} (placeholder — replace with actual digest)"
    ((SKIPPED++))
    continue
  fi

  # Extract relative path (remove registry.redhat.io/ prefix)
  REL_PATH=$(echo "${IMAGE}" | sed 's|registry.redhat.io/||')
  TARGET="${MIRROR_REGISTRY}/${REL_PATH}"

  echo "--- Copying: ${REL_PATH} ---"

  if [ "${COPY_CMD}" = "skopeo" ]; then
    if skopeo copy "docker://${IMAGE}" "docker://${TARGET}" --all 2>&1; then
      echo "  OK"
      ((SUCCESS++))
    else
      echo "  FAILED — trying without --all flag..."
      if skopeo copy "docker://${IMAGE}" "docker://${TARGET}" 2>&1; then
        echo "  OK (single arch)"
        ((SUCCESS++))
      else
        echo "  FAILED"
        ((FAILED++))
      fi
    fi
  else
    # Podman fallback
    if podman pull "${IMAGE}" && podman push "${IMAGE}" "docker://${TARGET}"; then
      echo "  OK"
      ((SUCCESS++))
    else
      echo "  FAILED"
      ((FAILED++))
    fi
  fi
  echo ""
done

echo "============================================================"
echo "  Results: ${SUCCESS} copied, ${FAILED} failed, ${SKIPPED} skipped"
echo "============================================================"
echo ""

if [ ${FAILED} -gt 0 ]; then
  echo "Some images failed. Check:"
  echo "  1. Are you logged into both registries?"
  echo "  2. Does the mirror path exist in Artifactory?"
  echo "  3. Are the digests correct (copy from cluster output)?"
  echo ""
fi

echo "Once images are in the mirror, pods will auto-recover (kubelet retries every ~5 min)."
echo "Monitor with: oc get pods -n redhat-ods-applications -w"
