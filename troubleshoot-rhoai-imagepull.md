# Troubleshooting RHOAI ImagePullBackOff in Disconnected Environment

> **Problem:** RHOAI operator auto-upgraded (e.g., 3.4.2 → 3.4.3) but the new image
> digests haven't been mirrored to the internal registry. All RHOAI pods are in
> `ImagePullBackOff`.
>
> **Root Cause:** The `ImageDigestMirrorSet` redirects `registry.redhat.io/rhoai` to the
> internal mirror, but the mirror doesn't have the new 3.4.3 digests. The cluster is
> disconnected so fallback to `registry.redhat.io` also fails (DNS: no such host).
>
> **Impact on MCP:** None. MCP Gateway, Broker, and MCP Server are in separate namespaces
> managed by a different operator (`mcp-gateway.v0.7.1`). They continue to function normally.

---

## Step 1: Confirm the problem

```bash
# Check pod status in redhat-ods-applications:
oc get pods -n redhat-ods-applications --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn

# Check the RHOAI CSV status:
oc get csv -n redhat-ods-operator | grep rhods

# Expected: rhods-operator.3.4.3 with phase "Installing" (stuck)
```

---

## Step 2: Identify the exact error

```bash
# Get the first failing pod's events:
FAILING_POD=$(oc get pods -n redhat-ods-applications --no-headers | grep -m1 "ImagePull" | awk '{print $1}')
oc describe pod ${FAILING_POD} -n redhat-ods-applications | tail -20
```

Expected error pattern:
```
Mirrors also failed: [binaryrepo.../rhoai/<image>: manifest unknown]
pinging container registry registry.redhat.io: lookup registry.redhat.io: no such host
```

---

## Step 3: List all failing images

```bash
# Get unique images that can't be pulled:
oc get pods -n redhat-ods-applications -o jsonpath='{range .items[?(@.status.phase!="Running")]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
```

---

## Step 4: Understand the mirror redirect chain

```bash
# Show all ImageDigestMirrorSets and their sources:
oc get imagedigestmirrorset -o jsonpath='{range .items[*]}Name: {.metadata.name}{"\n"}{range .spec.imageDigestMirrors[*]}  Source: {.source} -> Mirror: {.mirrors[0]}{"\n"}{end}{"\n"}{end}'

# Show all ImageTagMirrorSets:
oc get imagetagmirrorset -o jsonpath='{range .items[*]}Name: {.metadata.name}{"\n"}{range .spec.imageTagMirrors[*]}  Source: {.source} -> Mirror: {.mirrors[0]}{"\n"}{end}{"\n"}{end}' 2>/dev/null || echo "None"
```

---

## Step 5: Check what the CSV declares vs what's mirrored

```bash
# Total images the operator needs:
CSV_NAME=$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep rhods | head -1)
echo "CSV: ${CSV_NAME}"

TOTAL=$(oc get csv ${CSV_NAME} -n redhat-ods-operator -o jsonpath='{.spec.relatedImages[*].name}' | wc -w)
echo "Total relatedImages: ${TOTAL}"

# Export full list for mirroring:
oc get csv ${CSV_NAME} -n redhat-ods-operator \
  -o jsonpath='{range .spec.relatedImages[*]}{.image}{"\n"}{end}' > /tmp/rhoai-images-needed.txt
echo "Image list saved to /tmp/rhoai-images-needed.txt (${TOTAL} images)"
```

---

## Step 6: Check imagePullPolicy (can cached images be used?)

```bash
oc get pods -n redhat-ods-applications -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].imagePullPolicy}{"\n"}{end}' | head -15
```

- `Always` → Node cache won't help; must mirror the images
- `IfNotPresent` → Cached images will be used if present on the node

---

## Step 7: Check if nodes have cached images

```bash
# Pick the node where a failing pod is scheduled:
NODE=$(oc get pod ${FAILING_POD} -n redhat-ods-applications -o jsonpath='{.spec.nodeName}')
echo "Node: ${NODE}"

# List cached RHOAI images on that node:
oc debug node/${NODE} -- chroot /host crictl images 2>/dev/null | grep -i "rhoai\|odh"
```

---

## Step 8: Check subscription/upgrade mechanism

```bash
# Try to find what triggered the upgrade:
oc get subscription.operators.coreos.com -n redhat-ods-operator 2>/dev/null || \
  oc get subscription.apps.open-cluster-management.io -A 2>/dev/null | grep -i rhoai

# Check InstallPlans:
oc get installplan -n redhat-ods-operator 2>/dev/null

# Check CatalogSource:
oc get catalogsource -n openshift-marketplace
```

---

## Fix Options

### Option A: Mirror the 3.4.3 images (recommended)

From a machine with internet access:

```bash
# Use the image list from Step 5:
# /tmp/rhoai-images-needed.txt

# For each image, pull and push to internal mirror:
MIRROR_REGISTRY="binaryrepo.nam.nsroot.net/docker-cto-dev-local/cti-svcs-orion-177398/rhoai-temp"

while read -r IMAGE; do
  # Extract the repo path after registry.redhat.io/
  REPO_PATH=$(echo "${IMAGE}" | sed 's|registry.redhat.io/||' | cut -d@ -f1)
  DIGEST=$(echo "${IMAGE}" | grep -o "@sha256:.*")

  echo "Mirroring: ${REPO_PATH}${DIGEST}"
  podman pull "${IMAGE}"
  podman push "${IMAGE}" "docker://${MIRROR_REGISTRY}/${REPO_PATH}${DIGEST}"
done < /tmp/rhoai-images-needed.txt
```

Or use `oc mirror` (simpler if imageset-config.yaml is available):

```bash
oc mirror -c imageset-config.yaml docker://${MIRROR_REGISTRY} --v2
```

### Option B: Disable the CatalogSource to prevent re-upgrade

```bash
# Find the catalog:
oc get catalogsource -n openshift-marketplace

# Disable it temporarily (stops OLM from re-applying 3.4.3):
oc patch catalogsource <name> -n openshift-marketplace --type=merge \
  -p '{"spec":{"image":"disabled-temporarily"}}'

# Delete the stuck CSV:
oc delete csv rhods-operator.3.4.3 -n redhat-ods-operator

# Note: This leaves RHOAI without an operator until the catalog is re-enabled
# and images are properly mirrored.
```

### Option C: Pin to prevent future auto-upgrades

After fixing, prevent this from happening again:

```bash
# If using OLM subscription:
oc patch subscription.operators.coreos.com rhods-operator -n redhat-ods-operator \
  --type=merge -p '{"spec":{"installPlanApproval":"Manual"}}'

# If managed by ACM: update the policy to pin the channel/version
```

---

## Verify MCP is unaffected

```bash
# MCP components should all be Running:
echo "=== MCP Gateway ==="
oc get pods -n mcp-gateway-system
echo ""
echo "=== Gateway (Envoy) ==="
oc get pods -n gateway-system
echo ""
echo "=== MCP Server ==="
oc get pods -n ocp-mcp-server
echo ""
echo "=== MCP Gateway CSV ==="
oc get csv | grep mcp-gateway
```

Quick end-to-end MCP test:

```bash
MCP_GATEWAY_HOSTNAME=$(oc get route mcp-gateway -n gateway-system -o jsonpath='{.spec.host}')

# Should return 401 (proves gateway is alive and enforcing auth):
curl -sk -o /dev/null -w "MCP Gateway auth check: HTTP %{http_code}\n" \
  -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

Expected: `HTTP 401` = MCP is working, AuthPolicy is enforcing.

---

## Summary

| What | Status | Action needed |
|------|--------|---------------|
| MCP Gateway | Working | None |
| MCP Server | Working | None |
| RHOAI Dashboard | Broken (ImagePullBackOff) | Mirror 3.4.3 images |
| RHOAI Operator | Stuck in Installing | Will self-heal once images are mirrored |
| Root cause | Operator auto-upgraded, new digests not in mirror | Mirror images or pin version |
