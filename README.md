# IO500 on Kubernetes with DDN EXAScaler

This guide explains how to run the IO500 benchmark in a Kubernetes environment with DDN EXAScaler using mpi-operator and CSI volumes. It covers MPI integration, CSI-based volume configuration, and includes practical YAML examples for launching benchmark jobs.

## Overview

- Run IO500 using MPIJob via [mpi-operator](https://github.com/kubeflow/mpi-operator)
- Access EXAScaler storage with [exa-csi-driver](https://github.com/DDNStorage/exa-csi-driver)
- Provides templates for PersistentVolume, StorageClass, PVC, ConfigMap, and MPIJob
- Build and configure container images for benchmark workloads

## Prerequisites

* Kubernetes cluster
* [mpi-operator](https://github.com/kubeflow/mpi-operator) installed
* [DDN EXAScaler CSI driver](https://github.com/DDNStorage/exa-csi-driver) installed

## Quick Start

### 1. Confirm that the Kubernetes cluster has at least 10 available worker nodes
For example, the following is a 16-node cluster (1 control-plane node + 15 worker nodes). 5 worker nodes are cordoned, and only 10 worker nodes are used for the IO500 benchmark.

For example, the following is a 16-node Kubernetes cluster consisting of:
- 1 control-plane node (src01v)
- 15 worker nodes (src02v–src16v)

Check the current node status using:
```bash
kubectl get node
```
Example output:
```bash
NAME     STATUS                     ROLES           AGE   VERSION
src01v   Ready                      control-plane   89d   v1.31.5
src02v   Ready                      <none>          89d   v1.31.5
src03v   Ready                      <none>          89d   v1.31.5
src04v   Ready                      <none>          89d   v1.31.5
src05v   Ready                      <none>          89d   v1.31.5
src06v   Ready                      <none>          89d   v1.31.5
src07v   Ready                      <none>          89d   v1.31.5
src08v   Ready                      <none>          89d   v1.31.5
src09v   Ready                      <none>          89d   v1.31.5
src10v   Ready                      <none>          89d   v1.31.5
src11v   Ready                      <none>          89d   v1.31.5
src12v   Ready,SchedulingDisabled   <none>          89d   v1.31.5
src13v   Ready,SchedulingDisabled   <none>          89d   v1.31.5
src14v   Ready,SchedulingDisabled   <none>          89d   v1.31.5
src15v   Ready,SchedulingDisabled   <none>          89d   v1.31.5
src16v   Ready,SchedulingDisabled   <none>          89d   v1.31.5
```
> In this example, src01v is the control-plane node, and src02v through src11v are the 10 available worker nodes for IO500.

### 2. Install mpi-operator
IO500 requires MPI to run, and the MPI Operator allows you to run distributed MPI jobs across multiple Pods in a Kubernetes cluster.
Install the MPI Operator using the following command:
```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
```
Verify that the operator Pod is running:
```bash
kubectl get pod -A | grep mpi-operator
```
Example output:
```bash
mpi-operator             mpi-operator-84b4b8dbf4-v9ktf                                     1/1     Running   0               24s
```

### 3. Install EXAScaler CSI driver
Find the latest version of EXA-CSI at https://github.com/DDNStorage/exa-csi-driver/releases.
Then, clone the repository using the desired version tag (e.g., 2.3.5):
```bash
git clone -b 2.3.5 https://github.com/DDNStorage/exa-csi-driver.git
```
Create a dedicated namespace for the CSI driver:
```bash
kubectl create ns exa-csi
```
Install the driver using Helm:
```bash
helm install -n exa-csi exascaler-csi-file-driver exa-csi-driver/deploy/helm-chart/
```
Verify that the driver pods are running:
```bash
kubectl get pod -n exa-csi
```
Example output:
```bash
NAME                                        READY   STATUS    RESTARTS   AGE
exascaler-csi-controller-55555d9d67-g8jwr   5/5     Running   0          18s
exascaler-csi-node-2ktnz                    2/2     Running   0          18s
exascaler-csi-node-4247m                    2/2     Running   0          18s
exascaler-csi-node-585rq                    2/2     Running   0          18s
exascaler-csi-node-76lgn                    2/2     Running   0          18s
exascaler-csi-node-959hf                    2/2     Running   0          18s
...
```

### 4. Create StorageClass for EXAScaler for IO500
You need to modify the exaFS and mountPoint fields in the io500-sc.yaml file to match your EXAScaler environment before applying it.
```bash
kubectl apply -f io500-k8s/io500-sc.yaml
```
> NOTE: Bind mount is enabled by default in EXAScaler CSI, but it is explicitly disabled here to maximize performance across 10 clients.

### 5. Build the IO500 container image and push it to the local registry
Use the following commands to build the IO500 image:
```bash
sudo docker build -t 172.16.44.253:5000/bmuser/io500:latest -f io500-k8s/Dockerfile io500-k8s
```
Then, push it to your local container registry:
```bash
sudo docker push 172.16.44.253:5000/bmuser/io500:latest
```
> **Note:** Replace `172.16.44.253:5000` with the address of your own local container registry.

### 6. Create a namespace and user in Kubernetes for the benchmark
The `gen-k8s-user.sh` script creates a dedicated namespace, Kubernetes user, and sets up RBAC permissions for the benchmark.

By default, the namespace is named `ns-<username>`. For example, if the username is `bmuser`, the namespace will be `ns-bmuser`.

In this guide, the same username (`bmuser`) is used both as the Kubernetes user and as the corresponding Linux user on the IO500 client machine.

```bash
./io500-k8s/gen-k8s-user.sh <username>
```
Example:
```bash
./io500-k8s/gen-k8s-user.sh bmuser
```
The script generates a file named <username>.kubeconfig, which should be copied to the machine where the IO500 benchmark will run—typically as the Linux user with the same name.
> Note: If your Kubernetes username differs from your Linux username, ensure proper permissions and kubeconfig path mappings are handled accordingly.

The `bmuser.kubeconfig` file needs to be copied to the Linux user's (`bmuser`) home directory as the default kubeconfig:
```bash
cp <path>/bmuser.kubeconfig <path-to-bmuser-home>/.kube/config
```
Then, switch to the bmuser Linux user and verify access to the Kubernetes cluster:
```bash
kubectl get pods
```
Expected output:
```plantext
No resources found in ns-bmuser namespace.
```
Now that the user `bmuser` environment is set up, you are ready to prepare and submit the IO500 benchmark job.

### 7. Run IO500
All steps in this section should be performed as the `bmuser` Linux user, using the `bmuser.kubeconfig` file created earlier.

Make sure the kubeconfig is correctly set (e.g., `~/.kube/config` points to `bmuser.kubeconfig`) before proceeding.
#### 7.1 Create PVC for IO500
Create a PersistentVolumeClaim (PVC) that IO500 will use to write its benchmark files.

The storage capacity specified in `io500-pvc.yaml` should be adjusted to suit your environment.

```bash
kubectl apply -f io500-k8s/io500-pvc.yaml
```
Verify that the PVC is bound:
```bash
kubectl get pvc
```
Expected output:
```plaintext
NAME        STATUS   VOLUME                                         CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
io500-pvc   Bound    pvc-exa-ba0b1568-0a14-4956-955e-574a510276af   1Ti        RWX            io500-sc       <unset>                 6s
```

#### 7.2 Generate myio500.sh and myio500.ini
The container image does not include `io500.sh` or `io500.ini`, as these files typically require user-specific customization. Instead, they are mounted into the container using a Kubernetes ConfigMap.

Start a temporary pod to generate the default `io500.ini` and retrieve the script:
```bash
kubectl run io500-init --image=172.16.44.253:5000/bmuser/io500:latest --restart=Never --command -- sleep 3600
```
Generate myio500.ini from the io500 --list command:
```bash
kubectl exec -it io500-init -- /bin/bash -c "/io500/io500 --list | tee /io500/myio500.ini"
```
Copy io500.sh and the generated myio500.ini from the container to your local directory:
```bash
kubectl cp ns-bmuser/io500-init:/io500/io500.sh ./myio500.sh
```
```bash
kubectl cp ns-bmuser/io500-init:/io500/myio500.ini ./myio500.ini
```
Delete the temporary io500-init pod after copying the files:
```bash
kubectl delete pod io500-init -n ns-bmuser
```
#### 7.3 Modify myio500.sh and myio500.ini and register them as a ConfigMap
Modify myio500.sh and myio500.ini for your environments, and register them as a ConfigMap.

Example: run 20 MPI processes across 20 Pods (1 process per Pod), spread over 10 worker nodes.
In `io500-k8s/io500.yaml`:
```bash
    Worker:
      replicas: 20
```
In myio500.sh:
```bash
io500_mpirun="mpirun"
io500_mpiargs="--allow-run-as-root -np 20"
```
Create a ConfigMap from the modified files:
```bash
kubectl create configmap io500-user-config \
--from-file=myio500.sh=myio500.sh \
--from-file=myio500.ini=myio500.ini
```

#### 7.3 Run io500 using MPIJob
Apply the MPIJob configuration to start the IO500 benchmark:
```bash
kubectl apply -f io500-k8s/io500.yaml
```
Check the status of the Pods:
```bash
kubectl get pod -o wide
```
```bash
Example output (20 worker pods and 1 launcher pod running across 10 worker nodes):
NAME                   READY   STATUS    RESTARTS   AGE   IP             NODE     NOMINATED NODE   READINESS GATES
io500-launcher-wl8c2   1/1     Running   0          6s    10.244.8.2     src09v   <none>           <none>
io500-worker-0         1/1     Running   0          9s    10.244.18.4    src06v   <none>           <none>
io500-worker-1         1/1     Running   0          9s    10.244.13.8    src07v   <none>           <none>
io500-worker-10        1/1     Running   0          8s    10.244.14.8    src10v   <none>           <none>
io500-worker-11        1/1     Running   0          7s    10.244.2.141   src03v   <none>           <none>
io500-worker-12        1/1     Running   0          7s    10.244.1.214   src02v   <none>           <none>
io500-worker-13        1/1     Running   0          7s    10.244.7.6     src05v   <none>           <none>
io500-worker-14        1/1     Running   0          7s    10.244.3.6     src04v   <none>           <none>
io500-worker-15        1/1     Running   0          7s    10.244.13.9    src07v   <none>           <none>
io500-worker-16        1/1     Running   0          6s    10.244.18.5    src06v   <none>           <none>
io500-worker-17        1/1     Running   0          6s    10.244.8.254   src09v   <none>           <none>
io500-worker-18        1/1     Running   0          6s    10.244.17.18   src08v   <none>           <none>
io500-worker-19        1/1     Running   0          6s    10.244.11.13   src11v   <none>           <none>
io500-worker-2         1/1     Running   0          9s    10.244.1.213   src02v   <none>           <none>
io500-worker-3         1/1     Running   0          9s    10.244.8.253   src09v   <none>           <none>
io500-worker-4         1/1     Running   0          9s    10.244.3.5     src04v   <none>           <none>
io500-worker-5         1/1     Running   0          9s    10.244.2.140   src03v   <none>           <none>
io500-worker-6         1/1     Running   0          8s    10.244.11.12   src11v   <none>           <none>
io500-worker-7         1/1     Running   0          8s    10.244.14.7    src10v   <none>           <none>
io500-worker-8         1/1     Running   0          8s    10.244.17.17   src08v   <none>           <none>
io500-worker-9         1/1     Running   0          8s    10.244.7.5     src05v   <none>           <none>
```
As shown above, IO500 runs across 20 Pods distributed over 10 worker nodes.

To monitor progress in real time, check the logs of the launcher Pod:
```bash
kubectl logs io500-launcher-xxxxx
```
Example output:
```bash
IO500 version io500-isc25_v1 (standard)
```

### Additional Notes
#### Update the ConfigMap
If you want to modify myio500.sh or myio500.ini, you need to update the io500-user-config ConfigMap after making changes.
```bash
kubectl create configmap io500-user-config \
--from-file=myio500.sh=myio500.sh \
--from-file=myio500.ini=myio500.ini \
--dry-run=client -o yaml | kubectl apply -f -
```
