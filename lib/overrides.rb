#!/usr/bin/ruby
require 'rexml/document'
require 'base64'
require 'fileutils'
require 'open3'
require 'tempfile'
require 'digest'
require 'json'

module Monitorctl
  class Overrides
    attr_reader :vendor,:product,:sizes
    def initialize(plan)
      @vendor,@product = plan.fetch('vendor'),plan.fetch('product')
      raise ArgumentError,'Invalid vendor/product IDs' unless [vendor,product].all? { |v| v.is_a?(Integer) && v.between?(1,0xffffffff) }
      @sizes = plan.fetch('sizes')
      raise ArgumentError,'Expected at most 32 logical sizes' unless sizes.is_a?(Array) && sizes.size.between?(1,32)
      raise ArgumentError,'Invalid logical size' unless sizes.all? { |s| s.is_a?(Array) && s.size == 2 && s.all? { |n| n.is_a?(Integer) && n.between?(64,16384) } }
    end
    def default_directory
      "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-#{vendor.to_s(16)}"
    end
    def name
      "DisplayProductID-#{product.to_s(16)}"
    end
    def label
      "display #{vendor.to_s(16)}:#{product.to_s(16)}"
    end
    def state
      path = File.join(default_directory,name)
      metadata = path+'.larger-text-state.json'
      return {'path'=>path,'installed'=>File.file?(path),'owned'=>false} unless File.file?(metadata)
      saved = JSON.parse(File.read(metadata))
      {'path'=>path,'installed'=>File.file?(path),'owned'=>File.file?(path) && Digest::SHA256.file(path).hexdigest == saved.fetch('sha256')}
    rescue JSON::ParserError,KeyError
      {'path'=>path,'installed'=>File.file?(path),'owned'=>false,'error'=>'invalid ownership metadata'}
    end
    def requested_present?
      return false unless state['owned']
      xml,status = Open3.capture2('/usr/bin/plutil','-convert','xml1','-o','-',File.join(default_directory,name))
      return false unless status.success?
      pairs = REXML::Document.new(xml).elements['plist/dict'].elements.to_a.each_slice(2)
      array = pairs.find { |key,_| key.text == 'scale-resolutions' }&.last
      present = array ? array.elements.to_a.select { |e| e.name == 'data' }.map { |e| Base64.decode64(e.text.to_s) } : []
      sizes.all? { |w,h| present.include?([w*2,h*2,1].pack('N3')) }
    end
  def assert_plain_path(path)
    parent = File.expand_path(path)
    loop do
      raise "Refusing symbolic link: #{parent}" if File.symlink?(parent)
      break if parent == '/'
      parent = File.dirname(parent)
    end
    raise "Not a regular file: #{path}" if File.exist?(path) && !File.file?(path)
  end

  def merge(xml = nil)
    doc = xml ? REXML::Document.new(xml) : REXML::Document.new(
      '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>')
    dict = doc.elements['plist/dict']
    raise 'Existing override is not a plist dictionary.' unless dict
    entries = dict.elements.to_a
    values = {}
    entries.each_slice(2) do |key,value|
      raise 'Malformed plist dictionary.' unless key.name == 'key' && value
      values[key.text] = value
    end
    {'DisplayVendorID'=>vendor,'DisplayProductID'=>product}.each do |key,value|
      if values[key]
        raise "Existing override has a different #{key}." unless values[key].name == 'integer' && Integer(values[key].text) == value
      else
        dict.add_element('key').text = key
        dict.add_element('integer').text = value.to_s
      end
    end
    array = values['scale-resolutions']
    raise 'Existing scale-resolutions is not an array.' if array && array.name != 'array'
    unless array
      dict.add_element('key').text = 'scale-resolutions'
      array = dict.add_element('array')
    end
    existing = array.elements.to_a.select { |el| el.name == 'data' }.map do |el|
      Base64.decode64(el.text.to_s)
    end
    sizes.each do |w,h|
      # Three big-endian uint32s: doubled render size and HiDPI flag.
      payload = [w*2,h*2,1].pack('N3')
      array.add_element('data').text = Base64.strict_encode64(payload) unless existing.include?(payload)
    end
    output = ''
    REXML::Formatters::Default.new.write(doc,output)
    output + "\n"
  end

  def atomic_write(path,bytes)
    assert_plain_path(path)
    FileUtils.mkdir_p(File.dirname(path),mode: 0755)
    tmp = Tempfile.new('.larger-text-',File.dirname(path))
    begin
      tmp.binmode
      tmp.write(bytes)
      tmp.flush
      tmp.fsync
      tmp.chmod(0644)
      tmp.close
      File.rename(tmp.path,path)
    ensure
      tmp.close! if tmp
    end
  end

  def run(action,directory: default_directory,require_root: true)
    raise 'Run this installer with sudo.' if require_root && Process.uid != 0
    raise 'Use install or remove.' unless %w[install remove].include?(action)
    path = File.join(directory,name)
    backup = path + '.larger-text-backup'
    state = path + '.larger-text-state.json'
    [path,backup,state].each { |p| assert_plain_path(p) }
    if action == 'install'
      if File.exist?(state)
        saved = JSON.parse(File.read(state))
        raise 'The override has changed since installation. Refusing to overwrite it.' unless File.file?(path) && Digest::SHA256.file(path).hexdigest == saved.fetch('sha256')
        xml,status = Open3.capture2('/usr/bin/plutil','-convert','xml1','-o','-',path)
        raise 'Cannot parse existing override; it was left untouched.' unless status.success?
        generated = merge(xml)
        pairs = REXML::Document.new(xml).elements['plist/dict'].elements.to_a.each_slice(2)
        scale = pairs.find { |key,_| key.text == 'scale-resolutions' }&.last
        present = scale ? scale.elements.to_a.select { |el| el.name == 'data' }.map { |el| Base64.decode64(el.text.to_s) } : []
        if sizes.all? { |w,h| present.include?([w*2,h*2,1].pack('N3')) }
          puts 'Custom modes are already installed. Reconnect the monitor or restart to load them.'
          return
        end
        # Extend only our unchanged override; retain the original undo backup.
        updated = saved.merge('sha256'=>Digest::SHA256.hexdigest(generated))
        atomic_write(state,JSON.pretty_generate(updated))
        begin
          atomic_write(path,generated)
        rescue
          atomic_write(state,JSON.pretty_generate(saved))
          raise
        end
        puts "Updated HiDPI requests for #{label}."
        puts 'Reconnect the monitor or restart to load the new choices.'
        return
      end
      raise 'An orphaned backup exists. Restore or move it before installing.' if File.exist?(backup)
      original = File.file?(path) ? File.binread(path) : nil
      xml = nil
      if original
        xml,status = Open3.capture2('/usr/bin/plutil','-convert','xml1','-o','-',path)
        raise 'Cannot parse existing override; it was left untouched.' unless status.success?
      end
      generated = merge(xml)
      Tempfile.create('larger-text-validate') do |file|
        file.write(generated)
        file.flush
        raise 'Generated plist validation failed.' unless system('/usr/bin/plutil','-lint',file.path,out: File::NULL)
      end
      atomic_write(backup,original) if original
      metadata = {'previous_file'=>!original.nil?,
                  'previous_sha256'=>original && Digest::SHA256.hexdigest(original),
                  'sha256'=>Digest::SHA256.hexdigest(generated)}
      # State is written first: an interrupted install is detected rather than silently overwritten.
      atomic_write(state,JSON.pretty_generate(metadata))
      begin
        atomic_write(path,generated)
      rescue
        File.unlink(state) if File.exist?(state)
        File.unlink(backup) if original && File.exist?(backup)
        raise
      end
      puts "Installed HiDPI requests for #{label}."
      puts 'Reconnect the monitor. If modes are still missing, restart when convenient.'
      puts 'Check availability with monitorctl modes after reconnecting.'
    else
      unless File.file?(state)
        puts 'No override installed by this utility was found. Nothing changed.'
        return
      end
      saved = JSON.parse(File.read(state))
      raise 'The override was changed by another app. Refusing to remove or replace it.' unless File.file?(path) && Digest::SHA256.file(path).hexdigest == saved.fetch('sha256')
      if saved.fetch('previous_file')
        raise 'The original override backup is missing.' unless File.file?(backup)
        raise 'The original override backup is damaged.' unless Digest::SHA256.file(backup).hexdigest == saved.fetch('previous_sha256')
        atomic_write(path,File.binread(backup))
        File.unlink(backup)
      else
        File.unlink(path)
      end
      File.unlink(state)
      puts 'Original monitor override restored. Reconnect the monitor or restart to finish undoing.'
    end
  end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    action,manifest = ARGV
    raise 'Expected install/remove and a JSON plan' unless %w[install remove].include?(action) && manifest
    Monitorctl::Overrides.new(JSON.parse(File.read(manifest))).run(action)
  rescue => e
    warn e.message
    exit 1
  end
end
