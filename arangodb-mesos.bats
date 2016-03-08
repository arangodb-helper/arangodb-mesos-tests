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

@test "Killing a dbserver will automatically restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-DBServer1)
  docker rm -f $container_id
  
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-DBServer1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
  done
}

@test "Killing a coordinator will automatically restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-Coordinator1)
  docker rm -f $container_id
  
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
  done
}

@test "A returning coordinator should have the same amount of collections" {
  deploy_arangodb
  
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  local num_collections=$(curl $endpoint/_api/collections | jq length)
  
  local container_id=$(taskname2containername ara-Coordinator1)
  docker rm -f $container_id
  
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
  done
  
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  local num_collections_new=$(curl $endpoint/_api/collections | jq length)
  
  [ "$num_collections" == "$num_collections_new" ]
}
