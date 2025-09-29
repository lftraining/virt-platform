echo "=== create ==="
qm create 501 --name fd-cloud9 --memory 2048 --cores 2 --bios ovmf --serial0 socket --net0 virtio,bridge=vmbr0,firewall=1,queues=2

echo "=== import ==="
qm importdisk 501 tmp.qcow2 local --format qcow2
echo "=== cp iso ==="
rm /var/lib/vz/template/iso/cloudinit-fd-cloud9.iso
cp cloudinit-fd-cloud9.iso /var/lib/vz/template/iso/
#cp cloudinit-test.iso /var/lib/vz/template/iso/cloudinit-test.iso

echo "=== set scsi ==="
qm set 501 --scsihw virtio-scsi-pci --scsi0 local:501/vm-501-disk-0.qcow2,cache=writethrough,discard=on,iothread=1,ssd=1
    
echo "=== set cloudinit  ==="
qm set 501 --ide2 local:iso/cloudinit-fd-cloud9.iso,media=cdrom
#qm set 501 --cdrom local:iso/cloudinit-fd-cloud9.iso
    
echo "=== set efidisk ==="
qm set 501 --efidisk0 local:0,efitype=4m,format=qcow2,pre-enrolled-keys=1,size=528K
####qm set 501 --uefi0 local:0,format=qcow2,pre-enrolled-keys=1,size=528K

echo "=== set boot order  ==="
qm set 501 --boot order='ide2;scsi0'
