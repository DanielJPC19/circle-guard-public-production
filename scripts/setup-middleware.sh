#!/bin/bash
# Instala el middleware de CircleGuard en GKE usando Helm.
# Idempotente: usa helm upgrade --install.
#
# Pre-requisitos:
#   - kubectl configurado y apuntando al cluster correcto
#   - Acceso a internet para descargar charts de Bitnami y Neo4j
#
# Uso:
#   bash scripts/setup-middleware.sh                  # instala en stage y prod
#   bash scripts/setup-middleware.sh circleguard-stage
#   bash scripts/setup-middleware.sh circleguard-prod

set -e

TARGET_NS=${1:-"all"}

# ── Verificar/instalar Helm ───────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
    echo "==> Helm no encontrado. Instalando..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> Helm version: $(helm version --short)"

# ── Agregar repositorios de charts ───────────────────────────────────────────
echo "==> Configurando repositorios Helm..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
helm repo update

# ── Función: instalar middleware en un namespace ──────────────────────────────
install_middleware() {
    local NS=$1
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Instalando middleware en namespace: ${NS}"
    echo "════════════════════════════════════════════════════════"

    # Crear namespace si no existe
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

    # ── PostgreSQL ────────────────────────────────────────────────────────────
    echo "==> [${NS}] PostgreSQL..."
    helm upgrade --install circleguard-postgres bitnami/postgresql \
        --namespace "$NS" \
        --set auth.username=admin \
        --set auth.password=password \
        --set auth.database=circleguard \
        --set primary.persistence.size=5Gi \
        --wait --timeout=5m

    # ── Redis ─────────────────────────────────────────────────────────────────
    echo "==> [${NS}] Redis..."
    helm upgrade --install circleguard-redis bitnami/redis \
        --namespace "$NS" \
        --set auth.enabled=false \
        --set master.persistence.size=2Gi \
        --wait --timeout=5m

    # ── Kafka (modo KRaft, sin Zookeeper) ─────────────────────────────────────
    echo "==> [${NS}] Kafka..."
    helm upgrade --install circleguard-kafka bitnami/kafka \
        --namespace "$NS" \
        --set kraft.enabled=true \
        --set replicaCount=1 \
        --set persistence.size=5Gi \
        --wait --timeout=8m

    # ── Neo4j ─────────────────────────────────────────────────────────────────
    echo "==> [${NS}] Neo4j..."
    helm upgrade --install circleguard-neo4j neo4j/neo4j \
        --namespace "$NS" \
        --set neo4j.password=password \
        --set volumes.data.requests.storage=5Gi \
        --wait --timeout=8m

    # ── Estado de los pods ────────────────────────────────────────────────────
    echo "==> [${NS}] Estado de los pods:"
    kubectl get pods -n "$NS" -l 'app.kubernetes.io/instance in (circleguard-postgres,circleguard-redis,circleguard-kafka,circleguard-neo4j)'

    # ── Aplicar secrets de la aplicación ──────────────────────────────────────
    if [ -f "k8s/middleware/secrets.yaml" ]; then
        echo "==> [${NS}] Aplicando secrets..."
        kubectl apply -f k8s/middleware/secrets.yaml -n "$NS"
    else
        echo "==> ADVERTENCIA: k8s/middleware/secrets.yaml no encontrado."
    fi

    echo "==> [${NS}] Middleware instalado correctamente."
}

# ── Verificar rollout de StatefulSets ─────────────────────────────────────────
verify_statefulsets() {
    local NS=$1
    echo "==> [${NS}] Verificando rollout de StatefulSets..."
    for sset in \
        circleguard-postgres-postgresql \
        circleguard-redis-master \
        circleguard-kafka \
        circleguard-neo4j; do
        kubectl rollout status statefulset/"$sset" \
            -n "$NS" --timeout=5m 2>/dev/null || \
        echo "    (StatefulSet ${sset} no encontrado o aún iniciando)"
    done
}

# ── Ejecutar según el namespace objetivo ──────────────────────────────────────
case "$TARGET_NS" in
    all)
        install_middleware "circleguard-stage"
        verify_statefulsets "circleguard-stage"
        install_middleware "circleguard-prod"
        verify_statefulsets "circleguard-prod"
        ;;
    circleguard-stage|circleguard-prod)
        install_middleware "$TARGET_NS"
        verify_statefulsets "$TARGET_NS"
        ;;
    *)
        echo "Error: namespace '$TARGET_NS' no reconocido."
        echo "Opciones: circleguard-stage | circleguard-prod | all"
        exit 1
        ;;
esac

echo ""
echo "==> Setup de middleware completado."
echo "==> Verifica el estado con: kubectl get pods -n <namespace>"
