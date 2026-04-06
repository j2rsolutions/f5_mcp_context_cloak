#!/usr/bin/env bash
# Build the Context Cloak iAppLX RPM package for BIG-IP installation
#
# Usage: ./scripts/build-rpm.sh
# Output: f5-context-cloak-0.1.0-0001.noarch.rpm
#
# Prerequisites:
#   - rpmbuild (install via: brew install rpm / apt install rpm)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

NAME="f5-context-cloak"
VERSION=$(node -e "console.log(require('${PKG_DIR}/package.json').version)")
RELEASE="0001"
ARCH="noarch"

BUILD_DIR=$(mktemp -d)
RPM_DIR="${BUILD_DIR}/rpmbuild"

echo "Building ${NAME}-${VERSION}-${RELEASE}.${ARCH}.rpm"

# Create RPM build structure
mkdir -p "${RPM_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create the source tarball
STAGE_DIR="${RPM_DIR}/SOURCES/${NAME}-${VERSION}"
mkdir -p "${STAGE_DIR}"
cp -r "${PKG_DIR}/package.json" "${STAGE_DIR}/"
cp -r "${PKG_DIR}/nodejs" "${STAGE_DIR}/"
cp -r "${PKG_DIR}/presentation" "${STAGE_DIR}/"

# Create the spec file
cat > "${RPM_DIR}/SPECS/${NAME}.spec" << SPEC
Name:       ${NAME}
Version:    ${VERSION}
Release:    ${RELEASE}
Summary:    Context Cloak - PII Cloaking for AI Inference on BIG-IP
License:    Apache-2.0
Group:      Development/Tools
BuildArch:  ${ARCH}

%description
Privacy-preserving MCP-assisted LLM workflows.
Deploys PII cloaking iRules, virtual servers, and pools on BIG-IP
to protect sensitive data from reaching LLM inference endpoints.

%install
rm -rf \$RPM_BUILD_ROOT
mkdir -p \$RPM_BUILD_ROOT/var/config/rest/iapps/${NAME}
cp -r ${STAGE_DIR}/* \$RPM_BUILD_ROOT/var/config/rest/iapps/${NAME}/

%files
/var/config/rest/iapps/${NAME}

%post
restorecon -R /var/config/rest/iapps/${NAME} 2>/dev/null || true
SPEC

# Build the RPM
rpmbuild --define "_topdir ${RPM_DIR}" -bb "${RPM_DIR}/SPECS/${NAME}.spec" 2>&1

# Copy the RPM out
RPM_FILE=$(find "${RPM_DIR}/RPMS" -name "*.rpm" | head -1)
if [ -n "$RPM_FILE" ]; then
    cp "$RPM_FILE" "${PKG_DIR}/"
    echo "Built: ${PKG_DIR}/$(basename "$RPM_FILE")"
else
    echo "RPM build failed"
    exit 1
fi

# Cleanup
rm -rf "${BUILD_DIR}"
