#!/bin/bash
set -e

deploy_arangodb() {
  cat arangodb.json | sed -e "s/{{ IP }}/$CURRENT_IP/g" | curl -X POST "$CURRENT_IP":8080/v2/apps -d @- --dump - -H "Content-Type: application/json" && echo
  
  MGMT_URL="" 
  let end=$(date +%s)+100
  while [ -z "$MGMT_URL" ]; do
    MGMT_URL=$(curl http://"$CURRENT_IP":8080/v2/apps//arangodb | jq -r 'if (.app.tasks |length > 0) then .app.tasks[0].host + ":" + (.app.tasks[0].ports[0] | tostring) else "" end')
    [ "$end" -gt "$(date +%s)" ]
  done
  
  STATUS_CODE=""
  let end=$(date +%s)+300
  while [[ (-z "$STATUS_CODE") || ("$STATUS_CODE" -lt 200) || ("$STATUS_CODE" -gt 399) ]]; do
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MGMT_URL"/v1/health.json || true)
    if [ "$end" -gt "$(date +%s)" ];then
      >&2 curl $CURRENT_IP:5050/master/state.json --dump -
      >&2 curl "$MGMT_URL"/v1/health.json --dump -
      false
    fi
    sleep 1
  done
  COORDINATOR=$(curl "$MGMT_URL"/v1/endpoints.json | jq -r '.coordinators[0]')
  [[ (-n "$COORDINATOR") && ("$COORDINATOR" != "null") ]]
  [[ "$(curl $COORDINATOR/_api/collection | jq '.collections | length > 0')" = "true" ]]
}

taskname2slaveurl() {
  local slave_id=$(curl http://$CURRENT_IP:5050/master/state.json | jq --arg taskname "$1" -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == $taskname)) | .[0].slave_id')
  curl http://$CURRENT_IP:5050/master/state.json | jq --arg slave_id "$slave_id" -r '.slaves | map(select (.id == $slave_id)) | .[0].pid | split("@") | reverse | join("/")'
}

taskname2containername() {
  local framework_id=$(curl http://$CURRENT_IP:5050/master/state.json | jq --arg taskname "$1" -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == $taskname)) | .[0].framework_id')
  local task_id=$(curl http://$CURRENT_IP:5050/master/state.json | jq --arg taskname "$1" -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == $taskname)) | .[0].id')
  local slave_url=$(taskname2slaveurl $1)
  echo $(curl "$slave_url"/state | jq --arg task_id "$task_id" --arg framework_id "$framework_id" -r '"mesos-" + .id + "." + (.frameworks | map(select (.id == $framework_id)) | .[0].executors | map(select(.tasks[].id == $task_id)) | .[0].container)')
}

taskname2endpoint() {
  local slave_id=$(curl http://$CURRENT_IP:5050/master/state.json | jq --arg taskname "$1" -r '.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == $taskname)) | .[0].slave_id')
  local hostname=$(curl http://$CURRENT_IP:5050/master/state.json | jq -r --arg slave_id "$slave_id" '.slaves | map(select(.id ==$slave_id)) | .[0].hostname')
  curl http://$CURRENT_IP:5050/master/state.json | jq --arg taskname "$1" --arg hostname "$hostname" -r '"http://" + $hostname + ":" + ((.frameworks | map(select (.name == "ara")) | .[0].tasks | map(select (.name == $taskname)) | .[0].discovery.ports.ports[0].number) | tostring)'
}

taskname2slavename() {
  local slave_url=$(taskname2slaveurl $1)
  curl $slave_url/state | jq -r '.flags.work_dir | split("/") | last'
}
