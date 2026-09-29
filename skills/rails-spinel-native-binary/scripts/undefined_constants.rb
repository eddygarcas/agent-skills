#!/usr/bin/env ruby
# List constants the emitted app references (as `Const::X` or `Const.m`) that nothing in the tree defines.
# These are gems roundhouse does not model: each needs a facade (structural use) or a stub (expression use).
# Usage: ruby undefined_constants.rb <emitted-tree>
tree = ARGV[0] or abort "usage: undefined_constants.rb <emitted-tree>"
src = Dir[File.join(tree, "{app,runtime,config,db}/**/*.rb")] + Dir[File.join(tree, "{main,boot}.rb")]
text = src.map { |f| File.read(f) }.join("\n")
used = Dir[File.join(tree, "app/**/*.rb")].flat_map { |f| File.read(f).scan(/(?<![\w:])([A-Z][A-Za-z0-9]*)(?=::[A-Z]|\.[a-z_])/).flatten }.tally
core = %w[ARGV Array BasicObject Class Comparable Date DateTime Dir ENV Encoding Enumerable Errno File Float Hash
          IO Integer JSON Kernel Math Module Object OpenSSL Process Proc Queue Random Range Regexp Ruby Set Signal
          Singleton String StringIO Struct Symbol Tempfile Thread Time URI Base64 Digest SecureRandom Rails
          ActiveRecord ActiveSupport ActionController ActionDispatch ActionView ActionMailer ActiveJob ActiveStorage]
missing = used.reject { |c, _| core.include?(c) || text.match?(/^\s*(module|class)\s+#{c}\b|^\s*#{c}\s*=/) }
missing.sort_by { |_, n| -n }.each { |c, n| puts format("%5d  %s", n, c) }
warn "#{missing.size} undefined constant(s)"
