require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/native'
require_relative '../lib/store'
require_relative '../lib/overrides'

class MonitorctlTest < Minitest::Test
  FakeMode = Struct.new(:width,:height,:pixels_w,:pixels_h,:hz,:usable) do
    def hidpi?; pixels_w >= width*2 && pixels_h >= height*2; end
  end
  def test_monitor_geometry_is_not_model_specific
    [[2560,1600],[2560,1440],[3840,2160],[3440,1440],[3024,1964]].each do |w,h|
      [125,200,225,250,275,300].each do |p|
        x,y = Monitorctl::Selection.dimensions({'width'=>w,'height'=>h},p)
        assert_equal w*y,h*x
        assert_operator x,:>,0
      end
    end
    assert_equal [1024,640],Monitorctl::Selection.dimensions({'width'=>2560,'height'=>1600},250)
  end
  def test_hidpi_is_never_substituted_with_standard_resolution
    low = FakeMode.new(1024,640,1024,640,60,true)
    high = FakeMode.new(1024,640,2048,1280,60,true)
    native = {'width'=>2560,'height'=>1600}
    assert_nil Monitorctl::Selection.scale([low],native,250,nil,{'hz'=>60})
    assert_same high,Monitorctl::Selection.scale([low,high],native,250,nil,{'hz'=>60})
  end
  def test_aspect_ratio_and_refresh_are_respected
    wrong_aspect = FakeMode.new(1280,720,2560,1440,60,true)
    right = FakeMode.new(1280,800,2560,1600,60,true)
    fast = FakeMode.new(1280,800,2560,1600,100,true)
    native = {'width'=>2560,'height'=>1600}
    assert_nil Monitorctl::Selection.scale([wrong_aspect],native,200,nil,{'hz'=>60})
    assert_same right,Monitorctl::Selection.scale([fast,right],native,200,nil,{'hz'=>60})
    assert_same fast,Monitorctl::Selection.scale([fast,right],native,200,100,{'hz'=>60})
    assert_nil Monitorctl::Selection.scale([fast,right],native,200,75,{'hz'=>60})
  end
  def test_stable_identity_and_ambiguous_display_selection
    native = Monitorctl::Native.new
    fixtures = [{'name'=>'Twin','id'=>3,'uuid'=>'AAAA','main'=>true,'built_in'=>false},
                {'name'=>'Twin','id'=>4,'uuid'=>'BBBB','main'=>false,'built_in'=>false}]
    native.define_singleton_method(:displays) { |**_| fixtures }
    assert_equal 'AAAA',native.select('main')['uuid']
    assert_equal 'BBBB',native.select('bbbb')['uuid']
    assert_equal 4,native.select('4')['id']
    e = assert_raises(Monitorctl::Failure) { native.select('Twin') }
    assert_equal 'ambiguous_display',e.code
    assert_raises(Monitorctl::Failure) { native.select('missing') }
  end
  def test_store_is_atomic_and_mutations_serialize
    Dir.mktmpdir('monitorctl-test-','/private/tmp') do |dir|
      store = Monitorctl::Store.new(dir)
      store.write('last',{'schema_version'=>1,'displays'=>[]})
      assert_equal 1,store.read('last')['schema_version']
      assert_equal 0600,File.stat(store.path('last')).mode & 0777
      store.locked do
        other = Monitorctl::Store.new(dir)
        assert_raises(Monitorctl::Failure) { other.locked { flunk 'Concurrent mutation entered lock' } }
      end
      store.write('preview',{'token'=>'a','expires_at'=>1})
      assert_raises(Monitorctl::Failure) { store.no_preview! }
      store.delete('preview'); store.no_preview!
      assert_raises(Monitorctl::Failure) { store.profile_name('../escape') }
    end
  end
  def test_override_upgrade_preserves_original_bytes_and_other_modes
    Dir.mktmpdir('monitorctl-test-','/private/tmp') do |dir|
      first = Monitorctl::Overrides.new({'vendor'=>7789,'product'=>16019,'sizes'=>[[1280,800]]})
      more = Monitorctl::Overrides.new({'vendor'=>7789,'product'=>16019,'sizes'=>[[1024,640],[856,535]]})
      path = File.join(dir,first.name)
      File.write(path,'<?xml version="1.0"?><plist version="1.0"><dict><key>KeepMe</key><string>yes</string></dict></plist>')
      assert system('/usr/bin/plutil','-convert','binary1',path)
      original = File.binread(path)
      first.run('install',directory:dir,require_root:false)
      more.run('install',directory:dir,require_root:false)
      installed = File.binread(path)
      assert_includes installed,'KeepMe'
      modes = REXML::Document.new(installed).get_elements('plist/dict/array/data').map { |e| Base64.decode64(e.text).unpack('N3') }
      assert_includes modes,[2560,1600,1]
      assert_includes modes,[2048,1280,1]
      assert_includes modes,[1712,1070,1]
      more.run('install',directory:dir,require_root:false)
      assert_equal installed,File.binread(path)
      more.run('remove',directory:dir,require_root:false)
      assert_equal original,File.binread(path)
    end
  end
  def test_foreign_edits_and_symlinks_are_not_overwritten
    Dir.mktmpdir('monitorctl-test-','/private/tmp') do |dir|
      helper = Monitorctl::Overrides.new({'vendor'=>7789,'product'=>16019,'sizes'=>[[1280,800]]})
      helper.run('install',directory:dir,require_root:false)
      path = File.join(dir,helper.name)
      File.open(path,'a') { |f| f.puts 'changed' }
      assert_raises(RuntimeError) { helper.run('install',directory:dir,require_root:false) }
      assert_raises(RuntimeError) { helper.run('remove',directory:dir,require_root:false) }
      File.unlink(path); File.symlink('/private/tmp',path)
      assert_raises(RuntimeError) { helper.run('install',directory:dir,require_root:false) }
    end
  end
end
