# IO500 on Kubernetes with DDN EXAScaler

This guide explains how to run the IO500 benchmark in a Kubernetes environment with DDN EXAScaler using mpi-operator and CSI volumes. It covers MPI integration, CSI-based volume configuration, and includes YAML examples for launching benchmark jobs.

## Overview

- Run IO500 using MPIJob via [mpi-operator](https://github.com/kubeflow/mpi-operator)
- Access EXAScaler storage with [exa-csi-driver](https://github.com/DDNStorage/exa-csi-driver)
- Provides templates for StorageClass, PVC, ConfigMap, and MPIJob
- Build the container image locally and load it on the worker nodes (no registry needed)

> All addresses, host names and paths in this guide are placeholders. Replace them with your own.
> Addresses use the documentation range `192.0.2.0/24`.

## Prerequisites

* Kubernetes cluster
* [mpi-operator](https://github.com/kubeflow/mpi-operator) installed
* [DDN EXAScaler CSI driver](https://github.com/DDNStorage/exa-csi-driver) `v2.4.0` installed
* Lustre client installed on every worker node

## Quick Start

### 1. Confirm that the Kubernetes cluster has at least 10 available worker nodes
For example, a 16-node cluster with 1 control-plane node and 15 worker nodes, of which 5 are cordoned so that exactly 10 worker nodes run IO500.

Check the current node status:
```bash
kubectl get node
```
Example output:
```bash
NAME     STATUS                     ROLES           AGE   VERSION
node01   Ready                      control-plane   89d   v1.31.5
node02   Ready                      <none>          89d   v1.31.5
...
node11   Ready                      <none>          89d   v1.31.5
node12   Ready,SchedulingDisabled   <none>          89d   v1.31.5
...
node16   Ready,SchedulingDisabled   <none>          89d   v1.31.5
```
> In this example, node01 is the control-plane node, and node02 through node11 are the 10 worker nodes used for IO500.

### 2. Install mpi-operator
IO500 requires MPI. The MPI Operator runs distributed MPI jobs across multiple Pods.
```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
```
Verify that the operator Pod is running:
```bash
kubectl get pod -A | grep mpi-operator
```

### 3. Install EXAScaler CSI driver
This guide uses `v2.4.0`:
```bash
git clone -b v2.4.0 https://github.com/DDNStorage/exa-csi-driver.git
kubectl create ns exa-csi
helm install -n exa-csi exascaler-csi-file-driver exa-csi-driver/deploy/helm-chart/
```
Verify that the driver pods are running and the version:
```bash
kubectl get pod -n exa-csi
kubectl -n exa-csi get ds exascaler-csi-node -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

### 4. Create StorageClass for EXAScaler for IO500
Edit `io500-sc.yaml` for your site before applying it:
- `exaFS`: `<MGS-NID-1>:<MGS-NID-2>:/<fsname>/<subdir>` (e.g. `192.0.2.10@o2ib:192.0.2.11@o2ib:/exafs/k8s`)
- `mountPoint`: the client mount point (e.g. `/exafs`)
- `exaMountUid`: the uid of the benchmark user

```bash
kubectl apply -f io500-k8s/io500-sc.yaml
```
> **NOTE:** Bind mount is **enabled by default** in EXAScaler CSI (`bindMount: "true"`): the pods on a node share one Lustre mount.
> This guide runs a few IO500 pods per node and sets `bindMount: "false"`, so that every pod gets its own Lustre client.
> Keep the default (`"true"`) when many pods per node use the volume: every Lustre client has its own connections,
> cache and locks, so hundreds of clients per node waste client memory and load the servers.

### 4.1 Set the Lustre client parameters on the MGS
Set the client parameters once on the MGS (EXAScaler administrator). Every client gets them when it mounts:
```bash
lctl set_param -P osc.*.max_rpcs_in_flight=32
lctl set_param -P osc.*.checksums=0
lctl set_param -P ldlm.namespaces.*.lru_max_age=5000
lctl set_param -P llite.*.max_read_ahead_mb=2048
lctl set_param -P llite.*.max_read_ahead_per_file_mb=128
lctl set_param -P llite.*.max_read_ahead_whole_mb=16
lctl set_param -P llite.*.max_cached_mb=4096
```
These apply to all clients of the file system and are lost when the file system is reformatted; set them again after a reformat.
To check on a worker node while IO500 runs: `lctl get_param osc.*.checksums llite.*.max_read_ahead_mb`.

### 5. Build the IO500 image and load it on every worker node
Build the image (IO500 pinned to the io500-sc26 tag; IOR commit optional), then load it directly into containerd on each worker node:
```bash
sudo docker build -t io500:sc26 \
  --build-arg IO500_REF=io500-sc26 [--build-arg IOR_REF=<ior-commit>] \
  -f io500-k8s/Dockerfile-isc25 io500-k8s
for n in <worker-nodes>; do
  sudo docker save io500:sc26 | ssh $n sudo ctr -n k8s.io images import -
done
```
`io500.yaml` uses `image: io500:sc26` with `imagePullPolicy: IfNotPresent`, so no container registry is needed.
> If you prefer a registry, tag and push the image to your own registry and change `image:` accordingly.
> `Dockerfile-sc26` builds an MPICH 5.0.2 image (UCX, ROMIO Lustre driver) instead. It needs the Lustre client packages in `debs/` and an MPICH MPIJob (`mpiImplementation: MPICH`).

### 6. Create a namespace and access for the benchmark user
`gen-k8s-user.sh` creates a namespace `ns-<username>`, a ServiceAccount `<username>` in it, a Role limited to that namespace, and a kubeconfig with a short-lived token.

```bash
./io500-k8s/gen-k8s-user.sh <username> [token-duration]
```
Example (token valid for 7 days, the default):
```bash
./io500-k8s/gen-k8s-user.sh bmuser 168h
```
The script writes `<username>.kubeconfig`. Install it as the default kubeconfig of the Linux user that runs the benchmark, readable only by that user:
```bash
install -D -m 600 bmuser.kubeconfig ~bmuser/.kube/config
```
Then, as that user, verify access:
```bash
kubectl get pods
```
Expected output:
```plaintext
No resources found in ns-bmuser namespace.
```
- **Never commit `*.kubeconfig`**, keys or certificates. They are listed in `.gitignore`.
- To renew access, rerun the script. To revoke access immediately:
  ```bash
  kubectl -n ns-bmuser delete serviceaccount bmuser
  ```

### 7. Run IO500
All steps in this section are performed as the benchmark user, with the kubeconfig from step 6.

#### 7.1 Create a PVC for IO500
Create a PersistentVolumeClaim that IO500 uses for its benchmark files. All IO500 pods share this one PVC.
The capacity becomes a project quota on the PVC directory, so set it larger than everything IO500 writes (for example `400Ti`); adjust `io500-pvc.yaml` for your environment.
```bash
kubectl apply -f io500-k8s/io500-pvc.yaml
kubectl get pvc
```
The PVC `io500-pvc` should be `Bound` with storage class `io500-sc`.

#### 7.2 Generate myio500.sh and myio500.ini
The image does not include `io500.sh` or `io500.ini`, as these are site-specific. They are provided through a ConfigMap.

Start a temporary pod, generate the default ini and copy both files out:
```bash
kubectl run io500-init --image=io500:sc26 --image-pull-policy=IfNotPresent --restart=Never --command -- sleep 3600
kubectl exec io500-init -- /bin/bash -c "/io500/io500 --list > /io500/myio500.ini"
kubectl cp io500-init:/io500/io500.sh ./myio500.sh
kubectl cp io500-init:/io500/myio500.ini ./myio500.ini
kubectl delete pod io500-init
```

#### 7.3 Modify myio500.sh and myio500.ini and register them as a ConfigMap
Example: run 20 MPI processes across 20 Pods (1 process per Pod), spread over 10 worker nodes.

In `io500-k8s/io500.yaml`:
```yaml
    Worker:
      replicas: 20
```
In `myio500.sh`:
```bash
io500_mpirun="mpirun"
io500_mpiargs="--allow-run-as-root -np 20"
```
Create the ConfigMap:
```bash
kubectl create configmap io500-user-config \
  --from-file=myio500.sh=myio500.sh \
  --from-file=myio500.ini=myio500.ini
```

#### 7.4 Run IO500 using MPIJob
```bash
kubectl apply -f io500-k8s/io500.yaml
kubectl get pod -o wide
```
You should see 1 launcher pod and 20 worker pods spread over the 10 worker nodes.

Follow the progress in the launcher log:
```bash
kubectl logs -f $(kubectl get pod -o name | grep io500-launcher)
```
The first line shows the IO500 version, for example:
```plaintext
IO500 version io500-sc26_v3 (standard)
```

### Additional Notes
#### Update the ConfigMap
After changing `myio500.sh` or `myio500.ini`, update the ConfigMap:
```bash
kubectl create configmap io500-user-config \
  --from-file=myio500.sh=myio500.sh \
  --from-file=myio500.ini=myio500.ini \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Tips
The YAML files in this guide are kept simple. Tips for running IO500 on Kubernetes:

- **Spread the worker pods evenly.** Without a rule, the scheduler may put more pods on some nodes than others. Add this to the Worker template in `io500.yaml`:
  ```yaml
          topologySpreadConstraints:
          - maxSkew: 1
            topologyKey: kubernetes.io/hostname
            whenUnsatisfiable: DoNotSchedule
            labelSelector:
              matchLabels: {training.kubeflow.org/job-name: io500, training.kubeflow.org/job-role: worker}
  ```
- **A few pods per node, each with its own Lustre client.** With `bindMount: "false"`, every pod is a separate Lustre client. Several pods per node (we used 8) scale better than one, but keep the number small (see the note in step 4).
- **Pin CPUs.** Give worker pods equal `requests` and `limits` for CPU and memory (Guaranteed QoS), and enable the kubelet static CPU manager (`cpuManagerPolicy: static`, `topologyManagerPolicy: single-numa-node`). Each pod then gets dedicated CPUs on one socket.
- **If ior-hard uses collective MPI-IO:**
  1. The pods need high network bandwidth between them, because collective I/O exchanges the data over MPI before it is written.
  2. An MPI built with ROMIO's Lustre driver can be used (optional).
- **Using `lfs` in `setup()`.** To set Lustre layouts for the IO500 directories (for example `lfs setstripe` for ior-hard or `lfs setdirstripe` for mdtest), the launcher pod needs the `lfs` command.
  `Dockerfile-sc26` installs it in the image from the Lustre client packages in `debs/`.
  With `Dockerfile-isc25`, mount the host's `lfs` into the launcher pod instead (the launcher node needs `lustre-client-utils`):
  ```yaml
              volumeMounts:
                - {name: lfs, mountPath: /usr/bin/lfs, readOnly: true}
                - {name: lustreapi, mountPath: /usr/lib/liblustreapi.so.1, readOnly: true}
                - {name: lnetconfig, mountPath: /usr/lib/liblnetconfig.so.4, readOnly: true}
          volumes:
            - {name: lfs, hostPath: {path: /usr/bin/lfs, type: File}}
            - {name: lustreapi, hostPath: {path: /usr/lib/liblustreapi.so.1.0.0, type: File}}
            - {name: lnetconfig, hostPath: {path: /usr/lib/liblnetconfig.so.4.0.0, type: File}}
  ```
  The library paths are those of Ubuntu clients (RHEL-family clients use `/usr/lib64`). `lfs` also needs `libreadline8` and `libjson-c5` in the image.
- **Lustre client parameters** are set once on the MGS (step 4.1). Newer EXA CSI driver versions can instead set them per client in the StorageClass (`exaParams`). Check them on a node during the run with `lctl get_param`.

## Security notes
- Do not commit kubeconfigs, keys or certificates; `.gitignore` covers `*.kubeconfig`, `*.key`, `*.crt`, `*.csr`.
- The repository contains placeholders only; replace addresses and host names with your own locally.
- Access tokens are short-lived; revoke access by deleting the ServiceAccount.
- The benchmark user's Role is limited to its own namespace and cannot change RBAC.
