pipeline {
  agent {
    kubernetes {
      defaultContainer 'jnlp'
      yaml """
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: jenkins-docker-pipeline
spec:
  serviceAccountName: default
  containers:
    - name: docker
      image: docker:27
      command: ['sleep','infinity']
      tty: true
      volumeMounts:
        - name: workspace-volume
          mountPath: /home/jenkins/agent

    - name: dind
      image: docker:27-dind
      securityContext:
        privileged: true
      env:
        - name: DOCKER_TLS_CERTDIR
          value: ""
      args:
        - --host=tcp://0.0.0.0:2375
        - --storage-driver=overlay2
      volumeMounts:
        - name: dind-storage
          mountPath: /var/lib/docker
        - name: workspace-volume
          mountPath: /home/jenkins/agent

    - name: git
      image: alpine/git:2.45.2
      command: ['sleep','infinity']
      tty: true
      volumeMounts:
        - name: workspace-volume
          mountPath: /home/jenkins/agent

  volumes:
    - name: workspace-volume
      emptyDir: {}
    - name: dind-storage
      emptyDir: {}
"""
    }
  }

  environment {
    GIT_BRANCH   = 'main'                                            // [변경] 브랜치
    GIT_REPO_URL = 'https://github.com/k3sforall/jenkins-react.git'  // [변경]
    IMAGE_REPO   = 'ghcr.io/k3sforall/jenkins-react'                 // [변경]
    DEPLOY_FILE  = 'argoCD-yaml/4100-deploy-dokjongban-jen-react.yaml' // [변경]
  }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  stages {
    stage('Checkout (SCM)') {
      steps {
        // Multibranch는 자동 checkout되지만 명시적으로 보강
        checkout scm
      }
    }

    stage('Compute Image Tag') {
      steps {
        container('git') {
          script {
            env.GIT_SHA = sh(returnStdout: true, script: '''
              set -e
              cd "$WORKSPACE"
              git config --global --add safe.directory "$WORKSPACE" || true
              git rev-parse --short=7 HEAD || echo manual
            ''').trim()
            env.IMAGE_TAG = "sha-${env.GIT_SHA}"
          }
          echo "IMAGE_TAG=${env.IMAGE_TAG}"
        }
      }
    }

    stage('Build & Push to GHCR (resilient)') {
      steps {
        container('docker') {
          withEnv(['DOCKER_HOST=tcp://localhost:2375']) {
            withCredentials([usernamePassword(
              credentialsId: 'ghcr-creds',    // GHCR PAT(write:packages)
              usernameVariable: 'GH_USER',
              passwordVariable: 'GH_PAT'
            )]) {
              sh '''
                set -euxo pipefail

                echo "[WAIT] Checking dockerd on ${DOCKER_HOST}"
                for i in $(seq 1 60); do
                  if docker info >/dev/null 2>&1; then
                    echo "[OK] dockerd is ready"
                    break
                  fi
                  echo "[...] waiting for dockerd... ($i/60)"
                  sleep 2
                done
                docker info >/dev/null 2>&1 || { echo "[FAIL] dockerd not ready"; exit 1; }

                echo "$GH_PAT" | docker login ghcr.io -u "$GH_USER" --password-stdin
                docker build -t ${IMAGE_REPO}:${IMAGE_TAG} .

                try_push() {
                  set +e
                  docker push ${IMAGE_REPO}:${IMAGE_TAG} 2>push.err.log
                  rc=$?
                  set -e
                  if [ $rc -eq 0 ]; then
                    echo "[OK] docker push succeeded"
                    return 0
                  fi
                  if grep -qi 'unknown blob' push.err.log; then
                    echo "[WARN] unknown blob detected. Falling back to skopeo copy..."
                    apk add --no-cache skopeo || true
                    skopeo copy --src-daemon-host=${DOCKER_HOST} \
                      docker-daemon:${IMAGE_REPO}:${IMAGE_TAG} \
                      docker://${IMAGE_REPO}:${IMAGE_TAG}
                    return $?
                  fi
                  return $rc
                }

                n=0
                until try_push; do
                  n=$((n+1))
                  if [ $n -ge 5 ]; then
                    echo "[FAIL] push failed after ${n} attempts"
                    exit 1
                  fi
                  backoff=$(( n * 5 ))
                  echo "[RETRY] attempt ${n}/5 — sleeping ${backoff}s"
                  sleep ${backoff}
                done
              '''
            }
          }
        }
      }
    }

    stage('Update ArgoCD Manifest & Push') {
      steps {
        container('git') {
          withCredentials([usernamePassword(
            credentialsId: 'github-pat',      // 여기의 Password가 PAT
            usernameVariable: 'GITUSER',
            passwordVariable: 'GITPAT'
          )]) {
            sh '''
              set -euxo pipefail
              cd "$WORKSPACE"
              git config --global --add safe.directory "$WORKSPACE" || true
              git config user.name  "jenkins-bot"
              git config user.email "ci@example.local"

              # 첫 번째 image: 라인만 안전 치환
              awk -v repl="        image: ${IMAGE_REPO}:${IMAGE_TAG}" '
                done==0 && $0 ~ /^[[:space:]]*image:[[:space:]]/ { print repl; done=1; next }
                { print }
              ' "${DEPLOY_FILE}" > "${DEPLOY_FILE}.tmp"
              mv "${DEPLOY_FILE}.tmp" "${DEPLOY_FILE}"

              git add "${DEPLOY_FILE}"
              git commit -m "ci: update image to ${IMAGE_REPO}:${IMAGE_TAG}" || true
              git remote set-url origin "https://${GITUSER}:${GITPAT}@github.com/k3sforall/jenkins-react.git"  # [변경] 필요 시 리포 교체
              git push origin "HEAD:${GIT_BRANCH}"
            '''
          }
        }
      }
    }
  }

  post {
    success { echo '✅ Push 트리거 → GHCR 푸시 → 매니페스트 갱신 → Argo CD 배포 완료' }
    failure { echo '❌ 실패 — 마지막 단계 콘솔 로그를 확인해 주세요.' }
  }
}
