#!/bin/bash
###############################################################################
# diagnose-rhoai-images.sh
#
# Diagnostic script to understand how RHOAI images are pulled on a cluster.
# Works on: Linux, macOS, Windows (Git Bash / MINGW64)
#
# Prerequisites:
#   - oc CLI logged into the target cluster as cluster-admin
#   - bash (Git Bash on Windows is fine)
#
# Usage:
#   bash diagnose-rhoai-images.sh
###############################################################################

set -euo pipefail

echo "============================================================"
echo "  RHOAI Image Pull Diagnostic"
echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo "  User:    $(oc whoami 2>/dev/null || echo 'unknown')"
echo "  Time:    $(date)"
echo "============================================================"
echo ""

# -------------------------------------------------------------------
# Step 1: Find the RHOAI operator CSV
# -------------------------------------------------------------------
echo "=== STEP 1: RHOAI Operator CSV ==="
echo ""

CSV_NAME=$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i "rhods\|rhoai" | head -1)

if [ -z "$CSV_NAME" ]; then
  echo "WARNING: Could not find RHOAI CSV in redhat-ods-operator namespace."
  echo "Trying all namespaces..."
  CSV_NAME=$(oc get csv -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i "rhods\|rhoai" | head -1)
fi

if [ -n "$CSV_NAME" ]; then
  echo "Found CSV: $CSV_NAME"
  echo ""
  echo "--- relatedImages count ---"
  RELATED_COUNT=$(oc get csv "$CSV_NAME" -n redhat-ods-operator -o jsonpath='{.spec.relatedImages}' 2>/dev/null | tr ',' '\n' | grep -c "image" || echo "0")
  echo "Total relatedImages entries: $RELATED_COUNT"
  echo ""
  echo "--- First 20 relatedImages (name -> registry) ---"
  oc get csv "$CSV_NAME" -n redhat-ods-operator \
    -o jsonpath='{range .spec.relatedImages[*]}{.name}{"\t"}{.image}{"\n"}{end}' 2>/dev/null | head -20
  echo ""
  echo "(Full list saved to: /tmp/rhoai-related-images.txt)"
  oc get csv "$CSV_NAME" -n redhat-ods-operator \
    -o jsonpath='{range .spec.relatedImages[*]}{.name}{"\t"}{.image}{"\n"}{end}' 2>/dev/null > /tmp/rhoai-related-images.txt || true
else
  echo "ERROR: No RHOAI CSV found. Is the operator installed?"
fi

echo ""
echo "============================================================"

# -------------------------------------------------------------------
# Step 2: Pods in redhat-ods-applications and their images
# -------------------------------------------------------------------
echo "=== STEP 2: Pod Status in redhat-ods-applications ==="
echo ""

echo "--- Pod summary (Status counts) ---"
oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | sort -rn
echo ""

echo "--- Pods NOT Running ---"
oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep -v "Running\|Completed" || echo "  All pods are Running!"
echo ""

echo "--- Images referenced by failing pods ---"
FAILING_PODS=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep -v "Running\|Completed" | awk '{print $1}')
if [ -n "$FAILING_PODS" ]; then
  for POD in $FAILING_PODS; do
    IMAGES=$(oc get pod "$POD" -n redhat-ods-applications -o jsonpath='{range .spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null)
    echo "  Pod: $POD"
    echo "  Images: $IMAGES"
    echo ""
  done
else
  echo "  No failing pods found."
fi

echo "============================================================"

# -------------------------------------------------------------------
# Step 3: Image pull errors (events)
# -------------------------------------------------------------------
echo "=== STEP 3: Recent Image Pull Errors ==="
echo ""

echo "--- Failed pull events (last 20) ---"
oc get events -n redhat-ods-applications --field-selector reason=Failed --sort-by='.lastTimestamp' 2>/dev/null | grep -i "pull\|image" | tail -20 || echo "  No Failed pull events found."
echo ""

echo "--- BackOff events ---"
oc get events -n redhat-ods-applications --field-selector reason=BackOff --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "  No BackOff events found."

echo ""
echo "============================================================"

# -------------------------------------------------------------------
# Step 4: ImageDigestMirrorSet and ImageTagMirrorSet rules
# -------------------------------------------------------------------
echo "=== STEP 4: Mirror Rules (IDMS + ITMS) ==="
echo ""

echo "--- ImageDigestMirrorSet ---"
oc get imagedigestmirrorset -o jsonpath='{range .items[*]}Name: {.metadata.name}{"\n"}{range .spec.imageDigestMirrors[*]}  Source: {.source}{"\n"}  Mirror: {.mirrors[0]}{"\n"}{end}---{"\n"}{end}' 2>/dev/null || echo "  None found."
echo ""

echo "--- ImageTagMirrorSet ---"
oc get imagetagmirrorset -o jsonpath='{range .items[*]}Name: {.metadata.name}{"\n"}{range .spec.imageTagMirrors[*]}  Source: {.source}{"\n"}  Mirror: {.mirrors[0]}{"\n"}{end}---{"\n"}{end}' 2>/dev/null || echo "  None found."
echo ""

echo "--- ImageContentSourcePolicy (deprecated, but may exist) ---"
oc get imagecontentsourcepolicy -o jsonpath='{range .items[*]}Name: {.metadata.name}{"\n"}{range .spec.repositoryDigestMirrors[*]}  Source: {.source}{"\n"}  Mirror: {.mirrors[0]}{"\n"}{end}---{"\n"}{end}' 2>/dev/null || echo "  None found."

echo ""
echo "============================================================"

# -------------------------------------------------------------------
# Step 5: Unique registries in use
# -------------------------------------------------------------------
echo "=== STEP 5: Registries in Use (cluster-wide) ==="
echo ""

echo "--- Unique registries from ALL running pods ---"
oc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | \
  sed 's|@sha256:.*||' | awk -F/ '{if(NF>=2) print $1; else print "docker.io"}' | sort -u
echo ""

echo "--- Registries from redhat-ods-applications pods ---"
oc get pods -n redhat-ods-applications -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | \
  sed 's|@sha256:.*||' | sort -u
echo ""

echo "============================================================"

# -------------------------------------------------------------------
# Step 6: Describe one failing pod for full error detail
# -------------------------------------------------------------------
echo "=== STEP 6: Detailed Error from First Failing Pod ==="
echo ""

FIRST_FAILING=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep "ImagePullBackOff\|ErrImagePull" | awk '{print $1}' | head -1)
if [ -n "$FIRST_FAILING" ]; then
  echo "Pod: $FIRST_FAILING"
  echo ""
  echo "--- Events for this pod ---"
  oc describe pod "$FIRST_FAILING" -n redhat-ods-applications 2>/dev/null | sed -n '/Events:/,$ p' | head -30
else
  echo "  No pods in ImagePullBackOff/ErrImagePull state."
fi

echo ""
echo "============================================================"

# -------------------------------------------------------------------
# Step 7: Check if RHOAI images are digest-based or tag-based
# -------------------------------------------------------------------
echo "=== STEP 7: Digest vs Tag analysis ==="
echo ""

echo "--- Images using digest (@sha256:) ---"
DIGEST_COUNT=$(oc get pods -n redhat-ods-applications -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep -c "@sha256:" || echo "0")
echo "  Count: $DIGEST_COUNT"

echo ""
echo "--- Images using tags (no @sha256:) ---"
TAG_IMAGES=$(oc get pods -n redhat-ods-applications -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep -v "@sha256:" | sort -u)
TAG_COUNT=$(echo "$TAG_IMAGES" | grep -c "." || echo "0")
echo "  Count: $TAG_COUNT"
if [ -n "$TAG_IMAGES" ]; then
  echo "  WARNING: Tag-based images are NOT redirected by ImageDigestMirrorSet!"
  echo "  These need an ImageTagMirrorSet or manual mirroring:"
  echo "$TAG_IMAGES" | sed 's/^/    /'
fi

echo ""
echo "============================================================"
echo ""
echo "DIAGNOSIS COMPLETE."
echo ""
echo "Summary:"
echo "  - If Step 3 shows 'manifest unknown' errors:"
echo "    → The image digest exists in IDMS but hasn't been pushed to the mirror"
echo "    → Fix: Mirror the missing images with oc-mirror or podman pull/push"
echo ""
echo "  - If Step 3 shows 'unauthorized' errors:"
echo "    → The pull secret for the mirror registry is missing or expired"
echo "    → Fix: Update the global pull secret"
echo ""
echo "  - If Step 7 shows tag-based images not covered by ITMS:"
echo "    → IDMS only works for digest refs; tags need ImageTagMirrorSet"
echo "    → Fix: Create an ImageTagMirrorSet for those sources"
echo ""
echo "  - If Step 4 shows a broad source (e.g., 'registry.redhat.io/rhoai')"
echo "    but the mirror is incomplete:"
echo "    → All RHOAI pulls go to mirror, but mirror is missing images"
echo "    → Fix: Re-run oc mirror with current RHOAI 3.4 imageset-config"
echo "============================================================"
