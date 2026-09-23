#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("../publish.rb", __dir__)

def run(env, *args)
  Open3.capture3(env, "ruby", SCRIPT, *args)
end

Dir.mktmpdir("kiwios-publish-test") do |home|
  bin = File.join(home, "bin")
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, "codesign"), "#!/bin/sh\nexit 0\n")
  File.chmod(0o755, File.join(bin, "codesign"))
  env = { "HOME" => home, "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }
  root = File.join(home, "Builds & Space")
  app = File.join(home, "Test $(literal).app")
  FileUtils.mkdir_p(app)
  File.write(File.join(app, "Info.plist"), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>example.test</string>
      <key>CFBundleShortVersionString</key><string>1.2.3</string>
      <key>CFBundleVersion</key><string>42</string>
      <key>CFBundleExecutable</key><string>Test</string>
    </dict></plist>
  PLIST
  File.write(File.join(app, "embedded.mobileprovision"), "fixture")
  File.write(File.join(app, "Test"), "fixture")
  args = ["--library-root", root, "--portal", "https://kiwi-hub.example:8444", "--title", "Test build"]

  out, err, status = run(env, *args, "--check")
  raise "check failed: #{err}" unless status.success? && out.include?("Publisher ready") && !File.exist?(root)

  2.times do
    out, err, status = run(env, *args, app)
    raise "publish failed: #{err}" unless status.success?
    raise "deep link missing" unless out.match?(%r{Build: \[Test build\]\(https://kiwi-hub\.example:8444/#plugin/ios-build-library/page/builds\?build=\d{8}T\d{6}Z-[0-9a-f]{16}\)})
  end
  dirs = Dir.children(root)
  raise "repeated builds overwritten" unless dirs.length == 2 && dirs.uniq.length == 2
  dirs.each do |name|
    sidecar = JSON.parse(File.read(File.join(root, name, "kiwios-build.json")))
    raise "metadata wrong" unless sidecar.values_at("schema", "version", "build", "bundleID") == [1, "1.2.3", "42", "example.test"]
    raise "IPA missing" unless File.file?(File.join(root, name, "Build.ipa"))
  end

  out, err, status = run(env, *args, File.join(root, dirs.first, "Build.ipa"))
  raise "IPA republish failed: #{err}" unless status.success? && out.include?("Build: ")
  dirs = Dir.children(root)
  raise "IPA republish overwrote a build" unless dirs.length == 3

  broken_bin = File.join(home, "broken-bin")
  FileUtils.mkdir_p(broken_bin)
  File.write(File.join(broken_bin, "zip"), "#!/bin/sh\nexit 9\n")
  File.chmod(0o755, File.join(broken_bin, "zip"))
  _out, err, status = run(env.merge("PATH" => "#{broken_bin}:#{env.fetch('PATH')}"), *args, app)
  raise "failed packaging accepted" if status.success? || !err.include?("zip failed")
  raise "failed packaging left a stage" unless Dir.children(root).sort == dirs.sort

  plist = File.join(app, "Info.plist")
  File.write(plist, File.read(plist).sub("1.2.3", "1.0"))
  _out, err, status = run(env, *args, app)
  raise "Apple 1.0 short version rejected: #{err}" unless status.success?
  latest = (Dir.children(root) - dirs).fetch(0)
  raise "Apple short version changed" unless JSON.parse(File.read(File.join(root, latest, "kiwios-build.json")))["version"] == "1.0"
  dirs = Dir.children(root)

  unsafe = File.join(home, "unsafe.ipa")
  python = <<~PYTHON
    import stat, sys, zipfile
    with zipfile.ZipFile(sys.argv[1], 'w') as archive:
        member = zipfile.ZipInfo('Payload/Bad.app/escape')
        member.create_system = 3
        member.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(member, '/tmp')
  PYTHON
  raise "could not write unsafe IPA" unless system("python3", "-c", python, unsafe)
  _out, err, status = run(env, *args, unsafe)
  raise "unsafe IPA accepted" if status.success? || !err.include?("python3 failed")
  raise "unsafe IPA left a build" unless Dir.children(root).sort == dirs.sort

  File.write(File.join(app, "Test.debug.dylib"), "debug")
  _out, err, status = run(env, *args, app)
  raise "debug dylib accepted" if status.success? || !err.include?("debug dylib")
  raise "failed publish left a build" unless Dir.children(root).sort == dirs.sort

  File.delete(File.join(app, "Test.debug.dylib"))
  File.symlink(File.join(home, "outside-private-file"), File.join(app, "Outside"))
  _out, err, status = run(env, *args, app)
  raise "outward app symlink accepted" if status.success? || !err.include?("symbolic link")
  raise "symlink rejection left a build" unless Dir.children(root).sort == dirs.sort

  _out, err, status = run(env, "--library-root", root, "--portal", "http://unsafe.example", "--check")
  raise "HTTP portal accepted" if status.success? || !err.include?("HTTPS origin")
end

puts "publisher checks passed"
