# Post-emit helper: replace every receiverless call to the named methods with `nil`, and each such
# method's body with `nil`, using Prism for exact source ranges (multi-line calls included).
# Usage: ruby roundhouse-neutralize-calls.rb <tree> name1,name2,...
require "prism"
tree, names = ARGV
names = names.split(",").to_set
edited = 0
Dir[File.join(tree, "app/**/*.rb")].each do |path|
  src = File.binread(path)
  result = Prism.parse(src)
  next unless result.errors.empty?
  ranges = []
  visit = lambda do |node|
    return if node.nil?
    if node.is_a?(Prism::DefNode) && names.include?(node.name.to_s) && node.body
      l = node.body.location
      ranges << [l.start_offset, l.end_offset]
      return
    end
    if node.is_a?(Prism::CallNode) && node.receiver.nil? && names.include?(node.name.to_s)
      l = node.location
      ranges << [l.start_offset, l.end_offset]
      return
    end
    node.compact_child_nodes.each { |c| visit.(c) }
  end
  visit.(result.value)
  next if ranges.empty?
  ranges.sort.reverse.each { |s, e| src[s...e] = "nil" }
  File.binwrite(path, src)
  edited += 1
end
puts "neutralized #{names.to_a.join(", ")} in #{edited} files"
