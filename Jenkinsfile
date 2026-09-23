pipeline {
  agent any
  options {
    disableConcurrentBuilds(abortPrevious: true)
    skipDefaultCheckout(true)
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
  }
  environment {
    DOCKER_CONTEXT_NAME = 'wg-key-rotator-ci-docker'
    BUILDER = 'wg-key-rotator-http-host'
  }
  stages {
    stage('Checkout') {
      steps {
        deleteDir()
        checkout scm
      }
    }
    stage('Test') {
      steps {
        sh '''
          set -eu
          tar -cf - . | docker run --rm -i -w /workspace elixir:1.17-slim \
            sh -c 'tar --no-same-owner -xf - && mix local.hex --force && mix deps.get && mix test'
        '''
      }
    }
    stage('Publish immutable image') {
      when { branch 'main' }
      steps {
        sh '''
          set -eu
          test -n "${CI_REGISTRY:-}"
          mkdir -p artifacts
          revision="$(git rev-parse HEAD)"
          if docker context inspect "$DOCKER_CONTEXT_NAME" >/dev/null 2>&1; then
            docker context rm --force "$DOCKER_CONTEXT_NAME" >/dev/null
          fi
          docker context create "$DOCKER_CONTEXT_NAME" \
            --docker "host=$DOCKER_HOST,ca=$DOCKER_CERT_PATH/ca.pem,cert=$DOCKER_CERT_PATH/cert.pem,key=$DOCKER_CERT_PATH/key.pem" >/dev/null
          docker_cmd() {
            env -u DOCKER_HOST -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
              DOCKER_CONTEXT="$DOCKER_CONTEXT_NAME" docker "$@"
          }
          printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$CI_REGISTRY" > artifacts/buildkitd.toml
          if ! docker_cmd buildx inspect "$BUILDER" >/dev/null 2>&1; then
            docker_cmd buildx create --name "$BUILDER" --driver docker-container \
              --driver-opt network=host --buildkitd-config artifacts/buildkitd.toml >/dev/null
          fi
          docker_cmd buildx inspect "$BUILDER" --bootstrap >/dev/null
          docker_cmd buildx build --builder "$BUILDER" --platform linux/amd64 \
            --file Dockerfile --tag "$CI_REGISTRY/wg-key-rotator:$revision" \
            --metadata-file artifacts/wg-key-rotator.json --push .
        '''
        archiveArtifacts artifacts: 'artifacts/*.json', fingerprint: true
      }
    }
  }
}
