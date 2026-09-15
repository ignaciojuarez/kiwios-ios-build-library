#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "zlib"

ROOT = File.expand_path("..", __dir__)
SCRIPT = File.join(ROOT, "ios-build-library.rb")

def write_config(dir, values)
  path = File.join(dir, "config.json")
  File.write(path, JSON.generate(values))
  path
end

def write_sidecar(dir, fields)
  File.write(File.join(dir, "kiwios-build.json"), JSON.generate(fields))
end

def write_store_zip(path, entries)
  File.open(path, "wb") do |io|
    central = +"".b
    offset = 0
    entries.each do |name, content|
      name = name.b
      content = content.b
      crc = Zlib.crc32(content)
      local = [0x04034b50, 20, 0, 0, 0, 0, crc, content.bytesize, content.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv")
      io.write(local)
      io.write(name)
      io.write(content)
      central << [0x02014b50, 20, 20, 0, 0, 0, 0, crc, content.bytesize, content.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV")
      central << name
      offset += local.bytesize + name.bytesize + content.bytesize
    end
    cd_offset = offset
    io.write(central)
    io.write([0x06054b50, 0, 0, entries.length, entries.length, central.bytesize, cd_offset, 0].pack("VvvvvVVv"))
  end
end

def fixture_plist(bundle_id:, version:, build:)
  <<~PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key>
      <string>#{bundle_id}</string>
      <key>CFBundleShortVersionString</key>
      <string>#{version}</string>
      <key>CFBundleVersion</key>
      <string>#{build}</string>
    </dict>
    </plist>
  PLIST
end

def write_ipa(path, bundle_id:, version:, build:, name: "Fixture")
  Dir.mktmpdir("kiwios-ipa") do |dir|
    app = File.join(dir, "Payload", "#{name}.app")
    FileUtils.mkdir_p(app)
    File.write(File.join(app, "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleIdentifier</key>
        <string>#{bundle_id}</string>
        <key>CFBundleShortVersionString</key>
        <string>#{version}</string>
        <key>CFBundleVersion</key>
        <string>#{build}</string>
      </dict>
      </plist>
    PLIST
    ok = system("/usr/bin/zip", "-rq", path, "Payload", chdir: dir, out: File::NULL, err: File::NULL)
    raise "zip failed" unless ok
  end
end

def default_sidecar(overrides = {})
  {
    "schema" => 1,
    "project" => "Kiwi Notes",
    "title" => "Share-sheet rewrite",
    "description" => "Faster sharing with offline drafts.",
    "version" => "1.4.0",
    "build" => "104",
    "feature" => "share-sheet",
    "createdAt" => "2026-09-14T18:30:00Z",
    "bundleID" => "example.kiwi-notes",
    "ipa" => "KiwiNotes.ipa"
  }.merge(overrides)
end

def run_check(home, command, config, extra_env = {})
  env = {
    "HOME" => home,
    "PATH" => "/usr/bin:/bin",
    "KIWIOS_CONFIG_FILE" => config,
    "KIWIOS_DATA_DIR" => File.join(home, "data")
  }.merge(extra_env)
  stdout, stderr, status = Open3.capture3(env, SCRIPT, command)
  raise "#{command}: unexpected stderr: #{stderr}" unless stderr.empty?

  lines = stdout.lines.map { |line| JSON.parse(line) }
  [lines, status]
end

def last_event(lines)
  lines.last
end

Dir.mktmpdir("kiwios-ios-build-library-test") do |home|
  library = File.join(home, "iOS Builds")
  FileUtils.mkdir_p(library)
  config = write_config(home, "library_root" => library, "sort" => "newest")

  valid = File.join(library, "kiwi-notes-1.4.0-104")
  FileUtils.mkdir_p(valid)
  write_sidecar(valid, default_sidecar)
  write_ipa(File.join(valid, "KiwiNotes.ipa"), bundle_id: "example.kiwi-notes", version: "1.4.0", build: "104")

  older = File.join(library, "field-log-2.0.0-31")
  FileUtils.mkdir_p(older)
  write_sidecar(older, default_sidecar.merge(
    "project" => "Field Log", "title" => "Map pins", "description" => "Offline map pins.",
    "version" => "2.0.0", "build" => "31", "feature" => "map",
    "createdAt" => "2026-08-01T12:00:00Z", "bundleID" => "example.field-log", "ipa" => "FieldLog.ipa"
  ))
  write_ipa(File.join(older, "FieldLog.ipa"), bundle_id: "example.field-log", version: "2.0.0", build: "31", name: "FieldLog")

  events, status = run_check(home, "library", config)
  event = last_event(events)
  raise "library failed: #{event.inspect}" unless status.success? && event["t"] == "ok" && event.dig("state", "value") == 2

  events, status = run_check(home, "builds", config)
  event = last_event(events)
  rows = event.dig("state", "rows")
  raise "builds failed" unless status.success? && rows.length == 2 && rows[0]["project"] == "Kiwi Notes" && rows[0]["version"] == "1.4.0 (104)"

  events, status = run_check(home, "invalid", config)
  event = last_event(events)
  raise "invalid empty failed" unless status.success? && event["t"] == "ok" && event.dig("state", "rows").empty?

  index = JSON.parse(File.read(File.join(home, "data", "index.v1.json")))
  raise "index missing relative paths" unless index["items"].all? { |item| item["relativeDir"] && item["status"] == "valid" }
  raise "index leaked absolute paths" if JSON.generate(index).include?(library)

  malformed = File.join(library, "broken-json")
  FileUtils.mkdir_p(malformed)
  File.write(File.join(malformed, "kiwios-build.json"), "{not-json")
  events, status = run_check(home, "invalid", config)
  event = last_event(events)
  raise "malformed JSON was hidden" unless status.success? && event["t"] == "warn" && event.dig("state", "rows").any? { |row| row["name"] == "broken-json" }

  unknown = File.join(library, "unknown-keys")
  FileUtils.mkdir_p(unknown)
  write_sidecar(unknown, default_sidecar.merge("url" => "https://example.invalid", "ipa" => "Unknown.ipa"))
  write_ipa(File.join(unknown, "Unknown.ipa"), bundle_id: "example.kiwi-notes", version: "1.4.0", build: "104")
  events, status = run_check(home, "invalid", config)
  raise "unknown sidecar keys were accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "unknown-keys" && row["reason"].include?("unknown fields") }

  missing = File.join(library, "missing-ipa")
  FileUtils.mkdir_p(missing)
  write_sidecar(missing, default_sidecar.merge("project" => "Missing", "title" => "Gone", "bundleID" => "example.missing", "ipa" => "Missing.ipa", "version" => "0.1.0", "build" => "1"))
  events, status = run_check(home, "invalid", config)
  raise "missing IPA was accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "missing-ipa" }

  mismatch = File.join(library, "mismatch")
  FileUtils.mkdir_p(mismatch)
  write_sidecar(mismatch, default_sidecar.merge(
    "project" => "Mismatch", "title" => "Wrong", "bundleID" => "example.mismatch",
    "version" => "9.9.9", "build" => "9", "ipa" => "Mismatch.ipa", "createdAt" => "2026-07-01T00:00:00Z"
  ))
  write_ipa(File.join(mismatch, "Mismatch.ipa"), bundle_id: "example.mismatch", version: "1.0.0", build: "1")
  events, status = run_check(home, "invalid", config)
  raise "metadata mismatch was accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "mismatch" && row["reason"].include?("does not match") }

  linked = File.join(library, "linked")
  File.symlink(valid, linked)
  events, status = run_check(home, "invalid", config)
  raise "symlink child was accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "linked" && row["reason"].include?("symbolic link") }

  linked_ipa = File.join(library, "linked-ipa")
  FileUtils.mkdir_p(linked_ipa)
  write_sidecar(linked_ipa, default_sidecar.merge(
    "project" => "Linked IPA", "title" => "Link", "bundleID" => "example.linked-ipa",
    "version" => "0.0.1", "build" => "1", "ipa" => "Linked.ipa", "createdAt" => "2026-06-01T00:00:00Z"
  ))
  File.symlink(File.join(valid, "KiwiNotes.ipa"), File.join(linked_ipa, "Linked.ipa"))
  events, status = run_check(home, "invalid", config)
  raise "symlink IPA was accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "linked-ipa" && row["reason"].include?("symbolic link") }

  traversal = File.join(library, "traversal")
  FileUtils.mkdir_p(traversal)
  write_sidecar(traversal, default_sidecar.merge(
    "project" => "Traversal", "title" => "Nope", "bundleID" => "example.traversal",
    "ipa" => "../KiwiNotes.ipa", "version" => "0.0.2", "build" => "1"
  ))
  events, status = run_check(home, "invalid", config)
  raise "parent IPA path was accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "traversal" }

  absolute = File.join(library, "absolute-ipa")
  FileUtils.mkdir_p(absolute)
  write_sidecar(absolute, default_sidecar.merge(
    "project" => "Absolute", "title" => "Nope", "bundleID" => "example.absolute",
    "ipa" => "/tmp/app.ipa", "version" => "0.0.3", "build" => "1"
  ))
  events, status = run_check(home, "invalid", config)
  raise "absolute IPA path was accepted" unless last_event(events).dig("state", "rows").any? { |row| row["name"] == "absolute-ipa" }

  duplicate = File.join(library, "zzz-duplicate")
  FileUtils.mkdir_p(duplicate)
  write_sidecar(duplicate, default_sidecar.merge("title" => "Duplicate", "createdAt" => "2026-05-01T00:00:00Z"))
  write_ipa(File.join(duplicate, "KiwiNotes.ipa"), bundle_id: "example.kiwi-notes", version: "1.4.0", build: "104")
  events, status = run_check(home, "invalid", config)
  raise "duplicate identity was accepted" unless last_event(events).dig("state", "rows").any? { |row|
    row["name"] == "zzz-duplicate" && row["reason"].include?("duplicate")
  }

  events, status = run_check(home, "builds", config)
  ids = last_event(events).dig("state", "rows").map { |row| row["id"] }
  raise "row ids are not contribution ids" unless ids.all? { |id| id.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) }

  title_config = write_config(home, "library_root" => library, "sort" => "title")
  events, status = run_check(home, "builds", title_config)
  titles = last_event(events).dig("state", "rows").map { |row| row["title"] }
  raise "title sort failed: #{titles.inspect}" unless titles.first == "Map pins"

  blank = write_config(home, "sort" => "newest")
  events, status = run_check(home, "library", blank)
  raise "missing library_root did not fail closed" unless !status.success? && last_event(events)["t"] == "error"

  home_config = write_config(home, "library_root" => home)
  events, status = run_check(home, "library", home_config)
  raise "home directory was accepted as the library root" unless !status.success? && last_event(events)["msg"].include?("disclosed")

  FileUtils.mkdir_p(File.join(home, "empty"))
  empty_config = write_config(home, "library_root" => File.join(home, "empty"))
  events, status = run_check(home, "library", empty_config)
  raise "empty library failed" unless status.success? && last_event(events).dig("state", "value") == 0

  extra = File.join(home, "many")
  FileUtils.mkdir_p(extra)
  101.times do |index|
    dir = File.join(extra, format("build-%03d", index))
    FileUtils.mkdir_p(dir)
    sidecar = default_sidecar.merge(
      "project" => "Bulk",
      "title" => format("Build %03d", index),
      "version" => "1.0.0",
      "build" => index.to_s,
      "bundleID" => "example.bulk.#{index}",
      "ipa" => "App.ipa",
      "createdAt" => format("2026-01-01T00:00:%02dZ", index % 60)
    )
    # SemVer requires three numeric identifiers; use 1.0.0 plus distinct build strings.
    sidecar["version"] = "1.0.0"
    write_sidecar(dir, sidecar)
    write_ipa(File.join(dir, "App.ipa"), bundle_id: sidecar["bundleID"], version: "1.0.0", build: index.to_s)
  end
  many_config = write_config(home, "library_root" => extra)
  events, status = run_check(home, "builds", many_config)
  event = last_event(events)
  unless status.success? && event["t"] == "warn" && event.dig("state", "rows").length == 100
    raise "101 valid builds were not truncated in the table: #{event.inspect}"
  end
  raise "truncation message missing" unless event["msg"].include?("showing 100 of 101")

  events, status = run_check(home, "rescan", config)
  raise "rescan failed" unless status.success? && %w[ok warn].include?(last_event(events)["t"])

  blank_root = write_config(home, "library_root" => "")
  events, status = run_check(home, "library", blank_root)
  raise "blank library_root did not fail closed" unless !status.success? && last_event(events)["t"] == "error"

  whitespace_root = write_config(home, "library_root" => "   ")
  events, status = run_check(home, "library", whitespace_root)
  raise "whitespace library_root did not fail closed" unless !status.success? && last_event(events)["t"] == "error"

  relative_root = write_config(home, "library_root" => "iOS Builds")
  events, status = run_check(home, "library", relative_root)
  raise "relative library_root did not fail closed" unless !status.success? && last_event(events)["t"] == "error"

  sort_lib = File.join(home, "sort-lib")
  whole = File.join(sort_lib, "whole")
  frac = File.join(sort_lib, "frac")
  FileUtils.mkdir_p(whole)
  FileUtils.mkdir_p(frac)
  write_sidecar(whole, default_sidecar.merge(
    "project" => "Sort", "title" => "Whole", "bundleID" => "example.whole",
    "ipa" => "Whole.ipa", "createdAt" => "2026-03-01T00:00:00Z", "version" => "1.0.0", "build" => "1"
  ))
  write_ipa(File.join(whole, "Whole.ipa"), bundle_id: "example.whole", version: "1.0.0", build: "1", name: "Whole")
  write_sidecar(frac, default_sidecar.merge(
    "project" => "Sort", "title" => "Frac", "bundleID" => "example.frac",
    "ipa" => "Frac.ipa", "createdAt" => "2026-03-01T00:00:00.1Z", "version" => "1.0.0", "build" => "1"
  ))
  write_ipa(File.join(frac, "Frac.ipa"), bundle_id: "example.frac", version: "1.0.0", build: "1", name: "Frac")
  sort_config = write_config(home, "library_root" => sort_lib, "sort" => "newest")
  events, status = run_check(home, "builds", sort_config)
  titles = last_event(events).dig("state", "rows").map { |row| row["title"] }
  raise "fractional createdAt sort failed: #{titles.inspect}" unless status.success? && titles == ["Frac", "Whole"]

  utf_lib = File.join(home, "utf8-lib")
  bad_zip = File.join(utf_lib, "bad-zip-name")
  FileUtils.mkdir_p(bad_zip)
  write_sidecar(bad_zip, default_sidecar.merge(
    "project" => "Bad zip", "title" => "Binary name", "bundleID" => "example.badzip",
    "ipa" => "Bad.ipa", "version" => "0.1.0", "build" => "1", "createdAt" => "2026-04-01T00:00:00Z"
  ))
  write_store_zip(File.join(bad_zip, "Bad.ipa"), [
    ["Payload/Fixture.app/Info.plist", fixture_plist(bundle_id: "example.badzip", version: "0.1.0", build: "1")],
    ["\xFF\xFEnot-utf8".b, "junk"]
  ])
  utf_config = write_config(home, "library_root" => utf_lib)
  events, status = run_check(home, "invalid", utf_config)
  event = last_event(events)
  unless status.success? && event.dig("state", "rows").any? { |row| row["name"] == "bad-zip-name" }
    raise "invalid UTF-8 zip member crashed or was accepted: #{event.inspect}"
  end

  denied_lib = File.join(home, "denied-lib")
  locked = File.join(denied_lib, "locked-child")
  FileUtils.mkdir_p(locked)
  write_sidecar(locked, default_sidecar.merge(
    "project" => "Locked", "title" => "Denied", "bundleID" => "example.locked",
    "ipa" => "Locked.ipa", "version" => "0.0.1", "build" => "1", "createdAt" => "2026-04-02T00:00:00Z"
  ))
  write_ipa(File.join(locked, "Locked.ipa"), bundle_id: "example.locked", version: "0.0.1", build: "1", name: "Locked")
  denied_config = write_config(home, "library_root" => denied_lib)
  begin
    File.chmod(0o000, locked)
    events, status = run_check(home, "invalid", denied_config)
    event = last_event(events)
    unless status.success? && event.dig("state", "rows").any? { |row| row["name"] == "locked-child" }
      raise "EACCES child crashed or was accepted: #{event.inspect}"
    end
  ensure
    File.chmod(0o755, locked) if File.exist?(locked)
  end

  huge_lib = File.join(home, "huge-lib")
  huge_dir = File.join(huge_lib, "too-big")
  FileUtils.mkdir_p(huge_dir)
  write_sidecar(huge_dir, default_sidecar.merge(
    "project" => "Huge", "title" => "Too big", "bundleID" => "example.huge",
    "ipa" => "Huge.ipa", "version" => "0.0.1", "build" => "1", "createdAt" => "2026-04-03T00:00:00Z"
  ))
  File.open(File.join(huge_dir, "Huge.ipa"), "wb") { |file| file.truncate((512 * 1024 * 1024) + 1) }
  huge_config = write_config(home, "library_root" => huge_lib)
  events, status = run_check(home, "invalid", huge_config)
  event = last_event(events)
  row = event && event.dig("state", "rows")&.find { |item| item["name"] == "too-big" }
  unless status.success? && row && row["reason"].include?("512 MiB")
    raise "oversized IPA crashed or was accepted: #{event.inspect}"
  end
  huge_index = JSON.parse(File.read(File.join(home, "data", "index.v1.json")))
  huge_item = huge_index["items"].find { |item| item["relativeDir"] == "too-big" }
  raise "oversized IPA was hashed" if huge_item && huge_item["sha256"]

  stale = File.join(library, "old-notes")
  FileUtils.mkdir_p(stale)
  write_sidecar(stale, default_sidecar.merge(
    "project" => "Old", "title" => "Stale", "bundleID" => "example.old",
    "version" => "0.0.1", "build" => "1", "ipa" => "Old.ipa", "createdAt" => "2020-01-01T00:00:00Z"
  ))
  write_ipa(File.join(stale, "Old.ipa"), bundle_id: "example.old", version: "0.0.1", build: "1", name: "Old")
  cleanup_config = write_config(home, "library_root" => library, "keep_days" => 7, "max_gb" => 0)
  events, status = run_check(home, "cleanup", cleanup_config)
  raise "cleanup failed: #{last_event(events).inspect}" unless status.success?
  raise "old build was not removed" if File.exist?(stale)
end

puts "ios-build-library plugin fixtures passed"
