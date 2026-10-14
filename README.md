# k8s_django_deployment_task

Deploys the **Healthchecks** Django application (`melnykv2/healthchecks`) to **AWS EKS** with Helm and helmfile. The database runs in **Amazon RDS (PostgreSQL)**. HTTPS uses a **Let's Encrypt** certificate issued by cert-manager.

## Repository structure

```
├── helm_chart/                    # Application chart
│   ├── Chart.yaml
│   ├── values.yaml                # All non-secret settings (image, domain, RDS host, HPA, ...)
│   ├── secrets-values.yaml        # Secret values, encrypted with sops + age (helm-secrets)
│   └── templates/
│       ├── configmap.yaml         # Non-secret env vars
│       ├── secrets.yaml           # Secret env vars (DB password, Django SECRET_KEY)
│       ├── deployment.yaml        # 2 replicas, port 8080, envFrom, probes, migrate initContainer
│       ├── service.yaml           # ClusterIP
│       ├── ingress.yaml           # ingress-nginx + TLS via cert-manager
│       ├── cluster-issuer.yaml    # Let's Encrypt (prod) ClusterIssuer
│       └── hpa.yaml               # 2–4 replicas at 80% CPU / memory
├── helmfile/helmfile.yaml         # Whole environment: ingress-nginx, cert-manager, app
├── infra/eks-cluster.yaml         # eksctl cluster definition
├── .sops.yaml                     # sops rule: which file is encrypted, with which age key
└── documentation/deployment_guide.md
```

## Quick start

eksctl create cluster -f infra/eks-cluster.yaml
# create RDS in the cluster VPC and set config.DB_HOST in helm_chart/values.yaml

helmfile -f helmfile/helmfile.yaml sync                   # first install  
helmfile -f helmfile/helmfile.yaml apply                  # every later change  

Before deploying in your own account, replace the environment-specific values. These include `config.DB_HOST` (RDS endpoint), the domain (`ingress.host`, `SITE_ROOT`, `ALLOWED_HOSTS`), `letsencrypt.email`, the age public key in `.sops.yaml`, and your own encrypted `secrets-values.yaml`. See the [deployment guide](documentation/deployment_guide.md).

See [documentation/deployment_guide.md](documentation/deployment_guide.md) for the deployment steps.
