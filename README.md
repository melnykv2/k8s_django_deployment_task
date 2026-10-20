# k8s_django_deployment_task

Deploys the **Healthchecks** Django application (`melnykv2/healthchecks`) to **AWS EKS** with Helm and helmfile. The database runs in **Amazon RDS (PostgreSQL)**. HTTPS uses a **Let's Encrypt** certificate issued by cert-manager. Static files are stored on a shared **Amazon EFS** volume mounted through a PersistentVolume (see [Persistent storage](#persistent-storage)).

## Repository structure

```
├── helm_chart/                    # Application chart
│   ├── Chart.yaml
│   ├── values.yaml                # All non-secret settings (image, domain, RDS host, HPA, ...)
│   ├── secrets-values.yaml        # Secret values, encrypted with sops + age (helm-secrets)
│   └── templates/
│       ├── configmap.yaml         # Non-secret env vars
│       ├── secrets.yaml           # Secret env vars (DB password, Django SECRET_KEY)
│       ├── deployment.yaml        # 2 replicas, port 8080, envFrom, probes, migrate + copy-static initContainers
│       ├── service.yaml           # ClusterIP
│       ├── ingress.yaml           # ingress-nginx + TLS via cert-manager
│       ├── cluster-issuer.yaml    # Let's Encrypt (prod) ClusterIssuer
│       ├── hpa.yaml               # 2–4 replicas at 80% CPU / memory
│       ├── storage-class.yaml     # efs-sc StorageClass (EFS CSI driver, Retain)
│       ├── pv.yaml                # Static PV on EFS (ReadWriteMany) through an access point
│       └── pvc.yaml               # Claim bound to that PV, mounted by every pod
├── helmfile/helmfile.yaml         # Whole environment: ingress-nginx, cert-manager, app
├── infra/eks-cluster.yaml         # eksctl cluster definition (+ OIDC and EFS CSI driver addon)
├── .sops.yaml                     # sops rule: which file is encrypted, with which age key
└── documentation/deployment_guide.md
```

## Before deploying

Before deploying in your own account, replace the environment-specific values. These include `config.DB_HOST` (RDS endpoint), the domain (`ingress.host`, `SITE_ROOT`, `ALLOWED_HOSTS`), `letsencrypt.email`, the EFS IDs (`storage.efsFileSystemId`, `storage.efsAccessPointId`), the age public key in `.sops.yaml`, and your own encrypted `secrets-values.yaml`. See the [deployment guide](documentation/deployment_guide.md).

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

## Persistent storage

### The problem

A container's filesystem is temporary. When a pod restarts, is rescheduled, or is replaced during a rollout or an HPA scale-down, everything it wrote is lost. Kubernetes solves this by keeping storage separate from pods, using three objects.

### PersistentVolume (PV)

A PV represents a real piece of storage, such as an AWS EBS disk, an EFS filesystem or an NFS share. It is a cluster-wide object, not namespaced, and it exists independently of any pod. It describes:

- **capacity**, for example `1Gi`
- **access modes**:
  - `ReadWriteOnce` (RWO): read-write from a single node (EBS)
  - `ReadOnlyMany` (ROX): read-only from many nodes
  - `ReadWriteMany` (RWX): read-write from many nodes (EFS, NFS)
  - `ReadWriteOncePod`: a single pod only
- **reclaim policy**: what happens to the data after the claim is deleted. `Retain` keeps it, and `Delete` destroys the backing storage.
- **backend**: the driver and the identifier of the real storage, e.g. `csi.driver: efs.csi.aws.com` and `volumeHandle`.

### PersistentVolumeClaim (PVC)

A PVC is an application's **request** for storage, for example "1Gi, ReadWriteMany, class `efs-sc`". It is namespaced and is part of the application's chart. Pods never reference a PV directly. They mount a PVC, and Kubernetes **binds** each PVC to exactly one matching PV. A matching PV has the same storage class, compatible access modes and enough capacity. Once bound, both show `STATUS: Bound`.

This split separates responsibilities. The application declares *what* it needs, and the cluster decides *where* it comes from.

### StorageClass

A StorageClass describes a *type* of storage and who provides it:

- `provisioner`: the CSI driver that talks to the storage system, e.g. `efs.csi.aws.com` or `ebs.csi.aws.com`
- `parameters`: driver-specific settings, e.g. disk type or EFS mode
- `reclaimPolicy` and `volumeBindingMode`: `Immediate`, or `WaitForFirstConsumer`, which waits until a pod is scheduled so that zonal disks are created in the right availability zone

It has two jobs: it groups PVs and PVCs for matching by `storageClassName`, and it enables **dynamic provisioning**.

### How they work together

```
 Pod ──mounts──▶ PVC ──bound 1:1──▶ PV ──CSI driver──▶ real storage (EFS)
                  │                  ▲
                  └─ storageClassName ── StorageClass ── creates PVs automatically (dynamic only)
```

- **Static provisioning**: an administrator creates the storage and a PV that points to it. A PVC then binds to that existing PV. **This project uses static provisioning.**
- **Dynamic provisioning**: only a PVC is written. The StorageClass's provisioner creates the storage and the PV automatically. Most production clusters work this way.

Lifecycle: **provision → bind → use (pods mount the PVC) → release (PVC deleted) → reclaim (Retain / Delete)**.

### Implementation in this project

**Why EFS and not EBS.** The application runs 2–4 replicas spread over 2 nodes in different availability zones, and all of them must read the same files. EBS volumes are `ReadWriteOnce` and zonal, so a second pod on another node would fail with a `Multi-Attach error`. EFS is `ReadWriteMany` and regional, so every pod on every node can mount it at the same time.

| File | What it defines |
|---|---|
| `storage-class.yaml` | `efs-sc`, provisioner `efs.csi.aws.com`, `reclaimPolicy: Retain` |
| `pv.yaml` | `healthchecks-static-pv`, 1Gi, `ReadWriteMany`, `Retain`, `volumeHandle: <fs-id>::<access-point-id>` |
| `pvc.yaml` | `healthchecks-static-pvc`, same class and access mode, pinned to the PV with `volumeName` |
| `deployment.yaml` | Pod volume `static` from the PVC, mounted by the `copy-static` initContainer and the app container |
| `infra/eks-cluster.yaml` | OIDC and the `aws-efs-csi-driver` addon, so the nodes can mount EFS |

EFS reports no real size limit, but Kubernetes requires `capacity` on a PV, so `1Gi` is only a placeholder.

**EFS access point.** The image runs as uid 1000, while a new EFS filesystem's root directory is owned by root. The access point exposes `/healthchecks-static`, owned by uid/gid 1000, and performs every operation as uid 1000. Without it, writes fail with `Permission denied`.

**How the static files get onto the volume.** The image build already runs `collectstatic` and `compress` in a builder stage and copies the result to `/app/static-collected` (`STATIC_ROOT`). WhiteNoise serves files from there. Mounting a volume on that path hides the image's files, so the `copy-static` initContainer mounts the same volume on `/mnt/static` and copies the built files into it before the app starts:

```
initContainer migrate      → database migrations
initContainer copy-static  → /app/static-collected (image) ──cp──▶ /mnt/static (EFS)
container healthchecks     → /app/static-collected = EFS volume → served by WhiteNoise
```

Running `collectstatic` in the pod is not possible because the final image does not contain the source `static/` directory. It is also unnecessary, because the build has already produced the files.

### Production considerations

A shared volume works, but it is rarely the best choice for **static** files:

- **Rolling updates mix versions.** Old and new pods share one directory, and the new pods overwrite files, including django-compressor's manifest, that the old pods are still serving.
- **Extra dependency.** If EFS is slow or unavailable, every pod is affected, even though the files are already inside the image.
- **Slower reads.** Network storage is slower than files in the image.

In production I would keep static files in the image (WhiteNoise), or upload them to **S3 + CloudFront** in CI. PersistentVolumes are a better fit for data the application *creates at runtime*, such as user uploads (`MEDIA_ROOT`), generated reports, or databases running as StatefulSets with one RWO volume per replica.

### Storage verification

```
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get pv,pvc
NAME                                      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                             STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
persistentvolume/healthchecks-static-pv   1Gi        RWX            Retain           Bound    default/healthchecks-static-pvc   efs-sc         <unset>                          7m59s

NAME                                            STATUS   VOLUME                   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/healthchecks-static-pvc   Bound    healthchecks-static-pv   1Gi        RWX            efs-sc         <unset>                 7m59s
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl get pods -o wide
NAME                            READY   STATUS    RESTARTS   AGE    IP               NODE                             NOMINATED NODE   READINESS GATES
healthchecks-7978785bb9-mfpqk   1/1     Running   0          8m3s   192.168.26.228   ip-192-168-4-254.ec2.internal    <none>           <none>
healthchecks-7978785bb9-r2twb   1/1     Running   0          8m3s   192.168.56.31    ip-192-168-54-119.ec2.internal   <none>           <none>
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl exec deploy/healthchecks -- ls /app/static-collected
CACHE
admin
css
fonts
img
js
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl exec deploy/healthchecks -- sh -c "mount | grep static-collected"
127.0.0.1:/ on /app/static-collected type nfs4 (rw,relatime,vers=4.1,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,proto=tcp,port=20611,timeo=600,retrans=2,sec=sys,clientaddr=127.0.0.1,local_lock=none,addr=127.0.0.1)
vadymmelnyk@Macbook k8s_django_deployment_task % curl -I https://hc.vadymthebest.com/static/img/favicon.svg
HTTP/2 200
content-type: image/svg+xml
```

Shared across nodes and persistent across pod restarts:

```
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl exec $POD1 -- sh -c "echo hello > /app/static-collected/pv-test.txt"
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl exec $POD2 -- cat /app/static-collected/pv-test.txt
hello
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl delete pods -l app=healthchecks
pod "healthchecks-7978785bb9-mfpqk" deleted from default namespace
pod "healthchecks-7978785bb9-r2twb" deleted from default namespace
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl rollout status deploy/healthchecks
deployment "healthchecks" successfully rolled out
vadymmelnyk@Macbook k8s_django_deployment_task % kubectl exec deploy/healthchecks -- cat /app/static-collected/pv-test.txt
hello
```
