#!/usr/bin/env ruby
# Exit 1 (listing hits) if any file under the given paths contains a denylisted identifier as a whole word.
# Usage: ruby sensitive_scan.rb --denylist DENYLIST.txt <path> [<path>...]
args = ARGV.dup
i = args.index("--denylist") or abort "usage: sensitive_scan.rb --denylist FILE <paths...>"
list_file = args.delete_at(i + 1); args.delete_at(i)
list = File.readlines(list_file, chomp: true).map(&:strip).reject { |w| w.empty? || w.start_with?("#") }
abort "empty denylist" if list.empty?
re = Regexp.union(list.map { |w| /(?<![A-Za-z0-9_])#{Regexp.escape(w)}(?![A-Za-z0-9_])/ })
hits = []
args.each do |root|
  files = File.directory?(root) ? Dir[File.join(root, "**", "*")].select { |f| File.file?(f) } : [root]
  files.each { |f| File.foreach(f).with_index(1) { |line, n| line.scan(re).each { |m| hits << "#{f}:#{n}: #{m}" } } }
end
if hits.empty?
  puts "sensitive scan: clean"
else
  puts "sensitive scan: #{hits.size} hit(s)"; puts hits.first(40); exit 1
end
