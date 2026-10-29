# Kubernetes Security Enhancement

## 1. Threat assessment

**Scope:**
- the Helm chart (`k8s_security_enhancement/`)
- the vendored subcharts
- `helmfile.yaml`
- the EKS cluster definition (`infra/eks-cluster.yaml`)

**Scenario:** an attacker finds a bug in Django and can run commands inside an application pod. How far can they get?

| # | Threat | Where (evidence) | Severity | Mitigation | Step |
|---|---|---|---|---|---|
| 1 | A compromised container can gain privileges, use Linux capabilities and write to its filesystem | `deployment.yaml` has no `securityContext` | High | `securityContext`: non-root, no privilege escalation, read-only filesystem, drop all capabilities, seccomp | 2 |
| 2 | Anyone who can create pods can start a privileged pod and take over the node | App runs in `default`, no Pod Security Admission | High | Dedicated namespace with Pod Security `restricted` | 2 |
| 3 | Every pod gets a Kubernetes API token it never uses | No `automountServiceAccountToken: false` | Medium | Dedicated ServiceAccount without a token | 2 |
| 4 | Any pod can reach any other pod and the AWS metadata service (node IAM credentials) | No NetworkPolicy | High | Default deny + allow only ingress-nginx → app, app → DNS and database | 3 |
| 5 | One identity is admin of everything; no limited access is possible | Only the cluster creator has access | High | RBAC roles: viewer, developer, namespace admin | 4 |
| 6 | Anyone allowed to read Secrets sees the DB password (base64 is not encryption) | `secret.yaml` | Medium | RBAC: viewers and developers cannot read Secrets | 4 |
| 7 | ingress-nginx 4.8.1 is vulnerable to CVE-2025-1974 "IngressNightmare" (read all cluster Secrets); the project no longer receives fixes since March 2026. cert-manager v1.13 is end of life | `charts/ingress-nginx-4.8.1.tgz`, `charts/cert-manager-v1.13.1.tgz` | High | Disable the ingress-nginx admission webhook now; upgrade the components | 2 + proposal |
| 8 | Long-lived AWS access keys stored in plain text on the workstation | `~/.zshrc` | High | Rotate keys, use AWS SSO with short-lived credentials | Proposal |

**Already good:**
- secrets encrypted in Git with sops + age
- HTTPS with Let's Encrypt
- the image runs as a non-root user (`USER 1000`)
- RDS is not publicly accessible, and the app connects over SSL
- resource requests and limits are set
