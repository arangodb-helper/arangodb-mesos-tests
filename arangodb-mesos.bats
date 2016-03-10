#!/usr/bin/env bats

load helper

setup() {
  CURRENT_IP=""
  mkdir -p data
  docker rm -f -v mesos-test-cluster || true
  ./start-cluster.sh $(pwd)/data/mesos-cluster/ --num-slaves=6 -d --name mesos-test-cluster
  let end=$(date +%s)+100
  while [ -z "$CURRENT_IP" ]; do
    CURRENT_IP=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' mesos-test-cluster)
    [ "$end" -gt "$(date +%s)" ]
  done
  let end=$(date +%s)+100
  while [ "$(curl $CURRENT_IP:8080/ping)" != "pong" ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
}

teardown() {
  docker stop mesos-test-cluster
  docker rm -f -v mesos-test-cluster
  docker run --rm -v $(pwd)/data:/data ubuntu rm -rf /data/ 2>&1 > /dev/null || true
  rm -rf data/mesos-cluster
}

@test "I can deploy arangodb" {
}

@test "Killing a dbserver will automatically restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-DBServer1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-DBServer1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    [ "$end" -gt "$(date +%s)" ]
  done
}

@test "Killing a coordinator will automatically restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-Coordinator1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
}

@test "A returning coordinator should have the same amount of collections" {
  deploy_arangodb
  
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  local num_collections=$(curl $endpoint/_api/collections | jq length)
  
  local container_id=$(taskname2containername ara-Coordinator1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
  
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  local num_collections_new=$(curl $endpoint/_api/collections | jq length)
  
  [ "$num_collections" = "$num_collections_new" ]
}

@test "Killing a secondary server will immediately restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-Secondary1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl http://$CURRENT_IP:5050/master/state.json | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Secondary1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
}

@test "When a machine containing a primary db server is going down there will be a failover to the secondary" {
  deploy_arangodb
  
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  curl -X POST --data-binary @- --dump - "$endpoint"/_api/collection <<EOF
{ 
  "name" : "clustertest", "numberOfShards": 2, "waitForSync": true
}
EOF
  curl -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF
{ "cluster": "lieber cluster" }
EOF
  curl -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF
{ "es ist": "noch nicht so weit" }
EOF
  curl -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF
{ "wir sehen erst den": "cluster fail" }
EOF
  curl -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF
{ "Ehe jeder Container nach": "/dev/null muss" }
EOF
  curl -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF
{ "Du hast gewiss": "Zeit" }
EOF
  local num_docs=$(curl "$endpoint"/_api/document?collection=clustertest | jq '.documents | length')

  local slavename=$(taskname2slavename ara-DBServer1)
  local containername=$(taskname2containername ara-DBServer1)

  docker exec mesos-test-cluster supervisorctl stop $slavename
  docker rm -f -v $containername
  
  local num_docs_new=$(curl "$endpoint"/_api/document?collection=clustertest | jq '.documents | length')
  >&2 echo "Docs: $num_docs $num_docs_new"
  [ "$num_docs" = "$num_docs_new" ]
}
