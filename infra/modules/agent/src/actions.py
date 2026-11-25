import json
import os
from datetime import datetime, timezone

import boto3

ecs = boto3.client("ecs")
sns = boto3.client("sns")
ddb = boto3.client("dynamodb")

AUDIT_TABLE = os.environ["AUDIT_TABLE"]
REPORT_TOPIC = os.environ.get("REPORT_TOPIC_ARN", "")
CLUSTER = os.environ.get("CLUSTER", "")
SERVICE = os.environ.get("SERVICE", "")
ALLOWED = ("rollback_to_previous", "scale_service")


def audit(incident, kind, payload):
    ddb.put_item(
        TableName=AUDIT_TABLE,
        Item={
            "incident_id": {"S": str(incident)},
            "ts": {"S": datetime.now(timezone.utc).isoformat()},
            "kind": {"S": kind},
            "payload": {"S": json.dumps(payload, default=str)[:20000]},
        },
    )


def notify(event, context):
    req = event["input"]
    incident = req.get("incident") or "unknown"
    action = req.get("action")
    audit(incident, "approval_pending", {
        "action": action, "reason": req.get("reason"),
        "desired_count": req.get("desired_count"), "token": event["token"],
    })
    cmd = ".\\scripts\\approve.ps1 -Incident \"" + incident + "\" -Decision "
    body = (
        f"Approval needed for incident {incident}\n\n"
        f"Proposed action: {action}\nReason: {req.get('reason')}\n"
        f"Desired count: {req.get('desired_count')}\n\n"
        "This request expires in 15 minutes.\n"
    ) + "To approve: " + cmd + "approve\n" + "To reject:  " + cmd + "reject\n"
    sns.publish(TopicArn=REPORT_TOPIC, Subject=f"[SentinelOps] Approval needed: {action}"[:100], Message=body)
    return {"notified": True}


def rollback():
    svc = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"][0]
    current = svc["taskDefinition"]
    family = current.split("/")[-1].rsplit(":", 1)[0]
    current_rev = int(current.rsplit(":", 1)[1])
    arns = ecs.list_task_definitions(familyPrefix=family, status="ACTIVE", sort="DESC", maxResults=20)["taskDefinitionArns"]
    older = [a for a in arns if int(a.rsplit(":", 1)[1]) < current_rev]
    if not older:
        return {"error": "no previous revision to roll back to"}
    target = older[0]
    ecs.update_service(cluster=CLUSTER, service=SERVICE, taskDefinition=target)
    return {"rolled_back_from": current.split("/")[-1], "to": target.split("/")[-1]}


def scale(desired):
    desired = max(1, min(int(desired), 3))
    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=desired)
    return {"desired_count": desired}


def execute(event, context):
    action = event.get("action")
    incident = event.get("incident") or "unknown"
    try:
        if action not in ALLOWED:
            result = {"error": "action not allowed"}
        elif action == "rollback_to_previous":
            result = rollback()
        else:
            result = scale(event.get("desired_count"))
    except Exception as e:
        result = {"error": str(e)[:200]}
    audit(incident, "action_executed", {"action": action, "result": result})
    return result
