#!/bin/bash
set -e

deploy_arangodb() {
  cat arangodb.json | sed -e "s/{{ IP }}/$CURRENT_IP/g" | curl -X POST "$CURRENT_IP":8080/v2/apps -d @- --dump - -H "Content-Type: application/json" && echo
  
  MGMT_URL="" 
  while [ -z "$MGMT_URL" ]; do
    MGMT_URL=$(curl http://"$CURRENT_IP":8080/v2/apps//arangodb | jq -r 'if (.app.tasks |length > 0) then .app.tasks[0].host + ":" + (.app.tasks[0].ports[0] | tostring) else "" end')
  done
  
  STATUS_CODE=""
  while [[ (-z "$STATUS_CODE") || ("$STATUS_CODE" -lt 200) || ("$STATUS_CODE" -gt 399) ]]; do
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MGMT_URL"/v1/health.json || true)
    sleep 1
  done
  COORDINATOR=$(curl "$MGMT_URL"/v1/endpoints.json | jq '.coordinators[0]')
  [[ (-n "$COORDINATOR") && ("$COORDINATOR" != "null") ]] || (echo "No coordinator present :S" && exit 1)
  [[ "$(curl $COORDINATOR/_api/collection | jq '.collections | length > 0')" = "true" ]] || (echo "No collections on coordinator. Cluster bootstrap must be broken" && exit 1)
}
