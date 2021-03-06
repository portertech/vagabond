require 'vagabond/vagabond'
require 'mixlib/cli'
require 'digest/md5'

module Vagabond
  
  class Server < Vagabond

    class << self
      def basename
        'vagabond server'
      end
    end

    self.class_exec(false, &Vagabond::COMMANDS)
    
    def initialize(*args)
      super
      @name = 'server'
      @base_template = 'ubuntu_1204' # TODO: Make this dynamic
      setup('status')
    end

    desc 'server stop', 'Stops the local Chef server'
    def stop
      if(lxc.exists?)
        if(lxc.running?)
          ui.info 'Shutting down Chef server container...'
          lxc.shutdown
          ui.info 'Chef server container shut down!'
        else
          ui.error 'Chef server container not currently running'
        end
      else
        ui.error 'Chef server container has not been created'
      end
    end

    desc 'auto_upload', 'Uploads all assets'
    def auto_upload
      ui.info 'Auto uploading all assets to local Chef server...'
      upload_roles
      upload_databags
      upload_environments
      upload_cookbooks
      ui.info ui.color('  -> All assets uploaded!', :green)
    end

    desc 'upload_roles', 'Upload all roles'
    def upload_roles
      am_uploading('roles') do
        if(File.directory?(File.join(base_dir, 'roles')))
          com = "knife role from file #{File.join(base_dir, 'roles/*')} #{options[:knife_opts]}"
          debug(com)
          cmd = Mixlib::ShellOut.new(com, :live_stream => options[:debug])
          cmd.run_command
          cmd.error!
        end
      end
    end

    desc 'upload_databags', 'Upload all data bags'
    def upload_databags
      am_uploading('data bags') do
        if(File.directory?(File.join(base_dir, 'data_bags')))
          Dir.glob(File.join(base_dir, "data_bags/*")).each do |b|
            next if %w(. ..).include?(b)
            coms = [
              "knife data bag create #{File.basename(b)} #{options[:knife_opts]}",
              "knife data bag from file #{File.basename(b)} #{options[:knife_opts]} --all"
            ].each do |com|
              debug(com)
              cmd = Mixlib::ShellOut.new(com, :live_stream => options[:debug])
              cmd.run_command
              cmd.error!
            end
          end
        end
      end
    end

    desc 'upload_environments', 'Upload all environments'
    def upload_environments
      am_uploading('environments') do
        if(File.directory?(File.join(base_dir, 'environments')))
          com = "knife environment from file #{File.join(base_dir, 'environments/*')} #{options[:knife_opts]}"
          debug(com)
          cmd = Mixlib::ShellOut.new(com, :live_stream => options[:debug])
          cmd.run_command
          cmd.error!
        end
      end
    end

    desc 'upload_cookbooks', 'Upload all cookbooks'
    def upload_cookbooks
      am_uploading('cookbooks') do
        if(vagabondfile[:local_chef_server][:librarian])
          librarian_upload
        elsif(vagabondfile[:local_chef_server][:berkshelf])
          berks_upload
        else
          raw_upload
        end
      end
    end

    private

    def validate!
    end

    def setup(action, name=nil, *args)
      super(action, 'server', *args)
    end
    
    def am_uploading(thing)
      ui.info "#{ui.color('Local chef server:', :bold)} Uploading #{ui.color(thing, :green)}"
      yield
      ui.info ui.color("  -> UPLOADED #{thing.upcase}", :green)
    end
    
    def do_create
      @lxc = Lxc.new(generated_name)
      unless(@lxc.exists?)
        com = "#{options[:sudo]}lxc-clone -n #{generated_name} -o #{@base_template}"
        debug(com)
        cmd = Mixlib::ShellOut.new(com, :live_stream => options[:debug])
        cmd.run_command
        cmd.error!
      else
        ui.warn 'Found server instance not if configuration. Adding and moving on.'
      end
      @internal_config[:mappings][name] = generated_name
      @internal_config.save
      ui.info ui.color('  -> Chef Server container created!', :cyan)
      lxc.start
      ui.info ui.color('  -> Chef Server CREATED!', :green)
      do_provision
      auto_upload if vagabondfile[:local_chef_server][:auto_upload]
    end

    def do_provision
      if(vagabondfile[:local_chef_server][:zero])
        ui.info ui.color('  -> Bootstrapping chef-zero...', :cyan)
        tem_file = File.expand_path(File.join(File.dirname(__FILE__), 'bootstraps/server-zero.erb'))
        options[:knife_opts] = " --server-url http://#{lxc.container_ip(20, true)}"
      else
        ui.info ui.color('  -> Bootstrapping erchef...', :cyan)
        tem_file = File.expand_path(File.join(File.dirname(__FILE__), 'bootstraps/server.erb'))
        options[:knife_opts] = " --server-url https://#{lxc.container_ip(20, true)}"
      end
      com = "#{options[:sudo]}knife bootstrap #{lxc.container_ip(10, true)} --template-file #{tem_file} -i /opt/hw-lxc-config/id_rsa"
      cmd = Mixlib::ShellOut.new(com, :live_stream => options[:debug], :timeout => 1200)
      debug(com)
      cmd.run_command
      cmd.error!
    end
    
    def berks_upload
      ui.info 'Cookbooks being uploaded via berks'
      berk_uploader = Uploader::Berkshelf.new(
        vagabondfile.directory, options.merge(
          :ui => ui,
          :berksfile => File.join(vagabondfile.directory, vagabondfile[:local_chef_server][:berkshelf][:path] || 'Berksfile'),
          :chef_server_url => options[:knife_opts].to_s.split(' ').last,
          :berks_opts => vagabondfile[:local_chef_server][:berkshelf][:options]
        )
      )
      berk_uploader.upload
    end

    def librarian_upload
      ui.info 'Cookbooks being uploaded with librarian'
      librarian_uploader = Uploader::Librarian.new(
        vagabondfile.generate_store_path, options.merge(
          :ui => ui,
          :cheffile => File.join(vagabondfile.directory, 'Cheffile')
        )
      )
      librarian_uploader.upload
    end
    
    def raw_upload
      ui.info 'Cookbooks being uploaded via knife'
      knife_uploader = Uploader::Knife.new(vagabondfile.directory, options.merge(:ui => ui))
      knife_uploader.upload
    end

  end
end
