require 'sshkit/dsl'
require 'timeout'

class SetupServerWorker
  include Sidekiq::Worker
  sidekiq_options retry: 0

  SYSTEM_PACKAGES = [
    'yum-plugin-security',
    'firewalld',
    'java-1.7.0-openjdk-headless',
    'python3',
    'python3-devel',
    'python3-pip',
    'git',
    'tmux',
  ]

  def perform(user_id, server_id, times = 0)
    user = User.find(user_id)
    server = Server.find(server_id)
    begin
      if !server.remote.exists?
        server.minecraft.log('Error starting server; remote_id is nil. Aborting')
        server.reset_partial
        return
      end
      if server.remote.error?
        server.minecraft.log("Error communicating with Digital Ocean while starting server; they responded with #{server.remote.error}. Aborting")
        server.reset_partial
        return
      end
      host = SSHKit::Host.new(server.remote.ip_address.to_s)
      host.port = !server.done_setup? ? 22 : server.ssh_port
      host.user = 'root'
      host.key = Gamocosm.digital_ocean_ssh_private_key_path
      host.ssh_options = {
        passphrase: Gamocosm.digital_ocean_ssh_private_key_passphrase,
        paranoid: false,
        timeout: 4
      }
      begin
        on host do
          execute :true
        end
      rescue SSHKit::Runner::ExecuteError => e
        if e.cause.is_a?(Timeout::Error)
          if times == 11
            server.minecraft.log('Error connecting to server; failed to SSH. Aborting')
            server.reset_partial
          else
            server.minecraft.log("Server started, but timed out while trying to SSH (attempt #{times}, #{e}). Trying again in 16 seconds")
            SetupServerWorker.perform_in(16.seconds, user_id, server_id, times + 1)
          end
          return
        end
        raise
      end
      if server.done_setup?
        self.base_update(user, server, host)
        self.add_ssh_keys(user, server, host)
      else
        server.update_columns(remote_setup_stage: 1)
        self.base_install(user, server, host)
        server.update_columns(remote_setup_stage: 2)
        self.add_ssh_keys(user, server, host)
        server.update_columns(remote_setup_stage: 3)
        self.install_minecraft(user, server, host)
        self.install_mcsw(user, server, host)
        server.update_columns(remote_setup_stage: 4)
        self.modify_ssh_port(user, server, host)
      end
      server.update_columns(remote_setup_stage: 5)
      StartMinecraftWorker.perform_in(4.seconds, server_id)
    rescue => e
      server = Server.find(server_id)
      server.minecraft.log("Background job setting up server failed: #{e}")
      server.reset_partial
      raise
    end
  rescue ActiveRecord::RecordNotFound => e
    logger.info "Record in #{self.class} not found #{e.message}"
  end

  def base_install(user, server, host)
    mcuser_password_escaped = shell_escape("#{user.email}+#{server.minecraft.name}")
    begin
      Timeout::timeout(512) do
        on host do
          within '/tmp/' do
            if test '! id -u mcuser'
              execute :adduser, '-m', 'mcuser'
            end
            execute :echo, mcuser_password_escaped, '|', :passwd, '--stdin', 'mcuser'
            execute :usermod, '-aG', 'wheel', 'mcuser'
            if test '[ ! -f "/swapfile" ]'
              execute :fallocate, '-l', '1G', '/swapfile'
              execute :chmod, '600', '/swapfile'
              execute :mkswap, '/swapfile'
              execute :swapon, '/swapfile'
              execute :echo, '/swapfile none swap defaults 0 0', '>>', '/etc/fstab'
            end
            execute :yum, '-y', 'install', *SYSTEM_PACKAGES
            execute :yum, '-y', 'update', '--security'
            execute 'firewall-cmd', '--add-port=5000/tcp'
            execute 'firewall-cmd', '--permanent', '--add-port=5000/tcp'
            execute 'firewall-cmd', '--add-port=25565/tcp'
            execute 'firewall-cmd', '--permanent', '--add-port=25565/tcp'
            execute 'firewall-cmd', '--add-port=25565/udp'
            execute 'firewall-cmd', '--permanent', '--add-port=25565/udp'
            execute :rm, '-rf', '/tmp/pip_build_root'
            execute 'python3-pip', 'install', 'flask'
          end
        end
      end
    rescue Timeout::Error => e
      raise 'Server setup (SSH): took too long doing base setup'
    end
  end

  def base_update(user, server, host)
    begin
      Timeout::timeout(16) do
        on host do
          within '/opt/gamocosm/' do
            execute :su, 'mcuser', '-c', '"git checkout master"'
            execute :su, 'mcuser', '-c', '"git pull origin master"'
            execute :cp, '/opt/gamocosm/mcsw.service', '/etc/systemd/system/mcsw.service'
            execute :systemctl, 'daemon-reload'
            execute :systemctl, 'restart', 'mcsw'
          end
        end
      end
    rescue Timeout::Error
      raise 'Server setup (SSH): took too long updating'
    end
  end

  def install_minecraft(user, server, host)
    begin
      fi = server.minecraft.flavour_info
      if fi.nil?
        server.minecraft.log("Flavour #{server.minecraft.flavour} not found! Installing default vanilla")
        server.minecraft.update_columns(flavour: Gamocosm.minecraft_flavours.first[0])
        fi = Gamocosm.minecraft_flavours.first[1]
      end
      fv = server.minecraft.flavour.split('/')
      minecraft_script = "/tmp/gamocosm-minecraft-flavours/#{fv[0]}.sh"
      mc_flv_git_url = Gamocosm.minecraft_flavours_git_url
      # estimated minutes * 60 secs/minute * 2 (buffer)
      Timeout::timeout(fi[:time] * 60 * 2) do
        on host do
          within '/tmp/' do
            execute :rm, '-rf', 'gamocosm-minecraft-flavours'
            execute :git, 'clone', mc_flv_git_url, 'gamocosm-minecraft-flavours'
          end
          within '/home/mcuser/' do
            execute :mkdir, '-p', 'minecraft'
            within :minecraft do
              execute :chmod, 'u+x', minecraft_script
              with minecraft_flavour_version: fv[1] do
                execute :bash, '-c', minecraft_script
              end
            end
            execute :chown, '-R', 'mcuser:mcuser', 'minecraft'
          end
        end
      end
    rescue Timeout::Error
      raise 'Server setup (SSH): took too long installing Minecraft'
    end
  end

  def install_mcsw(user, server, host)
    mcsw_git_url = Gamocosm.minecraft_server_wrapper_git_url
    mcsw_username = Gamocosm.minecraft_wrapper_username
    mcsw_password = server.minecraft.minecraft_wrapper_password
    begin
      Timeout::timeout(16) do
        on host do
          within '/opt/' do
            execute :rm, '-rf', 'gamocosm'
            execute :git, 'clone', mcsw_git_url, 'gamocosm'
            within :gamocosm do
              execute :echo, mcsw_username, '>', 'mcsw-auth.txt'
              execute :echo, mcsw_password, '>>', 'mcsw-auth.txt'
            end
            execute :chown, '-R', 'mcuser:mcuser', 'gamocosm'
          end
          within '/etc/systemd/system/' do
            execute :cp, '/opt/gamocosm/mcsw.service', 'mcsw.service'
            execute :systemctl, 'enable', 'mcsw'
            execute :systemctl, 'start', 'mcsw'
          end
        end
      end
    rescue Timeout::Error
      raise 'Server setup (SSH): took too long installing the Minecraft server wrapper'
    end
  end

  def modify_ssh_port(user, server, host)
    ssh_port = server.ssh_port
    if ssh_port == 22
      return
    end
    begin
      Timeout::timeout(8) do
        on host do
          within '/tmp/' do
            execute 'firewall-cmd', "--add-port=#{ssh_port}/tcp"
            execute 'firewall-cmd', '--permanent', "--add-port=#{ssh_port}/tcp"
            execute :sed, '-i', "'s/^#Port 22$/Port #{ssh_port}/'", '/etc/ssh/sshd_config'
            execute :systemctl, 'restart', 'sshd'
          end
        end
      end
    rescue Timeout::Error
      raise 'Server setup (SSH): took too long changing SSH port'
    end
  end

  def add_ssh_keys(user, server, host)
    if server.ssh_keys.nil?
      return
    end
    key_contents = []
    server.ssh_keys.split(',').each do |key_id|
      key = user.digital_ocean_ssh_public_key(key_id)
      if key.error?
        server.minecraft.log(key)
      else
        key_contents.push(shell_escape(key))
      end
    end
    server.update_columns(ssh_keys: nil)
    begin
      Timeout::timeout(32) do
        on host do
          within '/tmp/' do
            execute :mkdir, '-p', '/home/mcuser/.ssh/'
            key_contents.each do |key_escaped|
              execute :echo, key_escaped, '>>', '/home/mcuser/.ssh/authorized_keys'
            end
            execute :chown, '-R', 'mcuser:mcuser', '/home/mcuser/.ssh/'
            execute :chmod, '700', '/home/mcuser/.ssh/'
            execute :chmod, '600', '/home/mcuser/.ssh/authorized_keys'
          end
        end
      end
    rescue Timeout::Error
      raise 'Server setup (SSH): took too long adding SSH keys from Digital Ocean'
    end
  end

  def shell_escape(str)
    return "'#{str.gsub('\'', '\'"\'"\'')}'"
  end
end
