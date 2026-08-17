#!/bin/bash
###############################################################################
# fix-rhoai-images.sh
#
# Quickest fix for RHOAI 3.4.3 ImagePullBackOff in disconnected environments.
# Auto-discovers failing images from the cluster, then copies them from
# registry.redhat.io to the internal mirror using skopeo.
#
# USAGE (two modes):
#
#   Mode 1 — Run directly on a machine with both oc + skopeo + internet:
#     export MIRROR_REGISTRY="your-internal-registry.example.com/path"
#     oc login ...
#     bash fix-rhoai-images.sh
#
#   Mode 2 — Two machines (bastion for oc, jumpbox for skopeo):
#     # On bastion (has oc access):
#     bash fix-rhoai-images.sh --list-only > failing-images.txt
#     # Copy failing-images.txt to jumpbox, then:
#     bash fix-rhoai-images.sh --from-file failing-images.txt
#
# Prerequisites:
#   - skopeo installed (or podman as fallback)
#   - Logged into both registries:
#       podman login registry.redhat.io
#       podman login $MIRROR_REGISTRY
#   - For auto-discovery: oc CLI logged into the cluster
#
# Compatible with: Linux, macOS, Windows (Git Bash)
###############################################################################

set -euo pipefail

# ========================== CONFIGURATION ==================================
# Set your internal mirror registry path.
# The script mirrors images as: $MIRROR_REGISTRY/rhoai/image-name@sha256:...
MIRROR_REGISTRY="${MIRROR_REGISTRY:-binaryrepo.nam.nsroot.net/docker-cto-dev-local/cti-svcs-orion-177398/rhoai-temp}"

# Namespace where RHOAI components run
RHOAI_NS="${RHOAI_NS:-redhat-ods-applications}"
# ===========================================================================

MODE="auto"
IMAGE_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --list-only)   MODE="list-only"; shift ;;
    --from-file)   MODE="from-file"; IMAGE_FILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--list-only | --from-file FILE]"
      echo ""
      echo "  --list-only    Only print failing images (for offline transfer)"
      echo "  --from-file F  Read image list from file instead of cluster"
      echo ""
      echo "Environment:"
      echo "  MIRROR_REGISTRY  Target registry path (required for copy)"
      echo "  RHOAI_NS         RHOAI namespace (default: redhat-ods-applications)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ========================== DISCOVER FAILING IMAGES =========================

discover_failing_images() {
  echo "--- Discovering failing images from cluster ---" >&2

  # Get images from pods that are NOT Running/Succeeded
  local images
  images=$(oc get pods -n "${RHOAI_NS}" -o json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
images = set()
for pod in data.get('items', []):
    phase = pod.get('status', {}).get('phase', '')
    if phase in ('Running', 'Succeeded'):
        continue
    # Check container statuses for ImagePullBackOff / ErrImagePull
    for cs in pod.get('status', {}).get('containerStatuses', []) + pod.get('status', {}).get('initContainerStatuses', []):
        waiting = cs.get('state', {}).get('waiting', {})
        if waiting.get('reason', '') in ('ImagePullBackOff', 'ErrImagePull', 'ErrImageNeverPull'):
            images.add(cs.get('image', ''))
    # Also grab from spec for pods stuck in Pending
    if phase == 'Pending':
        for c in pod.get('spec', {}).get('containers', []) + pod.get('spec', {}).get('initContainers', []):
            images.add(c.get('image', ''))
for img in sorted(images):
    if img and 'registry.redhat.io' in img:
        print(img)
" 2>/dev/null || \
    # Fallback if python3 is not available — use jsonpath
    oc get pods -n "${RHOAI_NS}" \
      -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"|"}{.image}{"\n"}{end}{end}' 2>/dev/null | \
      grep -E "^(ImagePullBackOff|ErrImagePull)" | cut -d'|' -f2 | sort -u)

  if [ -z "${images}" ]; then
    echo "No failing images found in ${RHOAI_NS}. Checking events..." >&2
    images=$(oc get events -n "${RHOAI_NS}" --field-selector reason=Failed \
      -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | \
      grep -oP 'registry\.redhat\.io/[^\s"]+' | sort -u)
  fi

  echo "${images}"
}

# ========================== GET IMAGE LIST ==================================

if [ "${MODE}" = "from-file" ]; then
  if [ ! -f "${IMAGE_FILE}" ]; then
    echo "ERROR: File not found: ${IMAGE_FILE}"
    exit 1
  fi
  IMAGES=$(grep -v '^#' "${IMAGE_FILE}" | grep -v '^\s*$' | sort -u)
  echo "Loaded $(echo "${IMAGES}" | wc -l | tr -d ' ') images from ${IMAGE_FILE}"
else
  IMAGES=$(discover_failing_images)

  if [ -z "${IMAGES}" ]; then
    echo "No failing images found. Cluster may be healthy or namespace wrong."
    echo "Set RHOAI_NS if your namespace differs from 'redhat-ods-applications'."
    exit 0
  fi

  IMAGE_COUNT=$(echo "${IMAGES}" | wc -l | tr -d ' ')
  echo "Found ${IMAGE_COUNT} failing image(s)"
fi

# ========================== LIST-ONLY MODE ==================================

if [ "${MODE}" = "list-only" ]; then
  echo ""
  echo "# Failing RHOAI images (copy this file to a machine with skopeo + internet)"
  echo "# Then run: bash fix-rhoai-images.sh --from-file THIS_FILE"
  echo ""
  echo "${IMAGES}"
  exit 0
fi

# ========================== COPY IMAGES =====================================

echo ""
echo "============================================================"
echo "  RHOAI Image Mirror Fix"
echo "  Source: registry.redhat.io"
echo "  Target: ${MIRROR_REGISTRY}"
echo "  Images: $(echo "${IMAGES}" | wc -l | tr -d ' ')"
echo "============================================================"
echo ""

# Prefer skopeo (direct copy, no local disk)
if command -v skopeo &>/dev/null; then
  TOOL="skopeo"
  echo "Using: skopeo (direct registry-to-registry, no local disk needed)"
elif command -v podman &>/dev/null; then
  TOOL="podman"
  echo "Using: podman (requires local disk for pull+push)"
else
  echo "ERROR: Neither skopeo nor podman found. Install one first."
  exit 1
fi

echo ""
echo "--- Verifying registry logins ---"
if [ "${TOOL}" = "skopeo" ]; then
  skopeo login --get-login registry.redhat.io >/dev/null 2>&1 && echo "  registry.redhat.io: OK" || { echo "  registry.redhat.io: NOT LOGGED IN"; echo "  Run: podman login registry.redhat.io"; exit 1; }
  MIRROR_HOST=$(echo "${MIRROR_REGISTRY}" | cut -d'/' -f1)
  skopeo login --get-login "${MIRROR_HOST}" >/dev/null 2>&1 && echo "  ${MIRROR_HOST}: OK" || { echo "  ${MIRROR_HOST}: NOT LOGGED IN"; echo "  Run: podman login ${MIRROR_HOST}"; exit 1; }
fi
echo ""

SUCCESS=0
FAILED=0
FAILED_LIST=""

while IFS= read -r IMAGE; do
  [ -z "${IMAGE}" ] && continue

  # Build target path:
  #   registry.redhat.io/rhoai/odh-dashboard-rhel9@sha256:abc123
  #   becomes: $MIRROR_REGISTRY/rhoai/odh-dashboard-rhel9@sha256:abc123
  REL_PATH="${IMAGE#registry.redhat.io/}"
  TARGET="${MIRROR_REGISTRY}/${REL_PATH}"

  # For display, truncate the digest
  SHORT="${REL_PATH%%@*}"
  DIGEST="${IMAGE##*@}"
  echo "[$(( SUCCESS + FAILED + 1 ))] ${SHORT}"
  echo "    digest: ${DIGEST:0:20}..."

  if [ "${TOOL}" = "skopeo" ]; then
    if skopeo copy --all "docker://${IMAGE}" "docker://${TARGET}" 2>/dev/null; then
      echo "    -> OK"
      ((SUCCESS++))
    elif skopeo copy "docker://${IMAGE}" "docker://${TARGET}" 2>/dev/null; then
      echo "    -> OK (single-arch)"
      ((SUCCESS++))
    else
      echo "    -> FAILED"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}\n  ${IMAGE}"
    fi
  else
    if podman pull "${IMAGE}" 2>/dev/null && podman tag "${IMAGE}" "${TARGET}" 2>/dev/null && podman push "${TARGET}" 2>/dev/null; then
      echo "    -> OK"
      ((SUCCESS++))
    else
      echo "    -> FAILED"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}\n  ${IMAGE}"
    fi
  fi
done <<< "${IMAGES}"

echo ""
echo "============================================================"
echo "  RESULTS: ${SUCCESS} copied | ${FAILED} failed"
echo "============================================================"

if [ ${FAILED} -gt 0 ]; then
  echo ""
  echo "Failed images:"
  echo -e "${FAILED_LIST}"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Verify registry logins: podman login registry.redhat.io && podman login ${MIRROR_HOST:-your-registry}"
  echo "  2. Verify the mirror path exists in Artifactory"
  echo "  3. Check if digests are correct (re-run with --list-only)"
fi

echo ""
echo "--- Next Steps ---"
echo "1. Pods will auto-retry pulling images (~5 min backoff)"
echo "2. Speed up recovery: oc delete pods -n ${RHOAI_NS} --field-selector status.phase=Pending"
echo "3. Monitor: oc get pods -n ${RHOAI_NS} -w"
echo ""
echo "Done."
