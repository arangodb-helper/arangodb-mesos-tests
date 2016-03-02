#!/bin/bash

deploy_arangodb() {
  cat arangodb.json | sed -e "s/{{ IP }}/$CURRENT_IP/g" | curl -X POST "$CURRENT_IP":8080/v2/apps -d @- --dump - -H "Content-Type: application/json" && echo
  
  MGMT_URL="" 
  while [ -z "$MGMT_URL" ]; do
    MGMT_URL=$(curl http://"$CURRENT_IP":8080/v2/apps//arangodb | jq -r 'if (.app.tasks |length > 0) then .app.tasks[0].host + ":" + (.app.tasks[0].ports[0] | tostring) else "" end')
  done
  
  STATUS_CODE=""
  echo "" > code
  while [[ (-z "$STATUS_CODE") || ("$STATUS_CODE" -lt 200) || ("$STATUS_CODE" -gt 399) ]]; do
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MGMT_URL"/v1/health.json || true)
    echo "$STATUS_CODE" >> code
    echo "$MGMT_URL"/v1/health.json >> code
    sleep 1
  done
  
}
