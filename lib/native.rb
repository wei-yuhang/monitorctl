require 'fiddle'
require 'json'
require 'open3'

module Monitorctl
  VERSION = '1.1.0'.freeze
  class Failure < StandardError
    attr_reader :code, :details
    def initialize(code, message, details = {})
      @code, @details = code, details
      super(message)
    end
  end

  class Native
    P = Fiddle::TYPE_VOIDP
    I = Fiddle::TYPE_INT
    L = Fiddle::TYPE_LONG
    NATIVE_FLAG = 0x02000000
    def initialize
      @cg = Fiddle.dlopen('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
      @cf = Fiddle.dlopen('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
      @cs = Fiddle.dlopen('/System/Library/Frameworks/ColorSync.framework/ColorSync')
      @functions = {}
    end
    def cg(name, args, result = I)
      @functions[[name,args,result]] ||= Fiddle::Function.new(@cg[name], args, result)
    end
    def cf(name, args, result = P)
      @functions[[name,args,result]] ||= Fiddle::Function.new(@cf[name], args, result)
    end
    def release(ref)
      cf('CFRelease',[P],Fiddle::TYPE_VOID).call(ref) if ref && ref.to_i != 0
    end
    def constant(lib, name)
      Fiddle::Pointer.new(lib[name])[0,Fiddle::SIZEOF_VOIDP].unpack1('J')
    end
    def string(ref)
      return nil if !ref || ref.to_i == 0
      buffer = Fiddle::Pointer.malloc(8192)
      ok = cf('CFStringGetCString',[P,P,L,I],Fiddle::TYPE_CHAR).call(ref,buffer,8192,0x08000100)
      ok == 0 ? nil : buffer.to_s
    end
    def ids
      buffer = Fiddle::Pointer.malloc(128*4)
      count = Fiddle::Pointer.malloc(4)
      check(cg('CGGetActiveDisplayList',[I,P,P]).call(128,buffer,count),'enumerate displays')
      buffer[0,count[0,4].unpack1('L')*4].unpack('L*')
    end
    def uuid(id)
      ref = Fiddle::Function.new(@cs['CGDisplayCreateUUIDFromDisplayID'],[I],P).call(id)
      raise Failure.new('identity_unavailable','macOS did not provide a stable display UUID.') if ref.to_i == 0
      text = cf('CFUUIDCreateString',[P,P]).call(0,ref)
      string(text)
    ensure
      release(text) if text
      release(ref) if ref
    end
    def current(id)
      ref = cg('CGDisplayCopyDisplayMode',[I],P).call(id)
      raise Failure.new('mode_unavailable','Cannot read the current display mode.') if ref.to_i == 0
      Mode.new(self,ref)
    end
    def modes(id)
      key = constant(@cg,'kCGDisplayShowDuplicateLowResolutionModes')
      truth = constant(@cf,'kCFBooleanTrue')
      options = cf('CFDictionaryCreate',[P,P,P,L,P,P]).call(0,[key].pack('J'),[truth].pack('J'),1,0,0)
      array = cg('CGDisplayCopyAllDisplayModes',[I,P],P).call(id,options)
      raise Failure.new('mode_unavailable','Cannot enumerate display modes.') if array.to_i == 0
      Array.new(cf('CFArrayGetCount',[P],L).call(array)) do |i|
        ref = cf('CFArrayGetValueAtIndex',[P,L]).call(array,i)
        Mode.new(self,cg('CGDisplayModeRetain',[P],P).call(ref))
      end
    ensure
      release(array) if array
      release(options) if options
    end
    def names
      return @names if @names
      output,status = Open3.capture2('/usr/sbin/system_profiler','SPDisplaysDataType','-json',err: File::NULL)
      groups = status.success? ? JSON.parse(output).fetch('SPDisplaysDataType',[]) : []
      @names = groups.flat_map { |g| g.fetch('spdisplays_ndrvs',[]) }.each_with_object({}) do |d,h|
        h[d['_spdisplays_displayID'].to_i] = d['_name']
      end
    rescue JSON::ParserError
      @names = {}
    end
    def displays(metadata: true)
      ids.map do |id|
        all = modes(id)
        now = current(id)
        native = all.select { |m| m.flags & NATIVE_FLAG != 0 }
        source = native.empty? ? 'mode_catalog_fallback' : 'native_mode_flag'
        native = all.reject(&:hidpi?) if native.empty?
        native = all if native.empty?
        best = native.max_by { |m| [m.pixels_w*m.pixels_h, !m.hidpi? ? 1 : 0] }
        vendor = cg('CGDisplayVendorNumber',[I]).call(id)
        product = cg('CGDisplayModelNumber',[I]).call(id)
        display = {'id'=>id,'uuid'=>uuid(id),'name'=>(metadata ? names[id] : nil) || "Display #{id}",
          'vendor'=>vendor,'product'=>product,'serial'=>cg('CGDisplaySerialNumber',[I]).call(id),
          'main'=>cg('CGDisplayIsMain',[I]).call(id) != 0,
          'built_in'=>cg('CGDisplayIsBuiltin',[I]).call(id) != 0,
          'mirrored'=>cg('CGDisplayIsInMirrorSet',[I]).call(id) != 0,
          'native'=>{'width'=>best.pixels_w,'height'=>best.pixels_h,'source'=>source},
          'current'=>now.to_h}
        display['scale_percent'] = (100.0*best.pixels_w/now.width).round(2)
        display
      ensure
        now.close if now
        all.each(&:close) if all
      end
    end
    def select(selector = 'main', metadata: true)
      list = displays(metadata: metadata)
      matches = case selector.to_s.downcase
                when 'main' then list.select { |d| d['main'] }
                when 'external' then list.reject { |d| d['built_in'] }
                else
                  exact = list.select { |d| d['uuid'].casecmp(selector.to_s).zero? || d['id'].to_s == selector.to_s }
                  exact.empty? ? list.select { |d| d['name'].downcase.include?(selector.to_s.downcase) } : exact
                end
      raise Failure.new('display_not_found',"No connected display matches #{selector.inspect}.") if matches.empty?
      raise Failure.new('ambiguous_display',"More than one display matches #{selector.inspect}; use its UUID.",{'matches'=>matches.map { |d| d.slice('name','uuid','id') }}) if matches.size != 1
      matches.first
    end
    def snapshot
      {'schema_version'=>1,'created_at'=>Time.now.utc.strftime('%FT%TZ'),
       'displays'=>displays(metadata: false).map { |d| d.slice('uuid','id','vendor','product','serial','current') }}
    end
    def configure(changes, permanent: false)
      current_displays = displays(metadata: false)
      held = []
      prepared = changes.map do |change|
        display = current_displays.find { |d| d['uuid'] == change.fetch('uuid') }
        raise Failure.new('display_disconnected',"Display #{change['uuid']} is disconnected.") unless display
        all = modes(display['id']); held.concat(all)
        chosen = all.find { |m| m.usable && m.matches?(change.fetch('current')) }
        raise Failure.new('mode_unavailable','The requested saved mode is no longer available.',change) unless chosen
        [display['id'],chosen]
      end
      storage = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
      check(cg('CGBeginDisplayConfiguration',[P]).call(storage),'begin display transaction')
      config = storage[0,Fiddle::SIZEOF_VOIDP].unpack1('J')
      begin
        prepared.each do |id,mode|
          check(cg('CGConfigureDisplayWithDisplayMode',[P,I,P,P]).call(config,id,mode.ref,0),'set display mode')
        end
      rescue
        cg('CGCancelDisplayConfiguration',[P]).call(config)
        raise
      end
      check(cg('CGCompleteDisplayConfiguration',[P,I]).call(config,permanent ? 2 : 1),'commit display transaction')
    ensure
      held.each(&:close) if held
    end
    def check(status, action)
      raise Failure.new('macos_error',"Cannot #{action} (CGError #{status}).") unless status == 0
    end
  end

  class Mode
    attr_reader :ref,:width,:height,:pixels_w,:pixels_h,:hz,:number,:usable,:flags
    def initialize(api, ref)
      @api,@ref = api,ref
      @width = get('Width',Fiddle::TYPE_LONG); @height = get('Height',Fiddle::TYPE_LONG)
      @pixels_w = get('PixelWidth',Fiddle::TYPE_LONG); @pixels_h = get('PixelHeight',Fiddle::TYPE_LONG)
      @hz = get('RefreshRate',Fiddle::TYPE_DOUBLE)
      @number = get('IODisplayModeID',Fiddle::TYPE_INT) & 0xffffffff
      @flags = get('IOFlags',Fiddle::TYPE_INT) & 0xffffffff
      @usable = @api.cg('CGDisplayModeIsUsableForDesktopGUI',[Native::P],Fiddle::TYPE_CHAR).call(ref) != 0
    end
    def get(name,type)
      @api.cg("CGDisplayModeGet#{name}",[Native::P],type).call(@ref)
    end
    def hidpi?
      pixels_w >= width*2 && pixels_h >= height*2
    end
    def to_h
      {'width'=>width,'height'=>height,'pixels_w'=>pixels_w,'pixels_h'=>pixels_h,'hz'=>hz,
       'hidpi'=>hidpi?,'mode_id'=>number,'usable'=>usable}
    end
    def matches?(hash)
      %w[width height pixels_w pixels_h].all? { |k| to_h[k] == hash[k] } && (hz-hash.fetch('hz')).abs < 0.2
    end
    def close
      @api.cg('CGDisplayModeRelease',[Native::P],Fiddle::TYPE_VOID).call(ref) if @ref
      @ref = nil
    end
  end

  module Selection
    def self.dimensions(native, percent)
      gcd = native.fetch('width').gcd(native.fetch('height'))
      unit_w,unit_h = native['width']/gcd,native['height']/gcd
      units = (gcd*100.0/percent).round
      [unit_w*[units,1].max,unit_h*[units,1].max]
    end
    def self.scale(modes, native, percent, hz, current)
      candidates = modes.select do |m|
        ratio = m.width.to_f/m.height
        aspect = native['width'].to_f/native['height']
        actual = native['width']*100.0/m.width
        m.usable && (percent == 100 ? !m.hidpi? : m.hidpi?) &&
          (ratio/aspect-1).abs < 0.005 && (actual-percent).abs <= [0.5,percent*0.005].max
      end
      choose(candidates,hz,current) { |m| (native['width']*100.0/m.width-percent).abs }
    end
    def self.choose(candidates,hz,current)
      candidates = candidates.select { |m| (m.hz-hz).abs < 0.2 } if hz
      candidates.min_by { |m| [block_given? ? yield(m) : 0,(m.hz-current['hz']).abs < 0.2 ? 0 : 1,-m.hz] }
    end
  end
end
