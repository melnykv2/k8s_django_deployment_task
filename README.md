# Kubernetes Audit Logging

Kubernetes audit logs from the EKS API server are shipped to an ELK stack (Elasticsearch, Logstash, Kibana, Filebeat), where they are parsed, flagged by detection rules and analysed.

Earlier work (deployment, security hardening) is in [documentation/](documentation/).

## 1. Benefits of audit logs

Every action in Kubernetes is an API request. The audit log records **who** did **what**, to **which object**, **when**, **from where**, and **whether it was allowed**.

- **Detect attacks**: credential misuse, attempts to read Secrets or exec into pods. Blocked attempts are logged too, which gives early warning.
- **Investigate incidents**: a reliable timeline of who changed what.
- **Accountability**: every change is tied to an identity (IAM role → RBAC group).
- **Compliance**: PCI DSS, SOC 2 and ISO 27001 require access logs.
- **Verify security controls**: shows that RBAC and Pod Security Admission reject what they should.

The audit policy sets how much each event contains:

| Level | Contents |
|---|---|
| `Metadata` | user, verb, resource, source IP, response code |
| `Request` | `Metadata` plus the request body |
| `RequestResponse` | `Metadata` plus the request and response bodies |

## 2. Architecture

```
kube-apiserver (EKS) ──▶ CloudWatch Logs  /aws/eks/healthchecks/cluster  (kept 30 days)
                               │ IAM role (IRSA), read-only
                               ▼
   Filebeat ──▶ Logstash ──▶ Elasticsearch ──▶ Kibana   (namespace "logging", dedicated node)
               parse + detection rules                   (port-forward only)
```

- **CloudWatch** keeps the original log outside the cluster, so it can't be changed even if the cluster is compromised.
- **Filebeat** reads from CloudWatch, because on EKS the audit log is not a file on our nodes.

## 3. Setup

### 3.1 Enable audit logging (`infra/eks-cluster.yaml`)

On EKS, AWS runs the API server and applies its own audit policy, which records all requests and logs Secrets at `Metadata` level. The policy can't be changed; enabling the log type is enough:

```yaml
cloudWatch:
  clusterLogging:
    enableTypes: ["audit", "authenticator"]
    logRetentionInDays: 30
```

On a self-managed cluster (kubeadm, k3s) you would instead pass your own policy to the API server with `--audit-policy-file` and `--audit-log-path`.

### 3.2 Cluster prerequisites (`infra/eks-cluster.yaml`)

- node group `logging` (1 × t3.large, tainted `dedicated=logging:NoSchedule`) for the ELK stack
- `aws-ebs-csi-driver` add-on with a default StorageClass, for the Elasticsearch disk
- IRSA ServiceAccount `logging/filebeat`, allowed only to read the cluster's log group

### 3.3 ELK stack

| File | Purpose |
|---|---|
| `values/elasticsearch.yaml` | single node, TLS + password, 20 GiB EBS, NetworkPolicy, no privileged container |
| `values/logstash-config.yaml` | pipeline: parse, enrich, detection rules, output to Elasticsearch |
| `values/filebeat.yaml` | Deployment with the `aws-cloudwatch` input → Logstash |
| `values/kibana.yaml` | ClusterIP only |
| `helm_secrets/elastic_secret.yaml` | `elastic` password (sops-encrypted), fixed across upgrades |

All four are releases in `helmfile.yaml` with the label `tier=logging`:

```bash
helmfile -l tier=logging apply
kubectl get pods -n logging
```

The `logging` namespace enforces Pod Security `baseline` and audits `restricted`. The Kibana chart's setup job can't be hardened; all long-running ELK pods are `restricted`-compliant.

### 3.4 Open Kibana

```bash
kubectl get secret -n logging elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward -n logging svc/kibana-kibana 5601:5601
```

Open http://localhost:5601, log in as `elastic`, and create a data view for `k8s-audit-*` with time field `@timestamp`.

**Test:** run `kubectl get secrets -n healthchecks --as=jane --as-group=healthchecks:developers`. After 1–2 minutes the request appears in Kibana with `suspicious_reasons: access-denied`.

## 4. Parsing and detection

Logstash:
- parses each event into `audit.*` fields
- sets `@timestamp` to when the request happened
- adds `source_ip` and `user_type` (`human` / `serviceaccount` / `system`)
- drops lease heartbeats from control-plane components as noise (they remain in CloudWatch)
- uses `auditID` as the document ID, so re-reading the logs never creates duplicates

Each matching rule adds a reason to `suspicious_reasons` and sets `suspicious: true`:

| Reason | Rule |
|---|---|
| `access-denied` | response `401` / `403` |
| `secret-read` | a human reads Secrets |
| `pod-exec` | `exec`, `attach`, `portforward` |
| `rbac-change` | write to RBAC objects |
| `security-control-deleted` | delete of NetworkPolicy or Namespace |
| `impersonation` | request made with `--as` |
| `permission-discovery` | a human runs `kubectl auth can-i --list` |
| `anonymous-access` | unauthenticated request |

Useful Kibana queries:

```
suspicious : true
suspicious_reasons : "access-denied" and user_type : "human"
audit.objectRef.resource : "secrets" and not user_type : "system"
audit.user.username : *healthchecks-developer*
```

**Routine:** review `suspicious : true` daily, and alert on ≥ 3 `access-denied` events from one person within 5 minutes.

## 5. Exercise: suspicious activity (hypothetical)

**Trigger.** The daily review shows 8 flagged events at 02:47–02:51 UTC from `assumed-role/healthchecks-developer/jane`. Jane doesn't work at night.

**How it was logged.** One of the events, as stored in Elasticsearch after the Logstash pipeline (shortened):

```json
{
  "@timestamp": "2026-10-24T02:47:30.412Z",
  "source_ip": "198.51.100.77",
  "user_type": "human",
  "suspicious": true,
  "suspicious_reasons": ["access-denied", "secret-read"],
  "audit": {
    "verb": "list",
    "user": {
      "username": "arn:aws:sts::111122223333:assumed-role/healthchecks-developer/jane",
      "groups": ["healthchecks:developers", "system:authenticated"]
    },
    "objectRef": { "resource": "secrets", "namespace": "healthchecks" },
    "userAgent": "kubectl/v1.34.1 (linux/amd64)",
    "responseStatus": { "code": 403, "reason": "Forbidden" }
  }
}
```

The API server recorded the request; Logstash added `source_ip`, `user_type` and two detection reasons. That is why it appeared under `suspicious : true`.

**Step 1: everything this identity did.** Query `audit.user.username : *healthchecks-developer/jane*`:

| Time | source_ip | Action | Code |
|---|---|---|---|
| Fri 14:05–17:40 | 203.0.113.10 (darwin) | get/list pods, logs | 200 |
| Sat 02:47:12 | **198.51.100.77 (linux)** | `auth can-i --list` | 201 |
| 02:47:30 | 198.51.100.77 | list secrets `healthchecks` | **403** |
| 02:47:41 | 198.51.100.77 | list secrets `kube-system` | **403** |
| 02:48:05 | 198.51.100.77 | exec into app pod | **403** |
| 02:48:40 | 198.51.100.77 | create pod | **403** |
| 02:50:02 | 198.51.100.77 | **scale deployment to 0** | 200 |
| 02:50:30 | 198.51.100.77 | delete pods | 200 |

**Step 2: is it really Jane?** No:
- an IP never seen before
- a different OS in the user agent
- night-time activity
- a classic attacker sequence: discover permissions → Secrets → shell → own pod

CloudTrail shows `AssumeRole` from the same IP without MFA. **Jane's access key was stolen.**

**Step 3: impact.**
- RBAC blocked every attempt to read Secrets, exec, or create pods, so **no data was accessed**.
- The attacker *was* allowed to scale the app to zero, so **the site was down** until the morning.

**Step 4: response.**
- revoke the role's active sessions and deactivate Jane's key
- scale the app back to 2 replicas
- confirm there was no other activity from that IP

**Lessons:**
- require MFA and a source-IP condition to assume roles
- forbid `replicas: 0` for the app
- alert on bursts of denials (this would have caught the attack at 02:48 instead of 08:30)

## 6. Insights

1. **Denied requests are the strongest signal.** Normal users rarely get `403`. RBAC turned the attack into a visible series of denials.
2. **Look at the whole session, not only alerts.** The damaging actions were *allowed* and matched no rule. They were found by pivoting on the identity and IP.
3. **Correlate with CloudTrail.** The audit log shows *what* happened in the cluster; CloudTrail shows *how* the attacker got in.
4. **Most audit volume is system traffic.** Filtering it makes human activity easy to review.
5. **Alerting matters.** The evidence existed at 02:47, but without an alert it was found six hours later.

## 7. Security of the logging stack and limitations

**Security:**
- TLS and authentication on Elasticsearch, with the password encrypted in Git
- Kibana is not exposed (port-forward only)
- Filebeat uses a read-only IAM role, with no AWS keys in the cluster
- all long-running ELK pods are non-root, with all capabilities dropped

**Limitations:**
- the `elastic/*` Helm charts are deprecated (8.5.1 is the last release); use ECK or a managed service in production
- Elasticsearch runs as a single node
- Logstash writes as the `elastic` superuser

## Cleanup

```bash
helmfile -l tier=logging destroy
kubectl delete pvc -n logging elasticsearch-master-elasticsearch-master-0
eksctl delete nodegroup --cluster healthchecks --name logging --approve
```
