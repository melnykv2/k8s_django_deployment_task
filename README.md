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

## Before deploying

Before deploying in your own account, replace the environment-specific values. These include `config.DB_HOST` (RDS endpoint), the domain (`ingress.host`, `SITE_ROOT`, `ALLOWED_HOSTS`), `letsencrypt.email`, the age public key in `.sops.yaml`, and your own encrypted `secrets-values.yaml`. See the [deployment guide](documentation/deployment_guide.md).

## Verification after deployment

```
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get nodes
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-15-70.ec2.internal   Ready    <none>   14m   v1.34.11-eks-3b4a6ca
ip-192-168-55-14.ec2.internal   Ready    <none>   14m   v1.34.11-eks-3b4a6ca
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get pods -A
NAMESPACE       NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager    cert-manager-bc44b5799-vv5jb               1/1     Running   0          9m54s
cert-manager    cert-manager-cainjector-784846b495-tntxn   1/1     Running   0          9m54s
cert-manager    cert-manager-webhook-6c6d98f866-bblhw      1/1     Running   0          9m54s
default         healthchecks-6f7bbfb4d8-qnwg4              1/1     Running   0          9m3s
default         healthchecks-6f7bbfb4d8-wtktd              1/1     Running   0          9m3s
ingress-nginx   ingress-nginx-controller-6fd7d65fb-jqp7p   1/1     Running   0          9m42s
kube-system     aws-node-lrhvl                             2/2     Running   0          15m
kube-system     aws-node-tb9r6                             2/2     Running   0          15m
kube-system     coredns-7d68d7c46f-g6z6n                   1/1     Running   0          18m
kube-system     coredns-7d68d7c46f-lmn9h                   1/1     Running   0          18m
kube-system     kube-proxy-6z7f6                           1/1     Running   0          15m
kube-system     kube-proxy-hlbph                           1/1     Running   0          15m
kube-system     metrics-server-7df5968978-jw4f2            1/1     Running   0          13m
kube-system     metrics-server-7df5968978-prwfl            1/1     Running   0          13m
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get deploy,svc,ingress,hpa,configmap,secret -n default
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/healthchecks   2/2     2            2           9m8s

NAME                   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/healthchecks   ClusterIP   10.100.60.25   <none>        80/TCP    9m8s
service/kubernetes     ClusterIP   10.100.0.1     <none>        443/TCP   21m

NAME                                     CLASS   HOSTS                 ADDRESS                                                                         PORTS     AGE
ingress.networking.k8s.io/healthchecks   nginx   hc.vadymthebest.com   acaaf8dbe6d584ee9b42717a10c3352f-87b42e2468977665.elb.us-east-1.amazonaws.com   80, 443   9m7s

NAME                                               REFERENCE                 TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/healthchecks   Deployment/healthchecks   cpu: 2%/80%, memory: 32%/80%   2         4         2          9m7s

NAME                            DATA   AGE
configmap/healthchecks-config   9      9m9s
configmap/kube-root-ca.crt      1      20m

NAME                                        TYPE                 DATA   AGE
secret/healthchecks-secret                  Opaque               2      9m9s
secret/healthchecks-tls                     kubernetes.io/tls    2      3m18s
secret/sh.helm.release.v1.healthchecks.v1   helm.sh/release.v1   1      9m9s
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get certificate,clusterissuer
NAME                                           READY   SECRET             AGE
certificate.cert-manager.io/healthchecks-tls   True    healthchecks-tls   9m13s

NAME                                             READY   AGE
clusterissuer.cert-manager.io/letsencrypt-prod   True    9m13s
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get svc -n ingress-nginx ingress-nginx-controller
NAME                       TYPE           CLUSTER-IP       EXTERNAL-IP                                                                     PORT(S)                      AGE
ingress-nginx-controller   LoadBalancer   10.100.213.249   acaaf8dbe6d584ee9b42717a10c3352f-87b42e2468977665.elb.us-east-1.amazonaws.com   80:31985/TCP,443:30742/TCP   9m57s
vadymmelnyk@Macbook k8s_django_deployment_task % helm list -A
NAME            NAMESPACE       REVISION        UPDATED                                 STATUS          CHART                   APP VERSION
cert-manager    cert-manager    1               2026-10-14 22:32:08.534478 +0300 EEST   deployed        cert-manager-v1.21.2    v1.21.2
healthchecks    default         1               2026-10-14 22:33:07.17023 +0300 EEST    deployed        django-app-0.1.0        1.0.0
ingress-nginx   ingress-nginx   1               2026-10-14 22:32:08.485607 +0300 EEST   deployed        ingress-nginx-4.15.1    1.15.1
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get hpa healthchecks -w
NAME           REFERENCE                 TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
healthchecks   Deployment/healthchecks   cpu: 2%/80%, memory: 32%/80%   2         4         2          11m
healthchecks   Deployment/healthchecks   cpu: 72%/80%, memory: 32%/80%   2         4         2          11m
healthchecks   Deployment/healthchecks   cpu: 236%/80%, memory: 32%/80%   2         4         2          12m
healthchecks   Deployment/healthchecks   cpu: 221%/80%, memory: 32%/80%   2         4         4          12m
```
