pipeline {
    agent any

    parameters {
        string(name: "IMAGE_TAG",   defaultValue: "staging",   description: "Docker image tag to deploy (staging | latest | vN | SHA)")
        choice(name: "ENVIRONMENT", choices: ["staging", "production"], description: "Target environment")
    }

    environment {
        DOCKERHUB_USER = "danieljpc1119"
        GKE_CLUSTER    = "kubernetes-instance-circle-guard"
        GKE_ZONE       = "us-central1-a"
        PROJECT_ID     = "ingesoft-v"
        SERVICES       = "auth-service identity-service promotion-service gateway-service notification-service form-service"
    }

    stages {

        // ── Resolver k8s dir y namespace según ENVIRONMENT ───────────────────
        stage("Resolve Environment") {
            steps {
                script {
                    def envMap = [staging: "stage", production: "prod"]
                    env.K8S_ENV   = envMap[params.ENVIRONMENT] ?: params.ENVIRONMENT
                    env.NAMESPACE = "circleguard-${env.K8S_ENV}"
                    echo "==> ENVIRONMENT=${params.ENVIRONMENT} → k8s/${env.K8S_ENV}/ | namespace=${env.NAMESPACE}"
                }
            }
        }

        // ── Stage 1: Autenticar en GCP y configurar kubectl ──────────────────
        stage("GCloud Auth & Kubectl Config") {
            steps {
                withCredentials([file(credentialsId: "gcp-service-account-key", variable: "GCP_KEY_FILE")]) {
                    sh """
                        gcloud auth activate-service-account --key-file=\$GCP_KEY_FILE
                        gcloud config set project ${env.PROJECT_ID}
                        gcloud container clusters get-credentials ${env.GKE_CLUSTER} \\
                          --zone ${env.GKE_ZONE} --project ${env.PROJECT_ID}
                        kubectl config current-context
                        kubectl get nodes
                    """
                }
            }
        }

        // ── Stage 2: Desplegar middleware (idempotente con kubectl apply) ──
        stage("Deploy Middleware") {
            steps {
                sh """
                    echo "==> Aplicando manifiestos de infraestructura en ${env.NAMESPACE}..."
                    kubectl apply -f k8s/infra/ -n ${env.NAMESPACE}

                    echo "==> Esperando que Postgres esté listo..."
                    kubectl rollout status statefulset/postgres -n ${env.NAMESPACE} --timeout=5m

                    echo "==> Esperando que Redis esté listo..."
                    kubectl rollout status deployment/redis -n ${env.NAMESPACE} --timeout=3m

                    echo "==> Esperando que Zookeeper esté listo..."
                    kubectl rollout status deployment/kafka-zookeeper -n ${env.NAMESPACE} --timeout=3m

                    echo "==> Esperando que Kafka esté listo..."
                    kubectl rollout status deployment/kafka-broker -n ${env.NAMESPACE} --timeout=4m

                    echo "==> Esperando que Neo4j esté listo..."
                    kubectl rollout status deployment/neo4j -n ${env.NAMESPACE} --timeout=5m

                    echo "==> Middleware listo en ${env.NAMESPACE}"
                """
            }
        }

        // ── Stage 3: Validar manifiestos sin aplicar ─────────────────────────
        stage("Validate Manifests") {
            steps {
                sh """
                    echo "==> Validando manifiestos para: ${env.K8S_ENV} (namespace: ${env.NAMESPACE})"
                    kubectl apply --dry-run=client \\
                      -f k8s/${env.K8S_ENV}/ \\
                      -n ${env.NAMESPACE}
                    echo "==> Validación exitosa"
                """
            }
        }

        // ── Stage 4: Actualizar image tags en los YAMLs ──────────────────────
        stage("Update Image Tags") {
            steps {
                script {
                    def servicesList = env.SERVICES.tokenize(' ')
                    for (int i = 0; i < servicesList.size(); i++) {
                        def svc = servicesList[i]
                        sh "bash scripts/update-image-tag.sh ${svc} ${params.IMAGE_TAG} ${env.K8S_ENV}"
                    }
                }
                sh "echo '==> Tags actualizados a ${params.IMAGE_TAG} en k8s/${env.K8S_ENV}/'"
            }
        }

        // ── Stage 5: Aplicar secrets ─────────────────────────────────────────
        stage("Apply Secrets") {
            steps {
                sh """
                    kubectl apply -f k8s/middleware/secrets.yaml -n ${env.NAMESPACE}
                    echo "==> Secrets aplicados en ${env.NAMESPACE}"
                """
            }
        }

        // ── Stage 6: Desplegar ────────────────────────────────────────────────
        stage("Deploy") {
            steps {
                sh """
                    echo "==> Desplegando en ${env.NAMESPACE} con tag ${params.IMAGE_TAG}"
                    kubectl apply -f k8s/${env.K8S_ENV}/ -n ${env.NAMESPACE}
                """
            }
        }

        // ── Stage 7: Verificar rollout con rollback automático ───────────────
        stage("Rollout Verification") {
            steps {
                script {
                    def servicesList = env.SERVICES.tokenize(' ')
                    def failed = []

                    for (int i = 0; i < servicesList.size(); i++) {
                        def svc = servicesList[i]
                        sh "kubectl rollout restart deployment/${svc} -n ${env.NAMESPACE}"
                        def result = sh(
                            script: "kubectl rollout status deployment/${svc} -n ${env.NAMESPACE} --timeout=10m",
                            returnStatus: true
                        )
                        if (result != 0) {
                            echo "==> ROLLBACK: deployment/${svc} falló — revertiendo..."
                            sh "kubectl rollout undo deployment/${svc} -n ${env.NAMESPACE}"
                            failed.add(svc)
                        } else {
                            echo "==> OK: deployment/${svc} desplegado correctamente"
                        }
                    }

                    if (!failed.isEmpty()) {
                        error("Rollout fallido para: ${failed.join(', ')} — rollback automático aplicado")
                    }
                }
            }
        }

        // ── Stage 8: Health Check del Gateway ────────────────────────────────
        stage("Health Check") {
            steps {
                script {
                    def ip = sh(
                        script: "kubectl get svc gateway-service -n ${env.NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}'",
                        returnStdout: true
                    ).trim()

                    if (!ip) {
                        error("No se pudo obtener la IP del LoadBalancer del gateway-service en ${env.NAMESPACE}")
                    }

                    env.GATEWAY_IP = ip
                    echo "==> Gateway IP: ${ip}"

                    def healthy = false
                    for (int i = 1; i <= 10; i++) {
                        def status = sh(
                            script: "curl -sf http://${ip}:8087/actuator/health",
                            returnStatus: true
                        )
                        if (status == 0) {
                            echo "==> Health check exitoso en intento ${i}/10"
                            healthy = true
                            break
                        }
                        echo "==> Intento ${i}/10 fallido — esperando 10s..."
                        sleep 10
                    }

                    if (!healthy) {
                        error("Health check fallido tras 10 intentos. Gateway no responde en http://${ip}:8087/actuator/health")
                    }
                }
            }
        }

        // ── Stage 9: Resumen del despliegue ──────────────────────────────────
        stage("Deployment Summary") {
            steps {
                script {
                    def servicesList = env.SERVICES.tokenize(' ')
                    def imageLines = ""
                    for (int i = 0; i < servicesList.size(); i++) {
                        imageLines += "  - ${env.DOCKERHUB_USER}/circleguard-${servicesList[i]}:${params.IMAGE_TAG}\n"
                    }

                    def summary = """\
Deployment Summary
==================
Environment:  ${params.ENVIRONMENT}
Namespace:    ${env.NAMESPACE}
Image tag:    ${params.IMAGE_TAG}
Timestamp:    ${new Date().format('yyyy-MM-dd HH:mm:ss')} UTC
Gateway URL:  http://${env.GATEWAY_IP}:8087

Services deployed:
${imageLines}
Jenkins build: ${env.BUILD_URL}
"""
                    writeFile file: "deployment-summary.txt", text: summary
                    echo summary
                }
                archiveArtifacts artifacts: "deployment-summary.txt"
            }
        }
    }

    post {
        success {
            echo "==> Deploy a ${params.ENVIRONMENT} exitoso — Gateway: http://${env.GATEWAY_IP}:8087"
        }
        failure {
            script {
                def servicesList = env.SERVICES.tokenize(' ')
                def rollbackCmds = ""
                for (int i = 0; i < servicesList.size(); i++) {
                    rollbackCmds += "  kubectl rollout undo deployment/${servicesList[i]} -n ${env.NAMESPACE}\n"
                }
                echo "==> ROLLBACK MANUAL (si el automático no alcanzó):\n${rollbackCmds}"
                echo "==> Logs: kubectl logs -n ${env.NAMESPACE} deployment/<servicio>"
            }
        }
        always {
            cleanWs()
        }
    }
}
