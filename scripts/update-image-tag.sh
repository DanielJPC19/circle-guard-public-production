#!/bin/bash
# Usage: ./scripts/update-image-tag.sh <service> <new-tag> <environment>
# Example: ./scripts/update-image-tag.sh auth-service v1.42 prod

set -e

SERVICE=$1
TAG=$2
ENV=$3
DOCKERHUB_USER=${DOCKERHUB_USER:-danieljpc1119}

if [ -z "$SERVICE" ] || [ -z "$TAG" ] || [ -z "$ENV" ]; then
    echo "Usage: $0 <service> <tag> <environment>"
    echo "  environment: stage | prod"
    exit 1
fi

MANIFEST="k8s/${ENV}/${SERVICE}.yaml"

if [ ! -f "$MANIFEST" ]; then
    echo "Error: manifest not found at $MANIFEST"
    exit 1
fi

sed -i "s|image: ${DOCKERHUB_USER}/circleguard-${SERVICE}:.*|image: ${DOCKERHUB_USER}/circleguard-${SERVICE}:${TAG}|" "$MANIFEST"

echo "Updated $MANIFEST -> ${DOCKERHUB_USER}/circleguard-${SERVICE}:${TAG}"
