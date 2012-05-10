=begin
executable: TinyGem.new(ARGV[0]).package
---

# TinyGem: A tiny gem build tool

Version 1.0.0

Home: https://github.com/gabrielg/tinygem

`tinygem` is a tool to build a RubyGem from a single file. `tinygem` itself is
built using `tinygem`.

## Dependencies

`tinygem` has no library dependencies. It requires Ruby 1.9.

## Install

`gem install tinygem`

## Examples

Here's an example file to create a gem from:

    =begin
    author: Gabriel Gironda
    email: gabriel@gironda.org
    version: 1.0.0
    summary: A tinygem example
    description: Example gem created using tinygem
    homepage: http://www.example.com/
    executable: puts(ARGV.inspect)
    ---

    # Example gem

    ## TODO - Write README

    =end

    class ExampleGem
      # Do something
    end

Save this in `example.rb`, then run `tinygem example.rb`.

## TODO

* Add support for specifying runtime dependencies
* Write better docs
=end

require "tmpdir"
require "yaml"
require "pathname"
require "ripper"
require "fileutils"

#### Public Interface

# `TinyGem.new` takes a source `source_path` to turn into a gem. This path, of course,
# should specify a file that is formatted in the manner that TinyGem` expects. TinyGem
# is built using itself, so you can use it as an example.
class TinyGem

  # Initialize TinyGem with a path pointing at an appropriately formatted source file.
  def initialize(source_path)
    @source_path = Pathname(source_path).expand_path
  end

  # Given an optional `output_dir`, which defaults to the current `pwd`, generate a
  # RubyGem out of the source that TinyGem was initialized with.
  def package(output_dir = Pathname(Dir.pwd).expand_path)
    # Check the source
    check_source!
    # Turn the source into component parts to build a gem out of
    gem_parts = read_source_parts
    # Write these parts to a directory
    gem_dir = write_gem_dir(gem_parts)
    # Build a .gem file from this directory, and leave it in the `output_dir`
    build_package(gem_dir, output_dir)
  end

private

  # Name the gem we're building the same thing as the filename of the code being turned
  # into a gem, without the ".rb" extension.
  def gem_name
    @gem_name ||= @source_path.sub_ext("").basename.to_s
  end

  # Perform some quick sanity checks to make sure the source path is readable, and also
  # contains syntactically valid Ruby code. No point continuing, otherwise.
  def check_source!
    raise "#{@source_path} is not readable" unless @source_path.readable?
    output = %x[ruby -c #{@source_path} 2>&1]
    raise "#{@source_path} is not valid ruby:\n#{output}" unless $?.success?
    true
  end

  # Take the source and chunk it into its component parts, so we can use them to build
  # a valid RubyGem.
  def read_source_parts
    @source_parts ||= begin
      chunked_source = ChunkedSource.new(@source_path.open("r"))
      metadata_extractor = TinyGem::MetadataExtractor.new(chunked_source, 'name' => gem_name)
      {spec: metadata_extractor.as_gemspec, library: chunked_source.library,
       readme: chunked_source.readme, executable: metadata_extractor.executable_code}
    end
  end

  # Create a temporary directory to write the various gem parts into, so that the `gem`
  # command can work against it to build a RubyGem.
  def write_gem_dir(gem_parts)
    tmp = Pathname(Dir.mktmpdir)
    warn("Using #{tmp} as a place to build the gem")
    # Write out the gemspec
    (tmp + "#{gem_name}.gemspec").open("w") {|f| f << gem_parts[:spec]}
    # Write out the readme
    (tmp + "README.md").open("w") {|f| f << gem_parts[:readme]}
    # Write out the library itself
    (tmp + "#{gem_name}.rb").open("w") {|f| f << gem_parts[:library]}
    # If a chunk of code has been specified to build a command line executable
    # from, write that out
    if gem_parts[:executable]
      (tmp + gem_name).open("w") do |f|
        # Flip the executable bit on the binary file
        f.chmod(f.stat.mode | 0100)
        f << "#!/usr/bin/env ruby\n"
        f << "require #{gem_name.inspect}\n"
        f << "#{gem_parts[:executable]}\n"
      end
    end
    tmp
  end

  # Build a .gem from the given gem_dir, and move it to the output_dir.
  def build_package(gem_dir, output_dir)
    curdir = Dir.pwd
    Dir.chdir(gem_dir.to_s)
    output = `gem build #{gem_name}.gemspec 2>&1`
    raise "Couldn't build gem: #{output}" unless $?.success?
    warn(output)
    filename = output.match(/^\s+File: ([^\n]+)$/)[1]
    # Move the built .gem to the output_dir, since `gem` doesn't seem to
    # provide a way to specify the output location.
    FileUtils.mv(filename, output_dir + filename)
    Dir.chdir(curdir)
  end
end

# A `TinyGem::ChunkedSource` object takes a string or something 'IO-ish' that is
# then chunked into parts for use by TinyGem.
class TinyGem::ChunkedSource
  # The YAML trailing document separator, `---`, is used to distinguish the separation
  # between the YAML metadata part of the first multi-line comment in the file, and
  # the rest of the multi-line comment that contains the README.
  README_SEPARATOR = /\A---\s*\z/

  def initialize(source_io)
    @source_io = source_io
  end

  def metadata; chunked[:metadata]; end
  def readme; chunked[:readme]; end
  def library; chunked[:library]; end

private

  def chunked
    return @chunked if @chunked
    metadata, readme, library = '', '', ''
    state = :seeking_brief

    lexed_source = Ripper.lex(@source_io)
    lexed_source.each do |((line,col),type,token)|
      case state
      # Start off looking for the first multiline comment
      when :seeking_brief then
        # Switch state to read the metadata from the brief when it's found
        state = :read_metadata if type == :on_embdoc_beg
      when :read_metadata then
        metadata << token if type == :on_embdoc
        # Slurp lines until the separator between the YAML metadata and the readme
        # is found, then switch state
        state = :read_readme if token =~ README_SEPARATOR
        state = :read_library if type == :on_embdoc_end
      when :read_readme then
        readme << token if type == :on_embdoc
        # Slurp readme lines until the end of the multi-line comment is found,
        # then switch state to read the rest of the file contents in as the actual
        # library code.
        state = :read_library if type == :on_embdoc_end
      when :read_library then
        library << token
      end
    end

    @chunked = {metadata: metadata, readme: readme, library: library}
  end
end

# Extracts metadata from the file used to build the gemspec, amongst other things.
# It does this by first checking for any explicit values in the YAML metadata
# supplied - for any omitted values, it tries to infer them in various ways.
class TinyGem::MetadataExtractor
  # The keys valid for use in the YAML metadata
  SPEC_KEYS = %w[author email name version summary description homepage]
  VERSION_MATCH = %r[(Version:?|v)\s* # A version string starting with Version or v
                     (\d+\.\d+\.\d+)  # A int.int.int version number
                    ]xi
  HOMEPAGE_MATCH = %r[^\s*             # A line starting with any or no whitespace
                      \[?Home(page)?:? # Home, Homepage:, optionally starting a Markdown link
                      \s*(\]\()?       # Some more optional Markdown link formatting
                      (https?:\/\/[^\)\n]+)\)?\s* # Anything url-ish
                     ]xi
  SUMMARY_MATCH = /^.*[:alnum:]+.*$/

  # Takes some already chunked source, and some default values to use if no explicit
  # metadata is available, or none can be inferred.
  def initialize(chunked_source, defaults = {})
    @chunked_source = chunked_source
    @defaults = defaults
  end

  # Spits out a gemspec.
  def as_gemspec
    spec_values = SPEC_KEYS.inject({}) do |keys,spec_key|
      keys[spec_key] = metadata_hash[spec_key] || default_or_inferred_for(spec_key)
      keys
    end
    gemspec_from_values(spec_values)
  end

  def has_executable?
    !executable_code.nil?
  end

  # A bit of code to call in a binary that ships with the gem can be specified using
  # the `executable` key.
  def executable_code
    metadata_hash['executable']
  end

private

  # Given a hash, we build a nicely formatted gemspec.
  def gemspec_from_values(spec_values)
    %Q[Gem::Specification.new do |gem|
         gem.author        = #{spec_values['author'].inspect}
         gem.email         = #{spec_values['email'].inspect}
         gem.name          = #{spec_values['name'].inspect}
         gem.version       = #{spec_values['version'].inspect}
         gem.summary       = #{spec_values['summary'].inspect}
         gem.description   = #{spec_values['description'].strip.inspect}
         gem.homepage      = #{spec_values['homepage'].inspect}
         gem.files         = [#{"#{spec_values['name']}.rb".inspect}]
         gem.require_paths = ["."]
         gem.bindir        = "."
         #{"gem.executables   = [#{spec_values['name'].inspect}]" if has_executable?}
       end].gsub(/^\s{7}/, "")
  end

  # Check the defaults passed in during initialization, or try and get an inferred
  # one, or fail.
  def default_or_inferred_for(key_name)
    @defaults[key_name] || send("default_value_for_#{key_name}") || \
      raise("No default value for: #{key_name}")
  end

  # Try to pull an author name out of the git global config.
  def default_value_for_author
    git_global_config_for("user.name") do |author_val|
      warn("Using author from git as: #{author_val}")
    end
  end

  # Try to pull an author email out of the git global config.
  def default_value_for_email
    git_global_config_for("user.email") do |email_val|
      warn("Using email from git as: #{email_val}")
    end
  end

  # Searches the readme for something that looks like a version string to use
  # as a version number.
  def default_value_for_version
    positional_match_or_nil(@chunked_source.readme, VERSION_MATCH, 2) do |str|
      warn("Using version from README: #{str}")
    end
  end

  # Searches the readme for something that looks like a homepage.
  def default_value_for_homepage
    positional_match_or_nil(@chunked_source.readme, HOMEPAGE_MATCH, 3) do |str|
      warn("Using homepage from README: #{str}")
    end
  end

  # Uses the first non-blank line from the readme as a summary.
  def default_value_for_summary
    positional_match_or_nil(@chunked_source.readme, SUMMARY_MATCH, 0) do |str|
      warn("Using summary from README: #{str}")
    end
  end

  # Uses the entire contents of the readme as a description.
  def default_value_for_description
    warn("Using README as description")
    # RubyGems refuses to build a gem if the description contains `FIXME` or `TODO`,
    # which are perfectly valid words to use in a description, but alas.
    @chunked_source.readme.gsub(/FIXME/i, "FIZZIX-ME").gsub(/TODO/i, "TOODLES")
  end

  # The metadata specified in the YAML part of the brief.
  def metadata_hash
    @metadata_hash ||= YAML.load(@chunked_source.metadata) || {}
  rescue Psych::SyntaxError
    msg = "Bad metadata hash - are you sure it's valid YAML?\n#{@chunked_source.metadata}"
    raise SyntaxError, msg
  end

  # Fetches global config values out of git.
  def git_global_config_for(config_key)
    return nil unless system_has_git?
    value = %x[git config --global #{config_key}]
    conf_val = value.squeeze.strip.empty? ? nil : value.strip
    yield(conf_val) if conf_val
    conf_val
  end

  # When given some text, a regexp with captures, and a capture position, get back the
  # matched text at that position and yield it if a block is given, or return nil.
  def positional_match_or_nil(source, re, position)
    md = source.match(re)
    matched_substr = md && md[position]
    yield(matched_substr) if matched_substr
    matched_substr
  end

  def system_has_git?
    system("which git 2>&1 1>/dev/null")
  end
end