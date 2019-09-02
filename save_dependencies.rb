require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'crystalball', '~> 0.7.0'
  gem 'neo4j-core'
  gem 'pry'
  gem 'rspec-core'
  gem 'parser'
end

require 'crystalball/map_generator/parser_strategy/processor'
require 'pry'

class Crystalball::MapGenerator::ParserStrategy::Processor
  def on_send(node)
    const = filtered_children(node).detect { |c| c.type == :const }
    return unless const

    namespace, _ = const.to_a
    scope_name = namespace ? qualified_name(qualified_name_from_node(namespace), current_scope) : current_scope
    unless consts_defined.include?(qualified_name(const.to_a.last, scope_name))
      scope_name = nil
    end
    add_constant_interacted(qualified_name_from_node(const), scope_name)
  end
end

root = File.expand_path(ARGV[0])
files = Dir.glob(File.join(root, '**/*.rb')) # .grep(/^((?!\_spec\.rb).)*$/)

nodes = files.map do |file|
  processor = Crystalball::MapGenerator::ParserStrategy::Processor.new
  {
    path: file.sub(root, ''),
    consts_defined: processor.consts_defined_in(file).uniq,
    consts_interacted_with: processor.consts_interacted_with_in(file).uniq,
    labels: file.end_with?('_spec.rb') ? 'Spec' : 'File'
  }
end

require 'neo4j/core/cypher_session/adaptors/http'
http_adaptor = Neo4j::Core::CypherSession::Adaptors::HTTP.new('http://neo4j:batata@localhost:7474')
connection = Neo4j::Core::CypherSession.new(http_adaptor)

query = nodes.reduce('') do |result, node|
  identifier = node[:path].gsub(/[^a-zA-Z1-9]/, '_')
  q = ''
  node[:consts_defined].each do |const|
    id = q.include?(identifier) || result.include?(identifier) ? identifier : "#{identifier}:#{node[:labels]} {path: \"#{node[:path]}\"}"
    const_identifier = const.gsub(/[^a-zA-Z1-9]/, '_')
    #q << "(#{identifier})-[:defines]->(#{const_identifier}:Const {name: \"#{const}\"}),"
    const_id = q.include?(const_identifier) || result.include?(const_identifier)? const_identifier : "#{const_identifier}:Const {name: \"#{const}\"}"
    q << "(#{id})-[:defines]->(#{const_id}),"
  end
  node[:consts_interacted_with].each do |const|
    id = q.include?(identifier) || result.include?(identifier) ? identifier : "#{identifier}:#{node[:labels]} {path: \"#{node[:path]}\"}"
    const_identifier = const.gsub(/[^a-zA-Z1-9]/, '_')
    const_id = q.include?(const_identifier) || result.include?(const_identifier)? const_identifier : "#{const_identifier}:Const {name: \"#{const}\"}"
    q << "(#{id})-[:interacts_with]->(#{const_id}),"
  end
  result << "#{q[0..-2]}\n," unless q.empty?
  result
end[0..-2]

connection.query("CREATE #{query}")

puts "Done"
