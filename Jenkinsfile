// Jenkinsfile — 루프 방지(봇/매니페스트 전용 커밋 스킵 + [skip ci])

pipeline {
  agent {
    kubernetes {
      label "jenkins-docker-pipeline"
      yaml """
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: jenkins-docker-pipeline
spec:
  restartPolicy: Never
  serviceAccountName: default
  containers:
    - name: docker
      image: docker:27
      command: ["sleep","infinity"]
      volumeMounts:
        - name: workspace
          mountPath: /home/jenkins/agent
    - name: dind
      image: docker:27-dind
      args: ["--host=tcp://0.0.0.0:2375","--storage-driver=overlay2"]
      securityContext: { privileged: true }
      env:
        - name: DOCKER_TLS_CERTDIR
          value: ""
      volumeMounts:
        - name: dind-storage
          mountPath: /var/lib/docker
        - name: workspace
          mountPath: /home/jenkins/agent
    - name: jnlp
      image: jenkins/inbound-agent:3327.v868139a_d00e0-6
      resources:
        requests: { cpu: "100m", memory: "256Mi" }
      volumeMounts:
        - name: workspace
          mountPath: /home/jenkins/agent
  volumes:
    - name: dind-storage
      emptyDir: {}
    - name: workspace
      emptyDir: {}
"""
    }
  }

  environment {
    DOCKER_HOST = "tcp://localhost:2375"

    // ★ 필요 시 변경
    GH_OWNER   = "k3sforall"                           // GitHub 소유자
    GH_REPO    = "jenkins-react"                       // 리포명
    GHCR_REPO  = "ghcr.io/k3sforall/jenkins-react"     // GHCR 경로
    ARGO_FILE  = "argoCD-yaml/4100-deploy-dokjongban-jen-react.yaml"  // 태그 바꿀 매니페스트
  }

  options {
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
    timeout(time: 60, unit: 'MINUTES')
  }

  stages {
    stage('Checkout (SCM)') {
      steps { checkout scm }
    }

    // 🔒 루프 방지 가드: 봇 커밋/매니페스트 전용 변경이면 SKIP_CI=true 설정
    stage('Guard (skip bot/manifest-only)') {
      steps {
        container('docker') {
          script {
            sh 'git config --global --add safe.directory "$PWD" || true'
            def authorEmail = sh(returnStdout:true, script:"git log -1 --pretty=%ae").trim()
            def subject     = sh(returnStdout:true, script:"git log -1 --pretty=%s").trim()
            def changedRaw  = sh(returnStdout:true, script:"git diff-tree --no-commit-id --name-only -r HEAD || true").trim()
            def changedList = changedRaw ? changedRaw.split('\\r?\\n') as List : []
            def manifestOnly = (changedList && changedList.every{ it.startsWith('argoCD-yaml/') })
            def isBotCommit  = (authorEmail == 'jenkins-bot@local') || subject.contains('[skip ci]') || subject.startsWith('CI: update image tag')

            env.SKIP_CI = (manifestOnly || isBotCommit) ? 'true' : 'false'

            echo "authorEmail=${authorEmail}"
            echo "subject=${subject}"
            echo "changed:\n${changedList.join('\n')}"
            echo "manifestOnly=${manifestOnly}, isBotCommit=${isBotCommit}, SKIP_CI=${env.SKIP_CI}"
          }
        }
      }
    }

    stage('Compute Image Tag') {
      when { expression { return env.SKIP_CI != 'true' } }
      steps {
        container('docker') {
          script {
            def short = sh(returnStdout:true, script:"git rev-parse --short=7 HEAD || echo manual").trim()
            env.IMAGE_TAG = "sha-${short}"
            echo "IMAGE_TAG=${env.IMAGE_TAG}"
          }
        }
      }
    }

    stage('Build & Push to GHCR (resilient)') {
      when { expression { return env.SKIP_CI != 'true' } }
      steps {
        container('docker') {
          withEnv(["DOCKER_CLI_EXPERIMENTAL=enabled"]) {
            withCredentials([usernamePassword(credentialsId: 'ghcr-creds', usernameVariable: 'GH_USER', passwordVariable: 'GH_PAT')]) {
              sh '''
                set -euxo pipefail
                echo "[WAIT] Checking dockerd on ${DOCKER_HOST}"
                for i in $(seq 1 60); do
                  if docker info >/dev/null 2>&1; then
                    echo "[OK] dockerd is ready"; break
                  fi
                  sleep 1
                done
                docker info

                echo "$GH_PAT" | docker login ghcr.io -u "$GH_USER" --password-stdin
                docker build -t ${GHCR_REPO}:${IMAGE_TAG} .
                docker push ${GHCR_REPO}:${IMAGE_TAG}
              '''
            }
          }
        }
      }
    }

    stage('Update ArgoCD Manifest & Push') {
      when { expression { return env.SKIP_CI != 'true' } }
      steps {
        container('docker') {
          withCredentials([usernamePassword(credentialsId: 'github-pat', usernameVariable: 'GITUSER', passwordVariable: 'GITPAT')]) {
            sh '''
              set -euxo pipefail
              WORK=/home/jenkins/agent/work-update
              rm -rf "$WORK"
              git clone "https://${GITUSER}:${GITPAT}@github.com/${GH_OWNER}/${GH_REPO}.git" "$WORK"
              cd "$WORK"

              # image 태그만 교체
              sed -i -E "s|(image:\\s*${GHCR_REPO}:).*|\\1${IMAGE_TAG}|" "${ARGO_FILE}"

              git add "${ARGO_FILE}"
              git -c user.name="jenkins-bot" -c user.email="jenkins-bot@local" \
                  commit -m "CI: update image tag to ${IMAGE_TAG} [skip ci]"
              git push origin HEAD:main
            '''
          }
        }
      }
    }
  }

  post {
    success {
      script {
        if (env.SKIP_CI == 'true') {
          echo "✅ 스킵: 봇 커밋/매니페스트 전용 변경 감지(루프 방지)."
        } else {
          echo "✅ 성공: ${env.IMAGE_TAG} 빌드/푸시 & 매니페스트 갱신 완료."
        }
      }
    }
    failure { echo "❌ 실패 — 콘솔 로그 확인" }
  }
}
