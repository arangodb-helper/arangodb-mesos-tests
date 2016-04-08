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
  while [ "$(curl -v -s $CURRENT_IP:8080/ping | tee -a /dev/stderr)" != "pong" ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
}

teardown() {
  local id=$(curl -v -s $CURRENT_IP:5050/master/state.json | jq -r .id)
  docker stop mesos-test-cluster
  docker logs mesos-test-cluster 1>&2
  docker rm -f -v mesos-test-cluster
  # absolutely make sure any dangling containers are gone...
  docker ps | grep $id | cut -d " " -f 1 | xargs docker rm -f -v || true
  docker run --rm -v $(pwd)/data:/data ubuntu rm -rf /data/ 2>&1 > /dev/null || true
  rm -rf data/mesos-cluster
}

@test "I can deploy arangodb" {
  deploy_arangodb
}

@test "Killing a dbserver will automatically restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-DBServer1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl -v -s http://$CURRENT_IP:5050/master/state.json | tee -a /dev/stderr | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-DBServer1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    [ "$end" -gt "$(date +%s)" ]
  done
}


@test "Killing a coordinator will automatically restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-Coordinator1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl -v -s http://$CURRENT_IP:5050/master/state.json | tee -a /dev/stderr | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
}

@test "A returning coordinator should have the same amount of collections" {
  deploy_arangodb
  
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  
  let end=$(date +%s)+100
  while [ ! $(curl -f -s $endpoint/_api/collection) ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done

  local num_collections=$(curl -v -s $endpoint/_api/collection | tee -a /dev/stderr | jq '.collections | length')

  >&2 echo "Num collections: $num_collections"
  
  local container_id=$(taskname2containername ara-Coordinator1)
  docker rm -f -v $container_id
  
  # Wait a bit so mesos has enough time to see the updated state
  sleep 5 
  let end=$(date +%s)+100
  while [ $(curl -v -s http://$CURRENT_IP:5050/master/state.json | tee -a /dev/stderr | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING" and .discovery.ports.ports[0].number)) | length') != 1 ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
  
  >&2 echo "Result: $endpoint"
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  
  let end=$(date +%s)+100
  while [ ! $(curl -v -f -s $endpoint/_api/collection) ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
  local num_collections_new=$(curl -v -s $endpoint/_api/collection | tee -a /dev/stderr | jq '.collections | length')
  
  >&2 echo "Result: $num_collections $num_collections_new"
  [ "$num_collections" = "$num_collections_new" ]
}

@test "Killing a secondary server will immediately restart that task" {
  deploy_arangodb
  local container_id=$(taskname2containername ara-Secondary1)
  docker rm -f -v $container_id
  
  let end=$(date +%s)+100
  while [ $(curl -v -s http://$CURRENT_IP:5050/master/state.json | tee -a /dev/stderr | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Secondary1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    sleep 1
    [ "$end" -gt "$(date +%s)" ]
  done
}

@test "When a machine containing a primary db server is going down there will be a failover to the secondary" {
    deploy_arangodb
    
    local endpoint=$(taskname2endpoint ara-Coordinator1)
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/collection <<EOF | tee -a /dev/stderr
  { 
    "name" : "clustertest", "numberOfShards": 2, "waitForSync": true
  }
EOF     
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "cluster": "lieber cluster" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "es ist": "noch nicht so weit" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "wir sehen erst den": "cluster fail" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "Ehe jeder Container nach": "/dev/null muss" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "Du hast gewiss": "Zeit" }
EOF
    local num_docs=$(curl -v -s "$endpoint"/_api/document?collection=clustertest | tee -a /dev/stderr | jq '.documents | length')

    local slavename=$(taskname2slavename ara-DBServer1)
    local containername=$(taskname2containername ara-DBServer1)

    serverId=$(grep -r "bootstraped" 8629.log | sed "s/.*bootstraped DB server //g")
    secondaryId=$(echo $serverId | sed -e 's/DBServer\([0-9]\+\)/Secondary\1/g')

    docker exec mesos-test-cluster supervisorctl stop $slavename
    docker rm -f -v $containername

    curl -X PUT -v "$endpoint"/_admin/cluster/swapPrimaryAndSecondary --data "{\"primary\": \"$serverId\", \"secondary\": \"$secondaryId\"}"
    
    local num_docs_new=$(curl -v -s "$endpoint"/_api/document?collection=clustertest | tee -a /dev/stderr | jq '.documents | length')
  >&2 echo "Docs: $num_docs $num_docs_new"
  [ "$num_docs" = "$num_docs_new" ]
}

@test "when a backend is going down the cluster will show a 503" {
    deploy_arangodb
    
    local endpoint=$(taskname2endpoint ara-Coordinator1)
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/collection <<EOF | tee -a /dev/stderr
  { 
    "name" : "clustertest", "numberOfShards": 2, "waitForSync": true
  }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "cluster": "lieber cluster" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "es ist": "noch nicht so weit" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "wir sehen erst den": "cluster fail" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "Ehe jeder Container nach": "/dev/null muss" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "Du hast gewiss": "Zeit" }
EOF
    local num_docs=$(curl -v -s "$endpoint"/_api/document?collection=clustertest | tee -a /dev/stderr | jq '.documents | length')

    local slavename=$(taskname2slavename ara-DBServer1)
    local containername=$(taskname2containername ara-DBServer1)

    docker exec mesos-test-cluster supervisorctl stop $slavename
    docker rm -f -v $containername
    
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$endpoint"/_api/document?collection=clustertest)

    >&2 echo "Code is $STATUS_CODE"
    [ "$STATUS_CODE" -eq "503" ]

}

@test "Rebooting a slave containing persistent data will restart its tasks with the old data" {
  deploy_arangodb
    local endpoint=$(taskname2endpoint ara-Coordinator1)
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/collection <<EOF | tee -a /dev/stderr
  { 
    "name" : "clustertest", "numberOfShards": 2, "waitForSync": true
  }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "cluster": "lieber cluster" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "es ist": "noch nicht so weit" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "wir sehen erst den": "cluster fail" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "Ehe jeder Container nach": "/dev/null muss" }
EOF
    curl -v -s -X POST --data-binary @- --dump - "$endpoint"/_api/document?collection=clustertest <<EOF | tee -a /dev/stderr
  { "Du hast gewiss": "Zeit" }
EOF
    local num_docs=$(curl -v -s "$endpoint"/_api/document?collection=clustertest | tee -a /dev/stderr | jq '.documents | length')
  local slavename=$(taskname2slavename ara-DBServer1)
  local containername=$(taskname2containername ara-DBServer1)
  
  docker exec mesos-test-cluster supervisorctl stop $slavename
  docker rm -f -v $containername

  docker exec mesos-test-cluster supervisorctl start $slavename
  sleep 2
  # slave will be rejected by the master. must be started one more time and will get a new Slave id BUT everything should work anyway
  docker exec mesos-test-cluster supervisorctl start $slavename

  let end=$(date +%s)+100
  while [ $(curl -v -s http://$CURRENT_IP:5050/master/state.json | tee -a /dev/stderr | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-DBServer1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    [ "$end" -gt "$(date +%s)" ]
  done

  let end=$(date +%s)+100
  while [ $(curl -v -s http://$CURRENT_IP:5050/master/state.json | tee -a /dev/stderr | jq -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == "ara-Coordinator1" and .state == "TASK_RUNNING")) | length') != 1 ]; do
    [ "$end" -gt "$(date +%s)" ]
  done
  local endpoint=$(taskname2endpoint ara-Coordinator1)
  local num_docs=$(curl -v -s "$endpoint"/_api/document?collection=clustertest | tee -a /dev/stderr | jq '.documents | length')
  >&2 echo "Docs: $num_docs $num_docs_new"
  [ "$num_docs" = "$num_docs_new" ]
}
