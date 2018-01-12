# Save as 'Vagrantfile', run 'vagrant up' to provision VM with devstack and swift with barbican patch
STORE = 'store.vdi'

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/xenial64"
  config.vm.boot_timeout = 600
  VMS = 1
  (0..VMS-1).each do |vm|
    config.vm.define "barbicanswift#{vm}" do |barbicanswift|
      barbicanswift.vm.hostname = "barbicanswift#{vm}"
      barbicanswift.vm.provider "virtualbox" do | v |
        v.memory = 8192
        v.cpus = 4
        unless File.exist?(STORE)
          v.customize ['createhd', '--filename', STORE, '--size', 2 * 1024]
          # For 'older' versions of virtualbox, change 'SCSI' to 'SCSI Controller'
          v.customize ['storageattach', :id, '--storagectl', 'SCSI', '--port', 2, '--device', 0, '--type', 'hdd', '--medium', STORE]
        end
      end
      barbicanswift.vm.provision :shell, path: "setup_devstack_swift.sh", args: "all", privileged: false, keep_color: true
    end
  end
  config.ssh.forward_x11 = true
end
