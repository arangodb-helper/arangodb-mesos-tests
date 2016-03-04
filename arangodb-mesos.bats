#!/usr/bin/env bats

load helper

setup() {
  CURRENT_IP=""
  mkdir -p data
  docker rm -f mesos-test-cluster || true
  ./start-cluster.sh $(pwd)/data/mesos-cluster/ --num-slaves=6 -d --name mesos-test-cluster
  while [ -z "$CURRENT_IP" ]; do
    CURRENT_IP=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' mesos-test-cluster)
  done
  while [ "$(curl $CURRENT_IP:8080/ping)" != "pong" ]; do
    sleep 1
  done
}

teardown() {
  docker stop mesos-test-cluster
  docker rm -f mesos-test-cluster
  docker run --rm -v $(pwd)/data:/data ubuntu rm -rf /data/ 2>&1 > /dev/null || true
  rm -rf data/mesos-cluster
}

@test "I can deploy arangodb" {
  deploy_arangodb
}
