#!/usr/bin/ruby
# frozen_string_literal: true

require "optparse"
require "find"
require "uri"
require_relative "ios-build-library"

def command!(*args, **options)
  stdout, _stderr, status = Open3.capture3(*args, **options)
  raise CheckError, "#{args.first} failed (exit #{status.exitstatus || 'unknown'})" unless status.success?

  stdout
rescue Errno::ENOENT
  raise CheckError, "#{args.first} is not installed"
end

def git_value(*args)
  value = capture("git", *args).strip
  value.empty? ? nil : value
rescue CheckError
  nil
end

def publish_root(path, create: false)
  raise CheckError, "set --library-root to an absolute path" unless path && path.start_with?("/", "~/")

  root = File.expand_path(path)
  raise CheckError, "library root must be under home or /Volumes" unless allowed_root?(root)

  ancestor = root
  ancestor = File.dirname(ancestor) until File.exist?(ancestor) || File.symlink?(ancestor)
  real = File.realpath(ancestor)
  real_home = File.realpath(File.expand_path(ENV.fetch("HOME")))
  raise CheckError, "library root resolves outside home or /Volumes" unless [real_home, "/Volumes"].include?(real) || real.start_with?("#{real_home}/", "/Volumes/")
  raise CheckError, "library root is a symbolic link" if File.symlink?(root)
  raise CheckError, "library root is not a directory" if File.exist?(root) && !File.directory?(root)
  raise CheckError, "library root parent is not writable" unless File.writable?(ancestor)

  FileUtils.mkdir_p(root) if create
  root
end

def portal_origin(raw)
  uri = URI.parse(raw.to_s)
  raise CheckError, "--portal must be an HTTPS origin" unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && ["", "/"].include?(uri.path.to_s) && uri.query.nil? && uri.fragment.nil?

  uri.to_s.delete_suffix("/")
rescue URI::InvalidURIError
  raise CheckError, "--portal must be an HTTPS origin"
end

def tool_check
  %w[plutil unzip zip codesign python3].each do |tool|
    raise CheckError, "#{tool} is not installed" unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
  end
end

def app_metadata(app)
  raise CheckError, "app is not a directory" unless File.directory?(app) && !File.symlink?(app)
  Find.find(app) { |path| raise CheckError, "app contains a symbolic link: #{path}" if File.symlink?(path) }
  plist = File.join(app, "Info.plist")
  raise CheckError, "app has no Info.plist" unless File.file?(plist)

  values = %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleExecutable].to_h do |key|
    [key, command!("plutil", "-extract", key, "raw", "-o", "-", plist).strip]
  end
  raise CheckError, "app has no embedded provisioning profile" unless File.file?(File.join(app, "embedded.mobileprovision"))
  executable = values.fetch("CFBundleExecutable")
  raise CheckError, "app contains a debug dylib; build with ENABLE_DEBUG_DYLIB=NO" if File.exist?(File.join(app, "#{executable}.debug.dylib")) || Dir.glob(File.join(app, "*.debug.dylib")).any?

  command!("codesign", "--verify", "--strict", app)
  { "bundleID" => values.fetch("CFBundleIdentifier"), "version" => values.fetch("CFBundleShortVersionString"), "build" => values.fetch("CFBundleVersion") }
end

def inspect_ipa_app(ipa)
  raise CheckError, "IPA is not a regular file" unless File.file?(ipa) && !File.symlink?(ipa)
  raise CheckError, "IPA is larger than 512 MiB" if File.size(ipa) > MAX_IPA_BYTES
  Dir.mktmpdir("kiwios-publish-ipa") do |temp|
    app = command!("python3", File.join(__dir__, "extract_ipa.py"), ipa, temp).strip
    yield app_metadata(app)
  end
end

def publish(options, artifact)
  root = publish_root(options.fetch(:root), create: true)
  origin = portal_origin(options.fetch(:portal))
  tool_check
  raise CheckError, "pass a signed .app or .ipa" unless artifact && File.exist?(artifact)

  artifact = File.expand_path(artifact)
  app_name = File.basename(artifact, File.extname(artifact))
  title = options[:title] || (git_value("log", "-1", "--format=%s") || app_name)[0, 64]
  branch = git_value("branch", "--show-current")
  sidecar = {
    "schema" => 1,
    "project" => options[:project] || app_name,
    "title" => title,
    "description" => options[:description] || title,
    "feature" => options[:feature] || (branch || "manual")[0, 64],
    "createdAt" => Time.now.utc.iso8601,
    "ipa" => "Build.ipa"
  }

  metadata = if artifact.end_with?(".app")
               app_metadata(artifact)
             elsif artifact.end_with?(".ipa")
               result = nil
               inspect_ipa_app(artifact) { |value| result = value }
               result
             else
               raise CheckError, "pass a signed .app or .ipa"
             end
  sidecar.merge!(metadata)
  # Validate the complete sidecar before making anything visible to KiwiOS.
  Dir.mktmpdir("kiwios-sidecar") do |temp|
    path = File.join(temp, SIDECAR_NAME)
    File.write(path, JSON.generate(sidecar))
    parse_sidecar(path)
  end

  stage = Dir.mktmpdir(".publish-", root)
  begin
    ipa = File.join(stage, "Build.ipa")
    if artifact.end_with?(".app")
      FileUtils.mkdir_p(File.join(stage, "Payload"))
      FileUtils.cp_r(artifact, File.join(stage, "Payload", File.basename(artifact)))
      command!("zip", "-qry", ipa, "Payload", chdir: stage)
      FileUtils.rm_rf(File.join(stage, "Payload"))
    else
      FileUtils.cp(artifact, ipa)
    end
    raise CheckError, "IPA is larger than 512 MiB" if File.size(ipa) > MAX_IPA_BYTES
    raise CheckError, "packaged IPA metadata changed" unless ipa_metadata(ipa) == metadata
    File.write(File.join(stage, SIDECAR_NAME), JSON.pretty_generate(sidecar))
    raise CheckError, "packaged sidecar is invalid" unless parse_sidecar(File.join(stage, SIDECAR_NAME)) == sidecar.reject { |key, _| key == "schema" }

    name = nil
    destination = nil
    loop do
      name = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(8)}"
      destination = File.join(root, name)
      break unless File.exist?(destination)
    end
    File.rename(stage, destination)
    stage = nil
    link_title = sidecar.fetch("title").gsub(/[\\\[\]]/) { |character| "\\#{character}" }
    puts "Build: [#{link_title}](#{origin}/#plugin/ios-build-library/page/builds?build=#{URI.encode_www_form_component(name)})"
  ensure
    FileUtils.remove_entry(stage) if stage && File.exist?(stage)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    require "securerandom"
    options = {}
    OptionParser.new do |parser|
      parser.banner = "usage: ruby publish.rb --library-root PATH --portal HTTPS_ORIGIN [options] [APP_OR_IPA]"
      parser.on("--library-root PATH") { |value| options[:root] = value }
      parser.on("--portal HTTPS_ORIGIN") { |value| options[:portal] = value }
      %i[project title description feature].each do |field|
        parser.on("--#{field} TEXT") { |value| options[field] = value }
      end
      parser.on("--check") { options[:check] = true }
    end.parse!
    raise CheckError, "unexpected arguments" if ARGV.length > 1
    publish_root(options[:root])
    portal_origin(options[:portal])
    tool_check
    if options[:check]
      puts "Publisher ready"
    else
      publish(options, ARGV.first)
    end
  rescue CheckError, OptionParser::ParseError, SystemCallError => error
    warn "error: #{error.message}"
    exit 2
  end
end
