class Vsphere < Mkvm

  def initialize
    @templates = {
      'small'  => [1, '1G', '15G'],
      'medium' => [2, '2G', '15G'],
      'large'  => [2, '4G', '15G'],
      'xlarge' => [2, '8G', '15G'],
    }

  end

  def defaults
    return {
      :username => ENV['USER'],
      :insecure => true,
      :upload_iso => true,
      :make_vm => true,
      :power_on => true,
      :clone => false,
    } 
  end

  def optparse opts, options
      opts.separator 'VSphere options:'
      opts.on( '-u', '--user USER', "vSphere user name (#{options[:username]})") do |x|
        options[:username] = x
      end
      opts.on( '-p', '--password PASSWORD', 'vSphere password') do |x|
        options[:password] = x
      end
      opts.on( '-H', '--host HOSTNAME', "vSphere host (#{options[:host]})") do |x|
        options[:host] = x
      end
      opts.on( '-D', '--dc DATACENTER', "vSphere data center (#{options[:dc]})") do |x|
        options[:dc] = x
      end
      opts.on( '-C', '--cluster CLUSTER', "vSphere cluster (#{options[:cluster]})") do |x|
        options[:cluster] = x
      end
      opts.on( '--[no-]insecure', "Do not validate vSphere SSL certificate (#{options[:insecure]})") do |x|
        options[:insecure] = x
      end
      opts.on( '--datastore DATASTORE', "vSphere datastore regex to use (#{options[:ds_regex]})") do |x|
        options[:ds_regex] = x
      end
      opts.on( '--isostore ISOSTORE', "vSphere ISO store to use (#{options[:iso_store]})") do |x|
        options[:isostore] = x
      end
      opts.separator 'VM options:'
      opts.on( '-t', '--template TEMPLATE', "VM template: small, medium, large, xlarge") do |x|
        options[:template] = x
      end
      opts.on( '--custom cpu,mem,sda', Array, 'CPU, Memory, and /dev/sda' ) do |x|
        options[:custom] = x
      end
      opts.on( '--sdb [10G{,/pub}]', 'Add /dev/sdb. Size and mount point optional.' ) do |x|
        options[:raw_sdb] = x || '10G'
      end
      opts.on( '--sourcevm SOURCEVM', 'Source VM from which to clone new VM.' ) do |x|
        options[:source_vm] = x 
      end
      opts.on( '--[no-]upload', "Upload the ISO to the ESX cluster (#{options[:upload_iso]})") do |x|
        options[:upload_iso] = x
      end
      opts.on( '--[no-]vm', "Build the VM (#{options[:make_vm]})") do |x|
        options[:make_vm] = x
      end
      opts.on( '--[no-]power', "Power on the VM after building it (#{options[:power_on]})") do |x|
        options[:power_on] = x
      end
      opts.on( '--[no-]clone', "Clone from the template VM (#{options[:clone]})") do |x|
        options[:clone] = x
      end
  end

  # this helper method converts unit sizes from human readable to machine usable
  def parse_size(size, target_unit = 'K')
    if size =~ /^[0-9.]+$/
      # size was an integer or a float
      # assume user knows what they are doing
      return size
    end
    # otherwise, get the input base unit
    unit = size[-1,1]
    input_size = size.chomp(unit)
    # if the input unit is the same as the target unit,
    # give them back what they gave us
    if unit == target_unit
      return input_size.to_int
    end
    # convert input size to Kibibytes
    @hash = { 'K' => 1, 'M' => 1024, 'G' => 1048576, 'T' => 1073741824 }
    if @hash.include? unit
      k = size.to_f*@hash[unit]
    else
      abort "Unit #{unit} makes no sense!"
    end
    # compute output size
    o = (k / @hash[target_unit]).to_int
    return o
  end


  def validate options
    abort '-t or --custom is required' unless options[:template] or options[:custom]
    if options[:template] and options[:custom]
      abort '-t and --custom are mutually exclusive'
    end

    if options[:template]
      options[:cpu], raw_mem, raw_sda = @templates[options[:template]]
    else
      options[:cpu], raw_mem, raw_sda = options[:custom]
    end

    # we accept human-friendly input, but need to deal with
    # Mebibytes for RAM and Kebibytes for disks
    options[:mem] = parse_size(raw_mem, 'M')
    options[:sda] = parse_size(raw_sda, 'K')

    if options[:raw_sdb]
      sdb_size, *sdb_path = options[:raw_sdb].split(/,/)
      options[:sdb] = parse_size(sdb_size, 'K')
      options[:sdb_path] = sdb_path[0]
    end

    debug( 'INFO', "CPU: #{options[:cpu]}" ) if options[:debug]
    debug( 'INFO', "Mem: #{options[:mem]} MiB" ) if options[:debug]
    debug( 'INFO', "sda: #{options[:sda]} KiB" ) if options[:debug]
    debug( 'INFO', "sdb: #{options[:sdb]} KiB" ) if options['sdb'] and options[:debug]
    debug( 'INFO', "sdb_path: #{options[:sdb_path]}" ) if options[:sdb_path] and options[:debug]

    if ! options[:network]
      abort "To properly configure the network interface you need a map 
in ~/.mkvm.yaml for :network. This structure maps subnet to dvportgroup name.
The mapping looks something like: 
    
:network:
  '192.168.20.0':
    name: 'Production'
  '192.168.30.0':
    name: 'DMZ'"
    end

    begin
      options[:network][options[:subnet]]['name']
    rescue
      abort "!! Invalid subnet !! Validate your subnet configuration. "
    end

    if ((options[:upload_iso] and options[:make_vm]) or options[:clone]) and not options[:password]
      print 'Password: '
      options[:password] = STDIN.noecho(&:gets).chomp
      puts ''
    end
  end

  def execute options

    vim = RbVmomi::VIM.connect( { :user => options[:username], :password => options[:password], :host => options[:host], :insecure => options[:insecure] } ) or abort $!
    dc = vim.serviceInstance.find_datacenter(options[:dc]) or abort "vSphere data center #{options[:dc]} not found"
    debug( 'INFO', "Connected to datacenter #{options[:dc]}" ) if options[:debug]
    cluster = dc.hostFolder.children.find { |x| x.name == options[:cluster] } or abort "vSphere cluster #{options[:cluster]} not found"
    debug( 'INFO', "Found VMware cluster #{options[:cluster]}" ) if options[:debug]
    vmFolder = dc.vmFolder
    rp = cluster.resourcePool
    # select the datastore with the most available space
    datastore = dc.datastore.find_all { |x| x.name =~ /#{options[:ds_regex]}/ }.max_by{ |i| i.info.freeSpace }.name
    debug( 'INFO', "Selected datastore #{datastore}" ) if options[:debug]

    if options[:clone]
      # Clone from Template VM
      source_vm = dc.find_vm("#{options[:source_vm]}") or abort "Failed to find source vm: #{options[:source_vm]}"
      sdb_size = options[:sdb] ? options[:sdb] : false
      source_vm.datastore.each { |ds|
        datastore = ds.name if ds.name =~ /VMstore/
      }
      clone_spec = generate_clone_spec(source_vm.config, dc, rp, options[:cpu], options[:mem], datastore, options[:network][options[:subnet]]['name'], cluster, sdb_size)
      clone_spec.customization = ip_settings(options)

      debug( 'INFO', "Cloning #{options[:source_vm]} to new VM: #{options[:hostname]}" ) if options[:debug]
      source_vm.CloneVM_Task(:folder => source_vm.parent, :name => options[:hostname], :spec => clone_spec).wait_for_completion

      # Setup anti-affinity rules if needed
      vc_affinity(dc, cluster, options[:hostname], options[:domain])
    else

      # we only execute if the options make sense
      if not options[:upload_iso] or not options[:make_vm]
        exit
      end

      # Build a VM from scratch
      time = Time.new
      annotation = "Created by " + options[:username] + " on " + time.strftime("%Y-%m-%d at %H:%M %p")
      datastore = dc.datastore.find_all { |x| x.name =~ /#{options[:ds_regex]}/ }.max_by{ |i| i.info.freeSpace }.name
      vm_cfg = {
        :name         => options[:hostname],
        :annotation   => annotation,
        :guestId      => "rhel#{options[:major]}_64Guest",
        :files        => {
          :vmPathName => "[#{datastore}]"
        },
        :numCPUs      => options[:cpu],
        :memoryMB     => options[:mem],
        :deviceChange => [ paravirtual_scsi_controller,
                           disk_config(datastore, options[:sda], 0),
                           cdrom_config(options[:iso_store], options[:hostname]),
                           network_config(options[:network][options[:subnet]]['name'], dc),
                         ],
      }
      if options[:sdb]
        vm_cfg[:deviceChange].push disk_config(datastore, options[:sdb], 1)
      end

      # stop here if --no-vm
      if not options[:make_vm]
        abort "--no-vm selected. Terminating."
      end

      # Build the VM
      if options[:debug]
        debug( 'INFO', "Building #{options[:hostname]} VM now" )
        require 'pp'
        PP.pp(vm_cfg)
      end
      _vm = vmFolder.CreateVM_Task( :config => vm_cfg, :pool => rp).wait_for_completion

      # upload the ISO as needed
      if options[:upload_iso]
        # get the ISO datastore
        isostore = dc.find_datastore(options[:iso_store])
        debug( 'INFO', "Uploading #{options[:hostname]}.iso to #{options[:iso_store]}" )  if options[:debug]
        isostore.upload "/#{options[:hostname]}.iso", "#{options[:outdir]}/#{options[:hostname]}.iso"
        # get the VMs CDROM config
        cdrom = _vm.config.hardware.device.detect { |x| x.deviceInfo.label == "CD/DVD drive 1" }
        # attach our ISO
        cdrom.deviceInfo = {
          :label   => 'CD/DVD drive 1',
          :summary => "ISO [#{options[:iso_store]}] #{options[:hostname]}.iso",
        }
        # update the config
        _vm.ReconfigVM_Task( :spec => RbVmomi::VIM::VirtualMachineConfigSpec(deviceChange: [{:operation=>:edit, :device=> cdrom }] ))
      end

      # Power on the VM and reconfigure the cdrom
      if options[:power_on]
        _vm.PowerOnVM_Task.wait_for_completion
        # sleep 10 seconds, to allow the VM to be built and booted
        sleep(10)
        # get the VMs CDROM config
        cdrom = _vm.config.hardware.device.detect { |x| x.deviceInfo.label == "CD/DVD drive 1" }
        # reconfigure CDROM to not attach at boot
        cdrom.connectable.startConnected = false
        _vm.ReconfigVM_Task( :spec => RbVmomi::VIM::VirtualMachineConfigSpec(deviceChange: [{:operation=>:edit, :device=> cdrom }] ))
        # answer VMware's question, if necessary
        if _vm.runtime.question then
          qID = _vm.runtime.question.id
          _vm.AnswerVM( questionId: qID, answerChoice: 0 )
        end
      end
  
    end

  end

  def vc_affinity(dc, cluster, host, domain)
    short = host.split('.')[0]
    if hostnum = short =~ /([2-9]$)/
      Vm_drs.new(dc, cluster, short.chop, domain, hostnum).create
    end
  end

    # Populate the customization_spec with the new host details
  def ip_settings(settings)

    ip_settings = RbVmomi::VIM::CustomizationIPSettings.new(:ip => RbVmomi::VIM::CustomizationFixedIp(:ipAddress => settings[:ip]), :gateway => [settings[:gateway]], :subnetMask => settings[:netmask])
    ip_settings.dnsDomain = settings[:domain]

    global_ip_settings = RbVmomi::VIM.CustomizationGlobalIPSettings
    global_ip_settings.dnsServerList = settings[:dns].split(',')
    global_ip_settings.dnsSuffixList = [settings[:domain]]

    hostname = RbVmomi::VIM::CustomizationFixedName.new(:name => settings[:hostname].split('.')[0])
    linux_prep = RbVmomi::VIM::CustomizationLinuxPrep.new( :domain => settings[:domain], :hostName => hostname)
    adapter_mapping = [RbVmomi::VIM::CustomizationAdapterMapping.new("adapter" => ip_settings)]

    spec = RbVmomi::VIM::CustomizationSpec.new( :identity => linux_prep,
                                                :globalIPSettings => global_ip_settings,
                                                :nicSettingMap => adapter_mapping )
    return spec

  end

   # Populate the VM clone specification
  def generate_clone_spec(source_config, dc, resource_pool, cpus, memory, datastore, network, cluster, sdb_size)

    clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(:location => RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => resource_pool), :template => false, :powerOn => false)
    clone_spec.config = RbVmomi::VIM.VirtualMachineConfigSpec(:deviceChange => Array.new, :extraConfig => nil)

    card = source_config.hardware.device.find { |d| d.deviceInfo.label == "Network adapter 1" }
    card.backing.port = get_switch_port(network, dc)
    network_spec = RbVmomi::VIM.VirtualDeviceConfigSpec(:device => card, :operation => "edit")
    clone_spec.config.deviceChange.push network_spec

    clone_spec.config.numCPUs  = Integer(cpus)
    clone_spec.config.memoryMB = Integer(memory)
    
    controllerkey = 100
    if sdb_size
      source_config.hardware.device.each { |device|
        if device.deviceInfo.summary =~ /SCSI/
          controllerkey = device.key
        end
      }
      puts controllerkey
      disk_spec = disk_config(datastore, controllerkey, sdb_size, 1)
      clone_spec.config.deviceChange.push disk_spec
    end

    return clone_spec
  end

  def get_switch_port(network, dc)
    baseEntity = dc.network
    network_object = baseEntity.find { |f| f.name == network }
    RbVmomi::VIM.DistributedVirtualSwitchPortConnection(
      :switchUuid => network_object.config.distributedVirtualSwitch.uuid,
      :portgroupKey => network_object.key
    )
  end

  def paravirtual_scsi_controller
    device = {
              :operation => :add,
              :device    => RbVmomi::VIM.ParaVirtualSCSIController(
                :key       => 100,
                :busNumber => 0,
                :sharedBus => :noSharing
              )
             }
    return device
  end

  def disk_config(datastore, controllerkey = 100, size, index)
    disk = {
            :operation     => :add,
            :fileOperation => :create,
            :device        => RbVmomi::VIM.VirtualDisk(
              :key     => index,
              :backing => RbVmomi::VIM.VirtualDiskFlatVer2BackingInfo(
                :fileName        => "[#{datastore}]",
                :diskMode        => :persistent,
                :thinProvisioned => false,
              ),
              :controllerKey => controllerkey,
              :unitNumber    => index,
              :capacityInKB  => size,
            )
          }
    puts disk
    return disk
  end

  def cdrom_config(isostore, hostname)
    cdrom = {
            :operation => :add,
            :device    => RbVmomi::VIM.VirtualCdrom(
              :key     => -2,
              :backing => RbVmomi::VIM.VirtualCdromIsoBackingInfo(
                :fileName => "[#{isostore}] #{hostname}.iso",
              ),
              :connectable => RbVmomi::VIM.VirtualDeviceConnectInfo(
                :allowGuestControl => true,
                :connected         => true,
                :startConnected    => true,
              ),
              :controllerKey => 200,
              :unitNumber    => 0,
            ),
          }
    return cdrom
  end

  def network_config(portgroup_name, dc)
    network = {
              :operation => :add,
              :device    => RbVmomi::VIM.VirtualVmxnet3(
                :key        => 0,
                :deviceInfo => {
                  :label   => 'Network Adapter 1',
                  :summary => "#{portgroup_name}",
                },
                :backing => RbVmomi::VIM.VirtualEthernetCardDistributedVirtualPortBackingInfo(
                  :port  => get_switch_port(portgroup_name, dc),
                ),
                :addressType => 'generated'
              ),
            }
    return network
  end

end
