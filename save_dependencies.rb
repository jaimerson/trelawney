require 'bundler/setup'
Bundler.setup(:default)

require 'crystalball/map_generator/parser_strategy/processor'
require 'pry'

# This is a fix on crystalball's processor that should be backported there
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
files = Dir.glob(File.join(root, '**/*.rb'))

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
# Adapt to your config
http_adaptor = Neo4j::Core::CypherSession::Adaptors::HTTP.new('http://neo4j:batata@localhost:7474')
connection = Neo4j::Core::CypherSession.new(http_adaptor)

def create_relationship(node, const, relationship:, connection:)
  execute_query("MERGE (:#{node[:labels]} {path: \"#{node[:path]}\"})", connection)
  execute_query("MERGE (:Const {name: \"#{const}\"})", connection)
  query = <<~QUERY
    MATCH (file:#{node[:labels]} {path: "#{node[:path]}"})
    MATCH (const:Const {name: "#{const}"})
    MERGE (file)-[:#{relationship}]->(const)
  QUERY
  execute_query(query, connection)
end

def execute_query(query, connection)
  puts "====", query, "===="
  connection.query(query)
end

nodes.each do |node|
  node[:consts_defined].each do |const|
    create_relationship(node, const, relationship: :defines, connection: connection)
  end
  node[:consts_interacted_with].each do |const|
    create_relationship(node, const, relationship: :interacts_with, connection: connection)
  end
end

# if you have an endpoint that returns a json in the format
# { spec_path: time_in_seconds, other_spec_path: time_in_seconds ... }
# configure the environment variable SPEC_TIMES_URL with the url
if ENV['SPEC_TIMES_URL']
  require 'faraday'

  specs = JSON.parse(Faraday.get(ENV['SPEC_TIMES_URL']).body)
  specs.each do |path, time|
    query = <<~QUERY
      MATCH (spec:Spec {path: "/#{path}"})
      SET spec.time = #{time}
      RETURN spec
    QUERY
    execute_query(query, connection)
  end
  # When api does not have time values for all specs, set a random one below 1 second
  query = <<~QUERY
    MATCH (spec:Spec)
    WHERE spec.time IS NULL
    SET spec.time = RAND()
  QUERY
  execute_query(query, connection)
end

puts "Done"
