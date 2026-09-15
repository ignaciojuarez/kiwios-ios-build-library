#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "tmpdir"

class CheckError < StandardError; end

MAX_ROWS = 100
MAX_STATE_BYTES = 44 * 1024
MAX_INDEX_ITEMS = 1_000
MAX_IPA_BYTES = 512 * 1024 * 1024
MAX_SIDECAR_BYTES = 64 * 1024
MAX_ZIP_LISTING_BYTES = 1024 * 1024
MAX_PLIST_BYTES = 256 * 1024
SIDECAR_NAME = "kiwios-build.json"
INDEX_NAME = "index.v1.json"
SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
CREATED_AT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/
BUNDLE_ID = /\A[A-Za-z0-9][A-Za-z0-9.-]{0,126}\z/
IPA_NAME = /\A[A-Za-z0-9._+-]+\.ipa\z/
PLIST_MEMBER = %r{\APayload/[^/]+\.app/Info.plist\z}n
SIDECAR_KEYS = %w[schema project title description version build feature createdAt bundleID ipa].freeze

def capture(*argv, max_bytes: nil)
  return capture_bounded(*argv, max_bytes: max_bytes) if max_bytes

  stdout, _stderr, status = Open3.capture3(*argv)
  raise CheckError, "#{argv.first} failed (exit #{status.exitstatus || "unknown"})" unless status.success?

  stdout
rescue Errno::ENOENT
  raise CheckError, "#{argv.first} is not installed or is not on PATH"
end

def capture_bounded(*argv, max_bytes:)
  data = +"".b
  too_large = false
  status = nil
  Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    stdout.binmode
    stderr.binmode
    err_reader = Thread.new do
      while stderr.read(4096)
      end
    end
    begin
      while (chunk = stdout.read(16 * 1024))
        data << chunk
        next if data.bytesize <= max_bytes

        too_large = true
        Process.kill("TERM", wait_thr.pid) rescue nil
        8.times { break unless stdout.read(16 * 1024) }
        break
      end
    ensure
      err_reader.join
    end
    status = wait_thr.value
  end
  raise CheckError, "#{argv.first} output is larger than #{max_bytes} bytes" if too_large
  raise CheckError, "#{argv.first} failed (exit #{status.exitstatus || "unknown"})" unless status.success?

  data
rescue Errno::ENOENT
  raise CheckError, "#{argv.first} is not installed or is not on PATH"
end

def event(type, message, state = nil)
  value = { "t" => type, "msg" => message }
  value["state"] = state if state
  puts JSON.generate(value)
end

def read_config
  path = ENV["KIWIOS_CONFIG_FILE"]
  raise CheckError, "KIWIOS_CONFIG_FILE is unavailable" unless path && !path.empty?
  raise CheckError, "Set the build library folder in Configure" unless File.file?(path)

  data = JSON.parse(File.read(path))
  raise CheckError, "plugin configuration is not an object" unless data.is_a?(Hash)

  data
rescue JSON::ParserError
  raise CheckError, "plugin configuration is not valid JSON"
end

def lstat!(path, label)
  File.lstat(path)
rescue Errno::ENOENT
  raise CheckError, "#{label} does not exist: #{path}"
rescue Errno::EACCES
  raise CheckError, "#{label} is not readable: #{path}"
end

def lstat_item(path, missing:, denied:)
  File.lstat(path)
rescue Errno::ENOENT
  raise CheckError, missing
rescue Errno::EACCES
  raise CheckError, denied
end

def allowed_root?(path)
  home = File.expand_path(ENV.fetch("HOME"))
  prefixes = [home, "/Volumes"]
  prefixes.any? { |root| path.start_with?("#{root}/") } && path != home && path != "/Volumes" && path != "/"
end

def configured_root
  raw = read_config["library_root"]
  raise CheckError, "Set the build library folder in Configure" unless raw.is_a?(String) && !raw.strip.empty?

  stripped = raw.strip
  raise CheckError, "the build library folder contains invalid characters" if stripped.match?(/[[:cntrl:]\0]/)
  raise CheckError, "the build library folder must be an absolute path under the home directory or /Volumes" unless stripped.start_with?("/", "~/")

  path = File.expand_path(stripped)
  raise CheckError, "the build library folder is outside the disclosed home directory and /Volumes roots" unless allowed_root?(path)

  status = lstat!(path, "build library folder")
  raise CheckError, "the build library folder is a symbolic link" if status.symlink?
  raise CheckError, "the build library folder is not a directory" unless status.directory?

  path
end

def configured_sort
  value = read_config["sort"]
  return "newest" if value.nil? || value == ""
  raise CheckError, "sort must be newest, title, or version" unless %w[newest title version].include?(value)

  value
end

def configured_integer(name, allowed)
  value = read_config[name]
  return allowed.first if value.nil?
  number = if value.is_a?(Integer)
             value
           elsif value.is_a?(Float) && value == value.round
             value.to_i
           end
  raise CheckError, "#{name} is invalid" unless allowed.include?(number)

  number
end

def configured_keep_days
  configured_integer("keep_days", [0, 7, 14, 30, 90])
end

def configured_max_bytes
  gigabytes = configured_integer("max_gb", [0, 5, 10, 20, 50])
  gigabytes.zero? ? 0 : gigabytes * 1024 * 1024 * 1024
end

def short_text(value, limit, field)
  raise CheckError, "#{field} must be a string" unless value.is_a?(String)
  raise CheckError, "#{field} is empty" if value.strip.empty?
  raise CheckError, "#{field} contains control characters" if value.match?(/[[:cntrl:]]/)
  raise CheckError, "#{field} is longer than #{limit} characters" if value.length > limit

  value
end

def parse_sidecar(path)
  raw = begin
    File.binread(path, MAX_SIDECAR_BYTES + 1)
  rescue Errno::ENOENT
    raise CheckError, "missing kiwios-build.json"
  rescue Errno::EACCES
    raise CheckError, "sidecar is not readable"
  end
  raise CheckError, "sidecar is larger than 64 KiB" if raw.nil? || raw.bytesize > MAX_SIDECAR_BYTES

  data = JSON.parse(raw)
  raise CheckError, "sidecar is not an object" unless data.is_a?(Hash)
  raise CheckError, "sidecar has unknown fields" unless (data.keys - SIDECAR_KEYS).empty?
  raise CheckError, "sidecar is missing required fields" unless SIDECAR_KEYS.all? { |key| data.key?(key) }
  raise CheckError, "sidecar schema must be 1" unless data["schema"] == 1
  raise CheckError, "version is not SemVer" unless data["version"].is_a?(String) && data["version"].match?(SEMVER)
  raise CheckError, "createdAt must be RFC 3339 UTC" unless data["createdAt"].is_a?(String) && data["createdAt"].match?(CREATED_AT)
  raise CheckError, "bundleID is invalid" unless data["bundleID"].is_a?(String) && data["bundleID"].match?(BUNDLE_ID)
  raise CheckError, "ipa filename is invalid" unless data["ipa"].is_a?(String) && data["ipa"].match?(IPA_NAME)

  {
    "project" => short_text(data["project"], 64, "project"),
    "title" => short_text(data["title"], 64, "title"),
    "description" => short_text(data["description"], 200, "description"),
    "version" => data["version"],
    "build" => short_text(data["build"], 32, "build"),
    "feature" => short_text(data["feature"], 64, "feature"),
    "createdAt" => data["createdAt"],
    "bundleID" => data["bundleID"],
    "ipa" => data["ipa"]
  }
rescue JSON::ParserError
  raise CheckError, "sidecar is not valid JSON"
end

def zip_names(ipa)
  listing = capture("unzip", "-Z1", ipa, max_bytes: MAX_ZIP_LISTING_BYTES).b
  listing.split("\n".b).map { |line| line.delete_suffix("\r".b) }
end

def unsafe_zip_name?(name)
  return true if name.empty? || name.start_with?("/".b) || name.split("/".b).include?("..".b)

  !name.dup.force_encoding(Encoding::UTF_8).valid_encoding?
end

def ipa_metadata(ipa)
  names = zip_names(ipa)
  raise CheckError, "IPA contains an unsafe path" if names.any? { |name| unsafe_zip_name?(name) }

  plists = names.select { |name| name.match?(PLIST_MEMBER) }
  raise CheckError, "IPA must contain exactly one top-level app Info.plist" unless plists.length == 1

  xml = capture("unzip", "-p", ipa, plists.first, max_bytes: MAX_PLIST_BYTES)
  Dir.mktmpdir("kiwios-ipa-plist") do |dir|
    plist = File.join(dir, "Info.plist")
    File.binwrite(plist, xml)
    identifier = capture("plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist).strip
    version = capture("plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist).strip
    build = capture("plutil", "-extract", "CFBundleVersion", "raw", "-o", "-", plist).strip
    raise CheckError, "IPA Info.plist is missing bundle metadata" if identifier.empty? || version.empty? || build.empty?

    { "bundleID" => identifier, "version" => version, "build" => build }
  end
end

def sha256(path)
  capture("/usr/bin/shasum", "-a", "256", path).split.first
end

def row_id(*values)
  "b-#{Digest::SHA256.hexdigest(values.join("\n"))[0, 16]}"
end

def inspect_child(root, name)
  path = File.join(root, name)
  sidecar = nil
  status = lstat_item(path, missing: "build directory does not exist", denied: "build directory is not readable")
  if status.symlink?
    return invalid_item(name, "build directory is a symbolic link")
  end
  unless status.directory?
    return invalid_item(name, "library child is not a directory")
  end

  sidecar_path = File.join(path, SIDECAR_NAME)
  sidecar_status = lstat_item(sidecar_path, missing: "missing kiwios-build.json", denied: "sidecar is not readable")
  return invalid_item(name, "sidecar is a symbolic link") if sidecar_status.symlink?
  return invalid_item(name, "sidecar is not a regular file") unless sidecar_status.file?
  raise CheckError, "sidecar is larger than 64 KiB" if sidecar_status.size > MAX_SIDECAR_BYTES

  sidecar = parse_sidecar(sidecar_path)
  ipa_path = File.join(path, sidecar["ipa"])
  ipa_status = lstat_item(ipa_path, missing: "missing IPA #{sidecar["ipa"]}", denied: "IPA is not readable")
  return invalid_item(name, "IPA is a symbolic link", sidecar) if ipa_status.symlink?
  return invalid_item(name, "IPA is not a regular file", sidecar) unless ipa_status.file?
  raise CheckError, "IPA is larger than 512 MiB" if ipa_status.size > MAX_IPA_BYTES

  digest = sha256(ipa_path)
  metadata = ipa_metadata(ipa_path)
  unless metadata["bundleID"] == sidecar["bundleID"] && metadata["version"] == sidecar["version"] && metadata["build"] == sidecar["build"]
    return invalid_item(name, "sidecar bundle ID, version, or build does not match the IPA", sidecar)
  end

  {
    "status" => "valid",
    "relativeDir" => name,
    "ipa" => sidecar["ipa"],
    "sha256" => digest,
    "size" => ipa_status.size,
    "project" => sidecar["project"],
    "title" => sidecar["title"],
    "description" => sidecar["description"],
    "version" => sidecar["version"],
    "build" => sidecar["build"],
    "feature" => sidecar["feature"],
    "createdAt" => sidecar["createdAt"],
    "bundleID" => sidecar["bundleID"],
    "id" => row_id(name, sidecar["bundleID"], sidecar["version"], sidecar["build"], digest)
  }
rescue CheckError => error
  invalid_item(name, error.message, sidecar)
rescue ArgumentError, SystemCallError, JSON::ParserError, EncodingError
  invalid_item(name, "build cannot be read", sidecar)
end

def invalid_item(name, reason, sidecar = nil)
  {
    "status" => "invalid",
    "relativeDir" => name,
    "reason" => reason,
    "project" => sidecar && sidecar["project"],
    "title" => sidecar && sidecar["title"],
    "version" => sidecar && sidecar["version"],
    "build" => sidecar && sidecar["build"],
    "bundleID" => sidecar && sidecar["bundleID"],
    "ipa" => sidecar && sidecar["ipa"],
    "id" => row_id("invalid", name, reason)
  }
end

def skip_name?(name)
  name.start_with?(".")
end

def sort_items(items, order)
  items.sort do |left, right|
    case order
    when "title"
      [left["title"].to_s.downcase, left["relativeDir"]] <=> [right["title"].to_s.downcase, right["relativeDir"]]
    when "version"
      comparison = semver_parts(right["version"]) <=> semver_parts(left["version"])
      comparison.zero? ? right["build"].to_s <=> left["build"].to_s : comparison
    else
      comparison = created_at_time(right["createdAt"]) <=> created_at_time(left["createdAt"])
      comparison.zero? ? left["relativeDir"] <=> right["relativeDir"] : comparison
    end
  end
end

def created_at_time(value)
  text = value.to_s
  return Time.at(0).utc unless text.match?(CREATED_AT)

  Time.iso8601(text)
rescue ArgumentError
  Time.at(0).utc
end

# Inventory sort uses major.minor.patch only; prerelease and +metadata are ignored.
def semver_parts(value)
  match = value.to_s.match(SEMVER)
  match ? match.captures[0, 3].map(&:to_i) : [0, 0, 0]
end

def scan_library
  root = configured_root
  order = configured_sort
  items = []
  children = begin
    Dir.children(root)
  rescue Errno::ENOENT, Errno::EACCES
    raise CheckError, "the build library folder cannot be read"
  end
  children.sort.each do |name|
    next if skip_name?(name)

    items << inspect_child(root, name)
  end

  seen = {}
  items.each do |item|
    next unless item["status"] == "valid"

    key = [item["bundleID"], item["version"], item["build"]]
    if seen[key]
      item.replace(invalid_item(item["relativeDir"], "duplicate bundle ID, version, and build", item))
    else
      seen[key] = true
    end
  end

  valid = sort_items(items.select { |item| item["status"] == "valid" }, order)
  invalid = items.select { |item| item["status"] == "invalid" }
  truncated = valid.length > MAX_INDEX_ITEMS
  write_index(valid.first(MAX_INDEX_ITEMS) + invalid, truncated, order)
  { "valid" => valid, "invalid" => invalid, "truncated" => truncated, "sort" => order }
end

def write_index(items, truncated, order)
  # Private plugin cache only. The host must not treat this file as trusted input.
  data_dir = ENV["KIWIOS_DATA_DIR"]
  return unless data_dir && !data_dir.empty?

  FileUtils.mkdir_p(data_dir, mode: 0o700)
  payload = {
    "schema" => 1,
    "generatedAt" => Time.now.utc.iso8601,
    "truncated" => truncated,
    "sort" => order,
    "items" => items.map { |item| index_record(item) }
  }
  path = File.join(data_dir, INDEX_NAME)
  temporary = File.join(data_dir, ".#{INDEX_NAME}.#{Process.pid}.tmp")
  File.write(temporary, JSON.generate(payload))
  File.chmod(0o600, temporary)
  File.rename(temporary, path)
end

def index_record(item)
  item.slice(
    "id", "status", "reason", "relativeDir", "ipa", "sha256", "size", "project", "title",
    "description", "version", "build", "feature", "createdAt", "bundleID"
  ).compact
end

def emit_table(message, columns, rows, warning: false)
  shown = rows.first(MAX_ROWS)
  state = { "columns" => columns, "rows" => shown }
  while shown.any? && JSON.generate(state).bytesize > MAX_STATE_BYTES
    shown.pop
    state = { "columns" => columns, "rows" => shown }
  end
  omitted = rows.length - shown.length
  suffix = omitted.positive? ? "; showing #{shown.length} of #{rows.length}" : ""
  event((warning || omitted.positive?) ? "warn" : "ok", "#{message}#{suffix}", state)
end

def check_library
  result = scan_library
  valid = result["valid"].length
  invalid = result["invalid"].length
  detail = [invalid.positive? ? "#{invalid} invalid" : nil, result["truncated"] ? "library exceeds #{MAX_INDEX_ITEMS} valid builds" : nil].compact
  state = {
    "value" => valid,
    "unit" => valid == 1 ? "build" : "builds",
    "detail" => (detail.empty? ? "sorted by #{result["sort"]}" : "#{detail.join("; ")}; sorted by #{result["sort"]}")
  }
  if result["truncated"] || invalid.positive?
    event("warn", "#{valid} valid iOS #{valid == 1 ? "build" : "builds"}", state)
  else
    event("ok", valid.zero? ? "No iOS builds in the library" : "#{valid} valid iOS #{valid == 1 ? "build" : "builds"}", state)
  end
end

def check_builds
  result = scan_library
  rows = result["valid"].map do |item|
    {
      "id" => item["id"],
      "project" => item["project"],
      "title" => item["title"],
      "version" => "#{item["version"]} (#{item["build"]})",
      "feature" => item["feature"],
      "built" => item["createdAt"][0, 10]
    }
  end
  warning = result["truncated"] || result["invalid"].any?
  emit_table(
    "#{rows.length} valid iOS #{rows.length == 1 ? "build" : "builds"}",
    [
      { "id" => "project", "label" => "Project" },
      { "id" => "title", "label" => "Title" },
      { "id" => "version", "label" => "Version" },
      { "id" => "feature", "label" => "Feature" },
      { "id" => "built", "label" => "Built" }
    ],
    rows,
    warning: warning
  )
end

def check_invalid
  result = scan_library
  rows = result["invalid"].map do |item|
    {
      "id" => item["id"],
      "name" => item["relativeDir"],
      "reason" => item["reason"]
    }
  end
  emit_table(
    rows.empty? ? "No invalid builds" : "#{rows.length} invalid #{rows.length == 1 ? "build" : "builds"}",
    [
      { "id" => "name", "label" => "Directory" },
      { "id" => "reason", "label" => "Reason" }
    ],
    rows,
    warning: rows.any?
  )
end

def rescan
  puts JSON.generate("t" => "log", "lvl" => "info", "msg" => "Scanning the iOS build library")
  puts JSON.generate("t" => "progress", "msg" => "Reading staged builds")
  result = scan_library
  event(
    result["invalid"].any? || result["truncated"] ? "warn" : "ok",
    "#{result["valid"].length} valid, #{result["invalid"].length} invalid"
  )
end

def cleanup
  puts JSON.generate("t" => "log", "lvl" => "info", "msg" => "Applying library cleanup")
  result = scan_library
  removed = apply_cleanup(configured_root, result["valid"])
  result = scan_library
  event(removed.positive? ? "warn" : "ok", "Removed #{removed} #{removed == 1 ? "build" : "builds"}; #{result["valid"].length} remain")
end

def apply_cleanup(root, valid)
  keep_days = configured_keep_days
  max_bytes = configured_max_bytes
  remaining = valid.dup
  removed = 0
  if keep_days.positive?
    cutoff = Time.now.utc - (keep_days * 24 * 60 * 60)
    remaining, expired = remaining.partition { |item| created_at_time(item["createdAt"]) >= cutoff }
    expired.each { |item| removed += 1 if delete_build(root, item) }
  end
  if max_bytes.positive?
    remaining = sort_items(remaining, "newest").reverse
    total = remaining.sum { |item| item["size"].to_i }
    while total > max_bytes && remaining.any?
      item = remaining.shift
      next unless delete_build(root, item)

      total -= item["size"].to_i
      removed += 1
    end
  end
  removed
end

def delete_build(root, item)
  name = item["relativeDir"].to_s
  return false if name.empty? || name.include?("/") || name == "." || name == ".."

  path = File.join(root, name)
  status = File.lstat(path)
  return false if status.symlink? || !status.directory?

  FileUtils.remove_entry(path)
  true
rescue SystemCallError
  false
end

commands = {
  "library" => method(:check_library),
  "builds" => method(:check_builds),
  "invalid" => method(:check_invalid),
  "rescan" => method(:rescan),
  "cleanup" => method(:cleanup)
}

begin
  command = commands[ARGV.fetch(0, "")]
  raise CheckError, "unknown iOS build-library command" unless command

  command.call
rescue CheckError => error
  event("error", error.message)
  exit 2
end
