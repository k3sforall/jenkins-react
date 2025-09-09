// Jenkinsfile — 루프 방지(봇+매니페스트 전용 커밋만 스킵) & def 미사용 안전버전

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
    - name: git
      image: alpine/git:2.45.2
      command: ["sleep","infinity"]
      volumeMounts:
        - name: workspace
          mountPath: /home/jenkins/agent
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
    GH_REPO    = "jenkins-react"                       // 리포지토리
    GHCR_REPO  = "ghcr.io/k3sforall/jenkins-react"     // GHCR (이미지 풀네임)
    ARGO_FILE  = "argoCD-yaml/4100-deploy-dokjongban-jen-react.yaml" // 이미지 태그 바꿀 파일
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

    // 🔒 루프 방지: "우리 봇 커밋" + "매니페스트만 변경"일 때만 스킵
    stage('Guard (skip only bot+manifest-only commit)') {
      steps {
        container('git') {
          sh '''
            set -e
            git config --global --add safe.directory "$PWD" || true

            authorEmail="$(git log -1 --pretty=%ae || true)"
            subject="$(git log -1 --pretty=%s || true)"
            changed="$(git show --pretty='' --name-only HEAD || true)"

            manifest_only=false
            if [ -n "$changed" ]; then
              # 하나라도 argoCD-yaml/ 아닌 변경이 있으면 manifest_only=false
              if echo "$changed" | awk '!/^argoCD-yaml\\//' | grep -q . ; then
                manifest_only=false
              else
                manifest_only=true
              fi
            fi

            is_bot_author=false; [ "$authorEmail" = "jenkins-bot@local" ] && is_bot_author=true
            is_bot_subject=false
            echo "$subject" | grep -q "\\[skip ci\\]" && is_bot_subject=true
            echo "$subject" | grep -q "^CI: update image tag" && is_bot_subject=true

            SKIP_CI=false
            if [ "$manifest_only" = "true" ] && { [ "$is_bot_author" = "true" ] || [ "$is_bot_subject" = "true" ]; }; then
              SKIP_CI=true
            fi

            printf "%s" "$SKIP_CI" > .skip_ci
            echo "authorEmail=$authorEmail"
            echo "subject=$subject"
            echo "changed-files:"
            echo "$changed"
            echo "manifest_only=$manifest_only is_bot_author=$is_bot_author is_bot_subject=$is_bot_subject SKIP_CI=$SKIP_CI"
          '''
          script { env.SKIP_CI = readFile('.skip_ci').trim() }
        }
      }
    }

    stage('Compute Image Tag') {
      when { expression { return env.SKIP_CI != 'true' } }
      steps {
        container('git') {
          sh '''
            set -e
            SHORT="$(git rev-parse --short=7 HEAD || echo manual)"
            printf "sha-%s" "$SHORT" > image_tag.txt
          '''
          script { env.IMAGE_TAG = readFile('image_tag.txt').trim() }
          echo "IMAGE_TAG=${env.IMAGE_TAG}"
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
        container('git') {
          withCredentials([usernamePassword(credentialsId: 'github-pat', usernameVariable: 'GITUSER', passwordVariable: 'GITPAT')]) {
            sh '''
              set -euxo pipefail
              WORK=/home/jenkins/agent/work-update
              rm -rf "$WORK"
              git clone "https://${GITUSER}:${GITPAT}@github.com/${GH_OWNER}/${GH_REPO}.git" "$WORK"
              cd "$WORK"

              # 이미지 태그만 교체
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
          echo "✅ 루프 방지: 봇이 만든 매니페스트-전용 커밋이라 스킵했습니다."
        } else {
          echo "✅ 성공: ${env.IMAGE_TAG} 빌드/푸시 및 매니페스트 갱신 완료."
        }
      }
    }
    failure { echo "❌ 실패 — 콘솔 로그 확인" }
  }
}
