# lib/facter/cisecurity.rb
#
# Custom facts needed for cisecurity.
# Original script courtesy jorhett
#
Facter.add('cisecurity') do
  require 'time'
  require 'etc'

  confine :kernel => "Linux"

  # Figure out os-specific stuff up top
  os_name = if Facter.value(:puppetversion).to_i >= 4
              Facter.value(:os)[:name]
            else
              Facter.value(:operatingsystem)
            end

  cisecurity = {}
  cisecurity['efi'] = File.directory?('/sys/firmware/efi') ? true : false

  # accounts with last password change date in future
  cisecurity['accounts_with_last_password_change_in_future'] = []
  days_since_epoch = Date.today.to_time.to_i / (60 * 60 * 24)
  File.readlines('/etc/shadow').map do |line|
    args = line.split(':')
    if args[2].to_i > days_since_epoch
      cisecurity['accounts_with_last_password_change_in_future'].push(args[0])
    end
  end

  # accounts_with_blank_passwords
  cisecurity['accounts_with_blank_passwords'] = []
  File.readlines('/etc/shadow').map do |line|
    if line =~ %r{^(\w+)::}
      cisecurity['accounts_with_blank_passwords'].push(Regexp.last_match(1))
    end
  end

  # accounts_with_uid_zero and system_accounts_with_valid_shell
  cisecurity['system_accounts_with_valid_shell'] = []
  cisecurity['accounts_with_uid_zero'] = []
  Etc.passwd do |entry|
    cisecurity['accounts_with_uid_zero'].push(entry.name) if entry.uid.zero?
    unless entry.uid >= 1000 || %w[root sync shutdown halt].include?(entry.name) || ['/sbin/nologin', '/bin/false'].include?(entry.shell)
      cisecurity['system_accounts_with_valid_shell'].push(entry.name)
    end
  end

  # installed_packages
  cisecurity['installed_packages'] = {}
  packages = `rpm -qa --queryformat '[%{NAME}===%{VERSION}-%{RELEASE}\n]'`.split(%r{\n})
  unless packages.nil? || packages == []
    packages.each do |pkg|
      name, version = pkg.lstrip.split('===')
      if name != '' && version != ''
        cisecurity['installed_packages'][name] = version
      end
    end
  end

  # package_system_file_variances
  cisecurity['package_system_file_variances'] = {}
  variances = `rpm -Va --nomtime --nosize --nomd5 --nolinkto`.split(%r{\n})
  unless variances.nil? || variances == []
    variances.each do |line|
      if line =~ %r{^(\S+)\s+(c?)\s*(\/[\w\/\-\.]+)$}
        cisecurity['package_system_file_variances'][Regexp.last_match(3)] = Regexp.last_match(1) if Regexp.last_match(2) != 'c'
      end
    end
  end

  # redhat_gpg_key_present
  gpg_keys = `rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep 'release key'`
  gpgkey_mail = case os_name
                when 'CentOS'
                  'security@centos.org'
                else
                  'security@redhat.com'
                end
  cisecurity['redhat_gpg_key_present'] = gpg_keys.match(gpgkey_mail) ? true : false

  # root_path
  cisecurity['root_path'] = []
  ENV['PATH'].split(%r{:}).each do |path|
    cisecurity['root_path'].push(path)
  end

  # subscriptions
  cisecurity['subscriptions'] = {}
  if File.exist?('/usr/bin/subscription-manager')
    subs = `subscription-manager status | grep 'Overall Status'`
    unless subs.nil? || subs == ''
      _name, value = subs.split(%r{:})
      cisecurity['subscriptions'] = value.downcase.gsub(%r{\s+}, '').chomp
    end
  end

  # suid_sgid_files and ungrouped_files
  cisecurity['suid_sgid_files'] = []
  cisecurity['unowned_files'] = []
  cisecurity['ungrouped_files'] = []
  cisecurity['world_writable_files'] = []
  cisecurity['world_writable_dirs'] = []
  `df -l --exclude-type=tmpfs -P`.split(%r{\n}).each do |fs|
    next if fs =~ %r{^Filesystem} # header line
    root_path = fs.split[5]

    unowned_files = `find #{root_path} -xdev -nouser`.split(%r{\n})
    unless unowned_files.nil? || unowned_files == ''
      unowned_files.each do |line|
        cisecurity['unowned_files'].push(line)
      end
    end

    ungrouped_files = `find #{root_path} -xdev -nogroup`.split(%r{\n})
    unless ungrouped_files.nil? || ungrouped_files == ''
      ungrouped_files.each do |line|
        cisecurity['ungrouped_files'].push(line)
      end
    end

    suid_sgid_files = `find #{root_path} -xdev -type f \\( -perm -4000 -o -perm -2000 \\)`.split(%r{\n})
    unless suid_sgid_files.nil? || suid_sgid_files == ''
      suid_sgid_files.each do |line|
        cisecurity['suid_sgid_files'].push(line)
      end
    end

    world_writable_files = `find #{root_path} -xdev -type f -perm -0002`.split(%r{\n})
    unless world_writable_files.nil? || world_writable_files == ''
      world_writable_files.each do |line|
        cisecurity['world_writable_files'].push(line)
      end
    end

    world_writable_dirs = `find #{root_path} -xdev -type d \\( -perm -0002 -a ! -perm -1000 \\)`.split(%r{\n})
    next unless world_writable_dirs.nil? || world_writable_dirs == ''
    world_writable_dirs.each do |line|
      cisecurity['world_writable_dirs'].push(line)
    end
  end

  # unconfined_daemons
  cisecurity['unconfined_daemons'] = []
  `ps -eZ`.split(%r{\n}).each do |line|
    next unless line =~ %r{initlc}
    cisecurity['unconfined_daemons'].push(line.split[-1])
  end

  # yum_enabled_repos
  cisecurity['yum_enabled_repos'] = []
  yum_repos = `yum repolist enabled`.split(%r{\n})
  unless yum_repos.nil? || yum_repos == []
    yum_repos.each do |line|
      next if line =~ %r{^Loaded } || line =~ %r{^Loading } # headers
      next if line =~ %r{^repo id *repo name } # column header
      next if line =~ %r{^ \* } # mirror list
      next if line =~ %r{^repolist: } # footer
      if line.split[0] != '' && line.split[0] != ':'
        cisecurity['yum_enabled_repos'].push(line.split[0])
      end
    end
  end

  # yum_repos_gpg_check_consistent
  disabled_gpg = `grep gpgcheck /etc/yum.repos.d/*.repo | grep 0 > /dev/null`
  cisecurity['yum_repos_gpgcheck_consistent'] = disabled_gpg ? true : false

  setcode do
    cisecurity
  end
end
