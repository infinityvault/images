# nfs-server

This Docker image provides an NFS server based on Alpine Linux, inspired by
[sjiveson/nfs-server-alpine](https://github.com/sjiveson/nfs-server-alpine). It allows you to
export directories over NFS, with optional support for mounting and decrypting block devices before
serving them.

The main purpose of creating this image was to access an external hard drive in Talos Linux.

## Features

- NFSv4 server
- Optionally mounts a block device to the shared directory
- Supports LUKS-encrypted devices (decrypted using `cryptsetup`)

## Configuration Options

All configuration is done via environment variables:

|Variable|Required|Default|Description|
|-|-|-|-|
|`SHARED_DIRECTORY`|✅|`-`|Directory to mount the device to and export via NFS.|
|`DEVICE_PATH`|❌|`-`|Path to the block device to mount (e.g. `/dev/external-hdd`).|
|`DEVICE_PASSWORD`|❌|`-`|Password for LUKS decryption. If set, device is decrypted before mounting.|
|`PERMITTED`|❌|*All Hosts*|Hosts allowed to connect via NFS.|
|`READ_ONLY`|❌|*Read/Write*|Only allow read access to shared directory.|
|`SYNC`|❌|*Async*|Write to disk immediately.|

If `DEVICE_PATH` and `DEVICE_PASSWORD` are set, the image will decrypt and mount the device before
starting the NFS server. If only `DEVICE_PATH` is set, the device will be mounted directly.

## Usage in Talos Linux

### Server

The server needs to be started in privileged mode.

```yaml
# Namespace
apiVersion: v1
kind: Namespace
metadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged
  name: nfs-server

---

# Secret (for drive encryption password)
apiVersion: v1
kind: Secret
metadata:
  name: nfs-server
  namespace: nfs-server
stringData:
  DEVICE_PASSWORD: P@ssw0rd

---

# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: nfs-server
  labels:
    app: nfs-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  strategy:
    type: Recreate  # required because of hostNetwork (blocks port on host)
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      containers:
        - name: nfs-server
          image: ghcr.io/infinityvault/nfs-server
          securityContext:
            privileged: true  # required for NFS
          env:
            - name: SHARED_DIRECTORY
              value: /mnt/nfs
            - name: DEVICE_PATH
              value: /dev/external-hdd
          envFrom:
            - secretRef:
                name: nfs-server  # device encryption password
          ports:
            - name: nfs
              containerPort: 2049
          volumeMounts:
            - mountPath: /dev/external-hdd
              name: external-hdd
      hostNetwork: true
      volumes:
        - name: external-hdd
          hostPath:
            path: /dev/disk/by-uuid/b039a510-fb03-48c9-a0a7-a31ac267492b
```

The logs should look like this:

```text
[nfs-server] DEVICE_PATH specified: /dev/external-hdd
[nfs-server] Decrypting device /dev/external-hdd with cryptsetup.
[nfs-server] Device decrypted and available at /dev/mapper/drive.
[nfs-server] Mounting /dev/mapper/drive to /mnt/nfs.
[nfs-server] Mount successful.
[nfs-server] Starting NFS service.
Writing SHARED_DIRECTORY to /etc/exports file
The PERMITTED environment variable is unset or null, defaulting to '*'.
This means any client can mount.
The READ_ONLY environment variable is unset or null, defaulting to 'rw'.
Clients have read/write access.
The SYNC environment variable is unset or null, defaulting to 'async' mode.
Writes will not be immediately written to disk.
Displaying /etc/exports contents:
/mnt/nfs *(rw,fsid=0,async,no_subtree_check,no_auth_nlm,insecure,no_root_squash)

Starting rpcbind...
Displaying rpcbind status...
   program version netid     address                service    owner
    100000    4    tcp6      ::.0.111               -          superuser
    100000    3    tcp6      ::.0.111               -          superuser
    100000    4    udp6      ::.0.111               -          superuser
    100000    3    udp6      ::.0.111               -          superuser
    100000    4    tcp       0.0.0.0.0.111          -          superuser
    100000    3    tcp       0.0.0.0.0.111          -          superuser
    100000    2    tcp       0.0.0.0.0.111          -          superuser
    100000    4    udp       0.0.0.0.0.111          -          superuser
    100000    3    udp       0.0.0.0.0.111          -          superuser
    100000    2    udp       0.0.0.0.0.111          -          superuser
    100000    4    local     /var/run/rpcbind.sock  -          superuser
    100000    3    local     /var/run/rpcbind.sock  -          superuser
Starting NFS in the background...
rpc.nfsd: knfsd is currently down
rpc.nfsd: Writing version string to kernel: -2 -3
rpc.nfsd: Created AF_INET TCP socket.
rpc.nfsd: Created AF_INET6 TCP socket.
Exporting File System...
exporting *:/mnt/nfs
/mnt/nfs          <world>
Starting Mountd in the background...These
Startup successful.
```

### Client(s)

```yaml
# PersistentVolume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-app-data
spec:
  capacity:
    storage: 10Gi  # arbitrary, NFS doesn’t enforce quota
  accessModes:
    - ReadWriteMany
  nfs:
    server: 127.0.0.1
    path: /path/to/apps/my-app
  persistentVolumeReclaimPolicy: Retain

---

# PersistentVolumeClaim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
  namespace: my-app
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  volumeName: my-app-data  # binds directly to our PV
  storageClassName: ""  # make sure no storageClass is used

---

# Pod (example -> most likely a Deployment or StatefulSet)
apiVersion: v1
kind: Pod
metadata:
  name: nfs-test-client
  namespace: my-app
spec:
  containers:
    - name: alpine
      image: alpine:3.21
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: my-app-data
```

## Reference

This image is based on and inspired by [sjiveson/nfs-server-alpine](https://github.com/sjiveson/nfs-server-alpine).
