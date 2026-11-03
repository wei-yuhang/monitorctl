require 'fileutils'
require 'tempfile'
require 'securerandom'
require 'time'

module Monitorctl
  class Store
    attr_reader :root
    def initialize(root = File.expand_path('~/Library/Application Support/monitorctl/state'))
      @root = root
    end
    def path(name)
      File.join(root,name+'.json')
    end
    def read(name)
      File.file?(path(name)) ? JSON.parse(File.read(path(name))) : nil
    end
    def write(name, data)
      FileUtils.mkdir_p(root,mode: 0700)
      temp = Tempfile.new('.monitorctl-',root)
      begin
        temp.chmod(0600); temp.write(JSON.pretty_generate(data)+"\n"); temp.flush; temp.fsync
        temp.close; File.rename(temp.path,path(name))
      ensure
        temp.close!
      end
    end
    def delete(name)
      File.unlink(path(name)) if File.exist?(path(name))
    end
    def locked(wait: false)
      FileUtils.mkdir_p(root,mode: 0700)
      File.open(File.join(root,'mutation.lock'),File::RDWR|File::CREAT,0600) do |file|
        raise Failure.new('busy','Another monitorctl command is changing displays; retry shortly.') unless file.flock(File::LOCK_EX|(wait ? 0 : File::LOCK_NB))
        yield
      ensure
        file.flock(File::LOCK_UN) if file
      end
    end
    def no_preview!
      pending = read('preview')
      raise Failure.new('preview_pending','Confirm or revert the active preview first.',pending.slice('token','expires_at')) if pending
    end
    def profile_name(name)
      raise Failure.new('invalid_profile','Profile names must use letters, numbers, dots, underscores or hyphens.') unless name && name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/)
      'profile-'+name
    end
  end
end
