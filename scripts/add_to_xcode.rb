#!/usr/bin/env ruby
#
# add_to_xcode.rb - Add Swift files to an Xcode project
#
# Usage:
#   scripts/add_to_xcode.rb [options] <file_path> [file_path...]
#
# Most arguments are inferred automatically:
#   - xcodeproj: auto-detected from current directory
#   - target: inferred from xcodeproj name
#   - group: inferred from each file's directory path
#
# Examples:
#   # Add files (everything inferred)
#   scripts/add_to_xcode.rb Trio/Sources/Services/AI/AIService.swift
#
#   # Add multiple files
#   scripts/add_to_xcode.rb Trio/Sources/Services/AI/File1.swift Trio/Sources/Services/AI/File2.swift
#
#   # Override target or project if needed
#   scripts/add_to_xcode.rb --project=Other.xcodeproj --target=OtherTarget Trio/Sources/Foo.swift
#
#   # Explicit group (overrides directory-based inference for all files)
#   scripts/add_to_xcode.rb --group=Trio/Sources/Services/AI Trio/Sources/Services/AI/File1.swift

require 'xcodeproj'
require 'optparse'

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] <file_path> [file_path...]"

  opts.on("--project=PROJECT", "Path to .xcodeproj (default: auto-detect)") do |v|
    options[:project] = v
  end

  opts.on("--target=TARGET", "Build target name (default: inferred from project name)") do |v|
    options[:target] = v
  end

  opts.on("--group=GROUP", "Group path in project (default: inferred from file directory)") do |v|
    options[:group] = v
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end

parser.parse!

if ARGV.empty?
  puts parser
  exit 1
end

file_paths = ARGV

# --- Auto-detect xcodeproj ---
project_path = options[:project]
unless project_path
  candidates = Dir.glob("*.xcodeproj")
  if candidates.length == 1
    project_path = candidates.first
  elsif candidates.empty?
    puts "Error: No .xcodeproj found in current directory. Use --project= to specify."
    exit 1
  else
    puts "Error: Multiple .xcodeproj found: #{candidates.join(', ')}. Use --project= to specify."
    exit 1
  end
end

unless File.exist?(project_path)
  puts "Error: Project not found: #{project_path}"
  exit 1
end

# --- Verify all files exist ---
file_paths.each do |file_path|
  unless File.exist?(file_path)
    puts "Error: File not found: #{file_path}"
    exit 1
  end
end

# --- Open project ---
project = Xcodeproj::Project.open(project_path)

# --- Resolve target ---
target_name = options[:target] || File.basename(project_path, '.xcodeproj')
target = project.targets.find { |t| t.name == target_name }
unless target
  puts "Error: Target '#{target_name}' not found"
  puts "Available targets: #{project.targets.map(&:name).join(', ')}"
  exit 1
end

# --- Helper: navigate/create group path ---
def find_or_create_group(project, group_path)
  path_components = group_path.split('/')
  current_group = project.main_group

  path_components.each do |component|
    existing = current_group.find_subpath(component, false)

    if existing.nil?
      existing = current_group.children.find { |child|
        child.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
        (child.name == component || child.display_name == component)
      }
    end

    if existing
      current_group = existing
    else
      current_group = current_group.new_group(component, component)
      puts "Created group: #{component}"
    end
  end

  current_group
end

# --- Add files, grouped by directory ---
added = 0
skipped = 0

# Group files by their directory so we resolve each group once
files_by_dir = file_paths.group_by { |f| File.dirname(f) }

files_by_dir.each do |dir, files|
  group_path = options[:group] || dir
  group = find_or_create_group(project, group_path)
  puts "Using group: #{group_path}"

  files.each do |file_path|
    file_name = File.basename(file_path)

    if group.files.any? { |f| f.display_name == file_name }
      puts "  Skipped (exists): #{file_name}"
      skipped += 1
      next
    end

    file_ref = group.new_file(file_name)
    file_ref.set_source_tree('<group>')
    target.source_build_phase.add_file_reference(file_ref)

    puts "  Added: #{file_name}"
    added += 1
  end
end

project.save
puts "\nDone! Added #{added} file(s), skipped #{skipped} existing file(s)."
