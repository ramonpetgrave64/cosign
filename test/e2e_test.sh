#!/usr/bin/env bash
#
# Copyright 2021 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -ex

docker_compose="docker compose"
if ! ${docker_compose} version >/dev/null 2>&1; then
    docker_compose="docker-compose"
fi

echo "setting up OIDC provider"
pushd ./test/fakeoidc
# oidcimg=$(ko build main.go --local --base-import-paths)
ko build --local --base-import-paths
# docker network ls | grep fulcio_default || docker network create fulcio_default --label "com.docker.compose.net work=fulcio_default"
docker start fakeoidc || docker run -d --rm -p 8080:8080 --name fakeoidc ko.local/fakeoidc
cleanup_oidc() {
    echo "cleaning up oidc"
    docker stop fakeoidc
}
# trap cleanup_oidc EXIT
export OIDC_URL="http://fakeoidc:8080"
cat <<EOF > /tmp/fulcio-config.json
{
  "OIDCIssuers": {
    "http://fakeoidc:8080": {
      "IssuerURL": "http://fakeoidc:8080",
      "ClientID": "sigstore",
      "Type": "email"
    }
  }
}
EOF
popd

pushd ../

echo "downloading service repos"
for repo in rekor fulcio; do
    if [[ ! -d $repo ]]; then
        git clone https://github.com/sigstore/${repo}.git
    else
        pushd $repo
        # git pull
        popd
    fi
done

echo "starting services"
export FULCIO_METRICS_PORT=2113
export FULCIO_CONFIG=/tmp/fulcio-config.json
for repo in rekor fulcio; do
    pushd $repo
    ${docker_compose} up -d
    echo -n "waiting up to 60 sec for system to start"
    count=0
    until [ $(${docker_compose} ps | grep -c "(healthy)") == 3 ];
    do
        if [ $count -eq 18 ]; then
           echo "! timeout reached"
           exit 1
        else
           echo -n "."
           sleep 10
           let 'count+=1'
        fi
    done
    popd
done
docker network disconnect fulcio_default fakeoidc || true
docker network connect --alias fakeoidc fulcio_default fakeoidc

cleanup_services() {
    echo "cleaning up"
    cleanup_oidc
    for repo in rekor fulcio; do
        pushd ../$repo
        ${docker_compose} down
        popd
    done
}
# trap cleanup_services EXIT

echo
echo "running tests"

popd
go test -tags=e2e -race ./test/...

# Test on a private registry
echo "testing sign/verify/clean on private registry"
cleanup() {
    cleanup_services
    docker rm -f registry
}
# trap cleanup EXIT
docker run -d -p 5000:5000 --restart always -e REGISTRY_STORAGE_DELETE_ENABLED=true --name registry registry:latest
export COSIGN_TEST_REPO=localhost:5000
go test -tags=e2e ./test/... -run TestSignVerifyClean

# Run the built container to make sure it doesn't crash
make ko-local
img="ko.local/cosign:$(git rev-parse HEAD)"
docker run $img version
