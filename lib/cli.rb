require 'optparse'
require 'tmpdir'
require 'shellwords'

module Monitorctl
  class CLI
    HELP = <<~TEXT.freeze
      monitorctl — monitor scaling and resolution controls for macOS

      monitorctl list [--json]
      monitorctl modes [--display main|external|NAME|ID|UUID] [--hidpi] [--all] [--json]
      monitorctl scale PERCENT [--display SELECTOR] [--refresh HZ]
      monitorctl resolution WIDTHxHEIGHT [--display SELECTOR] [--standard] [--refresh HZ]
      monitorctl refresh HZ [--display SELECTOR]
      monitorctl preview PERCENT [--seconds 20] [--display SELECTOR]
      monitorctl confirm TOKEN
      monitorctl revert [TOKEN]
      monitorctl undo
      monitorctl save NAME
      monitorctl profiles
      monitorctl restore NAME
      monitorctl status [--json]
      monitorctl hidpi plan|install|remove [--scales 200,225,250,275,300] [--display SELECTOR]
      monitorctl doctor [--json]

      Changes: --json, --dry-run, --preview SECONDS, --permanent
      Default display: main. Scale/resolution use HiDPI; --standard is explicit.
      --permanent saves mode changes across logins; default changes last this session.
      Preview returns a token immediately; timeout restores the previous mode.
      Custom HiDPI installation needs macOS administrator authentication and a reconnect.
      Commands run locally in the logged-in Mac session; hardware DDC controls are not included.
    TEXT

    def initialize(argv, executable)
      @args = argv.dup
      @executable = executable
      @opts = {display:'main',seconds:20,scales:'200,225,250,275,300'}
      @native = Native.new
      @store = Store.new
    end
    def run
      return watchdog(@args.fetch(1)) if @args[0] == '_watchdog'
      if @args[0] == '_snapshot'
        puts JSON.generate(@native.snapshot)
        return 0
      end
      @opts[:json] = @args.include?('--json')
      parser = OptionParser.new do |o|
        o.on('--display SELECTOR') { |v| @opts[:display] = v }
        o.on('--json') { @opts[:json] = true }
        o.on('--hidpi') { @opts[:hidpi] = true }
        o.on('--standard') { @opts[:standard] = true }
        o.on('--all') { @opts[:all] = true }
        o.on('--refresh HZ',Float) { |v| @opts[:refresh] = v }
        o.on('--preview SECONDS',Integer) { |v| @opts[:preview] = v }
        o.on('--seconds SECONDS',Integer) { |v| @opts[:seconds] = v }
        o.on('--permanent') { @opts[:permanent] = true }
        o.on('--dry-run') { @opts[:dry_run] = true }
        o.on('--scales LIST') { |v| @opts[:scales] = v }
        o.on('--help','-h') { @opts[:help] = true }
        o.on('--version') { @opts[:version] = true }
      end
      parser.permute!(@args)
      if @opts[:version]
        emit({'version'=>VERSION},"monitorctl #{VERSION}"); return 0
      end
      if @opts[:help] || @args.empty? || @args[0] == 'help'
        puts HELP; return 0
      end
      command = @args.shift
      arity = {'list'=>0..0,'modes'=>0..0,'scale'=>1..1,'resolution'=>1..1,'refresh'=>1..1,
        'preview'=>1..1,'confirm'=>1..1,'revert'=>0..1,'undo'=>0..0,'save'=>1..1,
        'profiles'=>0..0,'restore'=>1..1,'status'=>0..0,'hidpi'=>1..1,'doctor'=>0..0}
      raise Failure.new('invalid_argument',"Wrong number of arguments for #{command}; run monitorctl --help.") if arity[command] && !arity[command].include?(@args.size)
      raise Failure.new('invalid_argument','--hidpi and --standard conflict.') if @opts[:hidpi] && @opts[:standard]
      case command
      when 'list'
        displays = @native.displays
        emit({'displays'=>displays},displays.map { |d| display_label(d) }.join("\n"))
      when 'modes' then modes
      when 'scale','resolution','refresh','preview' then change(command)
      when 'confirm' then confirm(@args.shift)
      when 'revert' then revert(@args.shift)
      when 'undo' then restore_snapshot(@store.read('last'),'last change')
      when 'save'
        name = @args.shift; key = @store.profile_name(name)
        @store.locked { @store.write(key,@native.snapshot) } unless @opts[:dry_run]
        emit({'profile'=>name,'dry_run'=>!!@opts[:dry_run]},@opts[:dry_run] ? "Would save profile #{name}." : "Saved profile #{name}.")
      when 'profiles'
        names = Dir.glob(File.join(@store.root,'profile-*.json')).map { |p| File.basename(p,'.json').sub('profile-','') }.sort
        emit({'profiles'=>names},names.empty? ? 'No saved profiles.' : names.join("\n"))
      when 'restore'
        name = @args.shift
        restore_snapshot(@store.read(@store.profile_name(name)),"profile #{name}")
      when 'status'
        pending = @store.read('preview')
        emit({'displays'=>@native.displays,'preview'=>pending},pending ? "Preview #{pending['token']} expires at #{Time.at(pending['expires_at']).utc.iso8601}." : 'No pending preview.')
      when 'hidpi' then hidpi(@args.shift)
      when 'doctor' then doctor
      else raise Failure.new('unknown_command',"Unknown command #{command.inspect}. Run monitorctl --help.")
      end
      raise Failure.new('unexpected_arguments',"Unexpected arguments: #{@args.join(' ')}") unless @args.empty?
      0
    rescue OptionParser::ParseError,ArgumentError,KeyError => e
      error(Failure.new('invalid_argument',e.message)); 2
    rescue Failure => e
      error(e); 1
    rescue Interrupt
      error(Failure.new('interrupted','Interrupted. An armed preview watchdog still restores the previous mode.')); 130
    rescue StandardError => e
      error(Failure.new('operation_failed',e.message)); 1
    end

    def emit(data, human)
      if @opts[:json]
        puts JSON.pretty_generate({'schema_version'=>1,'ok'=>true}.merge(data))
      else
        puts human
      end
    end
    def error(exception)
      if @opts[:json]
        puts JSON.pretty_generate({'schema_version'=>1,'ok'=>false,'error'=>{'code'=>exception.code,'message'=>exception.message,'details'=>exception.details}})
      else
        warn "monitorctl: #{exception.message}"
      end
    end
    def display_label(d)
      m = d['current']
      "#{d['name']}#{d['main'] ? ' [main]' : ''} — #{m['width']}×#{m['height']}, #{m['hidpi'] ? 'HiDPI' : 'standard'}, #{m['hz']} Hz, #{d['scale_percent']}%\n  UUID #{d['uuid']} | ID #{d['id']} | native #{d['native']['width']}×#{d['native']['height']}"
    end
    def modes
      display = @native.select(@opts[:display])
      all = @native.modes(display['id'])
      selected = all.select { |m| (@opts[:all] || m.usable) && (!@opts[:hidpi] || m.hidpi?) }
      data = selected.map do |m|
        m.to_h.merge('scale_percent'=>(display['native']['width']*100.0/m.width).round(2))
      end
      rows = data.map { |m| "%6d  %5d×%-5d  %5d×%-5d  %-8s %6.2f Hz  %6.2f%%" % [m['mode_id'],m['width'],m['height'],m['pixels_w'],m['pixels_h'],m['hidpi'] ? 'HiDPI' : 'standard',m['hz'],m['scale_percent']] }
      emit({'display'=>display,'modes'=>data},([display_label(display),'MODE    DESKTOP      RENDER        TYPE       REFRESH    SCALE']+rows).join("\n"))
    ensure
      all.each(&:close) if all
    end
    def number(value,label,min,max)
      parsed = Float(value || '')
      raise ArgumentError,"#{label} must be between #{min} and #{max}." unless parsed.finite? && parsed.between?(min,max)
      parsed
    end
    def change(command)
      display = @native.select(@opts[:display])
      all = @native.modes(display['id'])
      raise Failure.new('mirrored_display','Change mirrored display settings in System Settings first.') if display['mirrored']
      current = display['current']
      hz = @opts[:refresh] && number(@opts[:refresh],'Refresh rate',1,1000)
      selected = nil
      requested = @args.shift
      if %w[scale preview].include?(command)
        percent = number(requested,'Scale',50,400)
        raise Failure.new('invalid_argument','Scale selects HiDPI automatically; use resolution --standard for standard modes.') if @opts[:standard]
        selected = Selection.scale(all,display['native'],percent,hz,current)
        @opts[:preview] = @opts[:seconds] if command == 'preview'
        unless selected
          raise Failure.new('mode_unavailable',"No available HiDPI mode matches #{percent}% on #{display['name']}.",
            {'requested_percent'=>percent,'suggested_command'=>"monitorctl hidpi install --display #{display['uuid']} --scales #{percent}"})
        end
      elsif command == 'resolution'
        match = /\A(\d{2,5})[x×](\d{2,5})\z/.match(requested.to_s)
        raise ArgumentError,'Resolution must look like 1024x640.' unless match
        w,h = match.captures.map(&:to_i)
        choices = all.select { |m| m.usable && [m.width,m.height] == [w,h] && (m.hidpi? != !!@opts[:standard]) }
        selected = Selection.choose(choices,hz,current)
      else
        hz = number(requested,'Refresh rate',1,1000)
        choices = all.select { |m| m.usable && m.width == current['width'] && m.height == current['height'] && m.hidpi? == current['hidpi'] }
        selected = Selection.choose(choices,hz,current)
      end
      raise Failure.new('mode_unavailable','That mode/refresh combination is not available; run monitorctl modes.') unless selected
      raise Failure.new('unexpected_arguments',"Unexpected arguments: #{@args.join(' ')}") unless @args.empty?
      after = {'uuid'=>display['uuid'],'current'=>selected.to_h}
      if @opts[:dry_run]
        emit({'display'=>display,'planned'=>after,'dry_run'=>true},"Would select #{selected.width}×#{selected.height}, #{selected.hidpi? ? 'HiDPI' : 'standard'}, #{selected.hz} Hz on #{display['name']}.")
      else
        apply([after],"#{display['name']}: #{selected.width}×#{selected.height}, #{selected.hidpi? ? 'HiDPI' : 'standard'}, #{selected.hz} Hz")
      end
    ensure
      all.each(&:close) if all
    end
    def independent_snapshot
      output,err,status = Open3.capture3('/usr/bin/ruby',@executable,'_snapshot')
      raise Failure.new('verification_failed',"Cannot independently read back display settings: #{err}") unless status.success?
      JSON.parse(output)
    end
    def verify(changes)
      actual = independent_snapshot
      changes.each do |wanted|
        d = actual['displays'].find { |x| x['uuid'] == wanted['uuid'] }
        raise Failure.new('verification_failed','Display disappeared while verifying.') unless d
        a,b = d['current'],wanted['current']
        ok = %w[width height pixels_w pixels_h].all? { |k| a[k] == b[k] } && (a['hz']-b['hz']).abs < 0.2
        raise Failure.new('verification_failed','macOS did not apply the requested mode.',{'wanted'=>wanted,'actual'=>d}) unless ok
      end
      actual
    end
    def apply(changes, description)
      if @opts[:dry_run]
        emit({'planned'=>changes,'dry_run'=>true},"Would apply #{description}.")
        return
      end
      @store.locked do
        @store.no_preview!
        before = @native.snapshot
        affected = before.merge('displays'=>before['displays'].select { |d| changes.any? { |c| c['uuid'] == d['uuid'] } })
        preview = @opts[:preview]
        if preview
          preview = Integer(preview)
          raise ArgumentError,'Preview duration must be 3–120 seconds.' unless preview.between?(3,120)
          token = SecureRandom.hex(8)
          @store.write('preview',{'token'=>token,'expires_at'=>Time.now.to_f+preview,'before'=>affected,
            'changes'=>changes,'permanent'=>!!@opts[:permanent]})
          start_watchdog(token)
        end
        begin
          @native.configure(changes,permanent: !!@opts[:permanent] && !preview)
          actual = verify(changes)
          @store.write('last',affected)
        rescue
          @native.configure(affected['displays'])
          @store.delete('preview') if preview
          raise
        end
        if preview
          emit({'applied'=>changes,'preview'=>@store.read('preview').slice('token','expires_at'),
            'actual'=>actual},"Preview applied: #{description}.\nConfirm: monitorctl confirm #{token}\nAuto-reverts in #{preview} seconds; revert now: monitorctl revert #{token}")
        else
          emit({'applied'=>changes,'permanent'=>!!@opts[:permanent],'actual'=>actual},"Applied #{description}. Undo: monitorctl undo")
        end
      end
    end
    def start_watchdog(token)
      reader,writer = IO.pipe
      log = File.open(File.join(@store.root,'watchdog.log'),'a',0600)
      pid = Process.spawn('/usr/bin/ruby',@executable,'_watchdog',token,in: File::NULL,out:writer,err:log,pgroup:true)
      Process.detach(pid); writer.close; log.close
      ready = IO.select([reader],nil,nil,5) && reader.gets == "READY\n"
      raise Failure.new('watchdog_failed','Preview watchdog did not start; no mode change was applied.') unless ready
    ensure
      reader.close if reader && !reader.closed?
      writer.close if writer && !writer.closed?
      log.close if log && !log.closed?
      @store.delete('preview') unless ready
    end
    def watchdog(token)
      pending = @store.read('preview')
      return 0 unless pending && pending['token'] == token
      # Enumerate and retain the original modes before acknowledging readiness.
      held = pending['before']['displays'].flat_map do |saved|
        display = @native.select(saved['uuid'],metadata:false)
        modes = @native.modes(display['id'])
        raise Failure.new('watchdog_failed','Original mode is unavailable.') unless modes.any? { |m| m.matches?(saved['current']) }
        modes
      end
      STDOUT.sync = true; puts 'READY'; STDOUT.reopen(File::NULL,'w')
      sleep([pending['expires_at']-Time.now.to_f,0].max)
      # A direct change/confirm/revert cannot race a timeout transaction.
      @store.locked(wait:true) do
        now = @store.read('preview')
        if now && now['token'] == token
          restore_preview(now)
          @store.delete('preview')
        end
      end
      0
    rescue StandardError => e
      warn "#{Time.now.utc.iso8601} Watchdog: #{e.message}"
      1
    ensure
      held.each(&:close) if held
    end
    def confirm(token)
      @store.locked do
        pending = @store.read('preview')
        raise Failure.new('preview_not_found','Supply the active preview token from monitorctl status.') unless pending && token == pending['token']
        raise Failure.new('preview_expired','Preview expired; the watchdog is restoring the previous mode.') if Time.now.to_f >= pending['expires_at']
        verify(pending['changes'])
        if @opts[:dry_run]
          emit({'would_confirm'=>token,'dry_run'=>true},'Would confirm the active preview.')
          return
        end
        @native.configure(pending['changes'],permanent:true) if pending['permanent']
        @store.delete('preview')
        emit({'confirmed'=>token,'permanent'=>pending['permanent']},'Preview confirmed.')
      end
    end
    def revert(token)
      @store.locked do
        pending = @store.read('preview')
        raise Failure.new('preview_not_found','No matching preview is active.') unless pending && (!token || pending['token'] == token)
        if @opts[:dry_run]
          emit({'planned'=>pending['before']['displays'],'dry_run'=>true},'Would restore the mode before the preview.')
          return
        end
        skipped = restore_preview(pending)
        @store.delete('preview')
        emit({'reverted'=>pending['token'],'disconnected_displays'=>skipped},'Previous mode restored on connected displays.')
      end
    end
    def restore_preview(pending)
      connected = @native.displays(metadata:false).map { |d| d['uuid'] }
      saved = pending['before']['displays']
      available,missing = saved.partition { |d| connected.include?(d['uuid']) }
      unless available.empty?
        @native.configure(available)
        verify(available)
      end
      missing.map { |d| d['uuid'] }
    end
    def restore_snapshot(saved,description)
      raise Failure.new('snapshot_not_found','No saved snapshot was found.') unless saved
      raise Failure.new('invalid_snapshot','Unsupported snapshot format.') unless saved['schema_version'] == 1 && saved['displays'].is_a?(Array)
      apply(saved['displays'],"restored #{description}")
    end
    def override_plan
      display = @native.select(@opts[:display])
      percentages = @opts[:scales].split(',').map { |p| number(p,'Scale',100,400) }.uniq
      raise ArgumentError,'Provide 1–32 scales.' unless percentages.size.between?(1,32)
      sizes = percentages.map { |p| Selection.dimensions(display['native'],p) }.uniq
      {'display_uuid'=>display['uuid'],'display_name'=>display['name'],'vendor'=>display['vendor'],
       'product'=>display['product'],'native'=>display['native'],'percentages'=>percentages,'sizes'=>sizes}
    end
    def hidpi(action)
      raise ArgumentError,'Use hidpi plan, install or remove.' unless %w[plan install remove].include?(action)
      raise ArgumentError,'--preview does not apply to override files.' if @opts[:preview]
      plan = override_plan
      overrides = Overrides.new(plan)
      if action == 'plan' || @opts[:dry_run]
        emit({'plan'=>plan,'override'=>overrides.state,'dry_run'=>true},"HiDPI plan for #{plan['display_name']}: #{plan['sizes'].map { |w,h| "#{w}×#{h}" }.join(', ')}\n#{overrides.state['path']}")
        return
      end
      if action == 'install' && overrides.requested_present?
        emit({'operation'=>action,'already_installed'=>true,'plan'=>plan,'override'=>overrides.state},'The requested HiDPI entries are already installed. Run monitorctl modes to check availability; reconnect if needed.')
        return
      end
      raise Failure.new('unexpected_arguments',"Unexpected arguments: #{@args.join(' ')}") unless @args.empty?
      output = nil
      @store.locked do
        @store.no_preview!
        Dir.mktmpdir('monitorctl-','/private/tmp') do |tmp|
          helper = File.join(tmp,'overrides.rb')
          manifest = File.join(tmp,'plan.json')
          FileUtils.cp(File.join(File.dirname(@executable),'lib','overrides.rb'),helper)
          File.write(manifest,JSON.generate(plan))
          command = ['/usr/bin/ruby',helper,action,manifest]
          if Process.uid == 0
            output,err,status = Open3.capture3(*command)
          else
            # Use OS authentication only for this explicit protected-file operation.
            script = 'do shell script '+JSON.generate(Shellwords.join(command))+' with administrator privileges'
            output,err,status = Open3.capture3('/usr/bin/osascript','-e',script)
          end
          raise Failure.new('override_install_failed',err.strip) unless status.success?
        end
      end
      emit({'operation'=>action,'plan'=>plan,'override'=>overrides.state,'reconnect_required'=>true},output.strip+"\nReconnect this monitor, then run monitorctl modes.")
    end
    def doctor
      display = @native.select(@opts[:display])
      override = Overrides.new({'vendor'=>display['vendor'],'product'=>display['product'],'sizes'=>[[display['native']['width']/2,display['native']['height']/2]]}).state
      data = {'version'=>VERSION,'executable'=>@executable,'state_directory'=>@store.root,'display'=>display,
        'override'=>override,'preview'=>@store.read('preview'),'capabilities'=>['enumerate','hidpi_scale','resolution','refresh','preview','undo','profiles','hidpi_overrides']}
      emit(data,"monitorctl #{VERSION}\n#{display_label(display)}\nExecutable: #{@executable}\nOverride: #{override['owned'] ? 'owned and unchanged' : override['installed'] ? 'external/unowned' : 'not installed'}\nPreview: #{@store.read('preview') ? 'pending' : 'none'}")
    end
  end
end
