Test & Dev
---
```
docker build -t flexvolume-npc-disk:test . && \
docker run -it --rm --network host -v $PWD/plugins-exec:/plugins-exec  -w /plugins-exec flexvolume-npc-disk:test

declare OPTIONS="$(jq -nc '{
        "kubernetes.io/pvOrVolumeName": "vol-test", 
        "kubernetes.io/fsType": "ext4" 
    }')" NODE="$(hostname)" INSTANCE='hzbdg-example-master'
kubectl label node "$NODE" npc.instance.name=$INSTANCE npc.instance.id=863ff9dc-9820-4200-a940-5f4d707984d8 npc.instance.zone=cn-east-1b

plugins-exec/npc~disk/disk init
plugins-exec/npc~disk/disk getvolumename "$OPTIONS"
ATTACH_RESULT="$(plugins-exec/npc~disk/disk attach "$OPTIONS" "$NODE")" && jq -c . <<<"$ATTACH_RESULT"
plugins-exec/npc~disk/disk isattached "$OPTIONS" "$NODE"
DEVICE="$(jq -r .device <<<"$ATTACH_RESULT")"
plugins-exec/npc~disk/disk waitforattach "$DEVICE" "$OPTIONS"

ssh example.master rm -fr /plugins-exec
scp -r plugins-exec example.master:/plugins-exec
ssh example.master /plugins-exec/npc~disk/disk mountdevice /plugins-mounts/vol-test "$DEVICE" "'$OPTIONS'"

ssh example.master /plugins-exec/npc~disk/disk unmountdevice /plugins-mounts/vol-test "$DEVICE"
plugins-exec/npc~disk/disk detach "$DEVICE" "$NODE"
```