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

ROOT = File.expand_path(ARGV[0])
FILES = Dir.glob(File.join(ROOT, '**/*.rb'))
CACHE_FILE = 'cache.json'

def load_or_parse_files
  if File.exist?(CACHE_FILE)
    JSON.parse(File.read(CACHE_FILE)).map { |h| h.inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo} }
  else
    parse_files
  end
end

def parse_files
  result = FILES.map do |file|
    processor = Crystalball::MapGenerator::ParserStrategy::Processor.new
    {
      path: file.sub("#{ROOT}/", ''),
      consts_defined: processor.consts_defined_in(file).uniq,
      consts_interacted_with: processor.consts_interacted_with_in(file).uniq,
      labels: file.end_with?('_spec.rb') ? 'Spec' : 'File'
    }
  end
  File.write(CACHE_FILE, result.to_json)

  result
end

nodes = load_or_parse_files

require 'neo4j/core'
require 'neo4j/core/cypher_session/adaptors/http'
# Adapt to your config
http_adaptor = Neo4j::Core::CypherSession::Adaptors::HTTP.new('http://neo4j:batata@localhost:7474')
connection = Neo4j::Core::CypherSession.new(http_adaptor)

def create_relationship_query(node, const, relationship:)
  queries = []
  queries << "MERGE (:#{node[:labels]} {path: \"#{node[:path]}\"})"
  queries << "MERGE (:Const {name: \"#{const}\"})"
  queries << <<~QUERY
    MATCH (file:#{node[:labels]} {path: "#{node[:path]}"})
    MATCH (const:Const {name: "#{const}"})
    MERGE (file)-[:#{relationship}]->(const)
  QUERY
  queries
end

def execute_query(query, connection)
  puts "====", query, "===="
  connection.query(query)
end

queries = nodes.reduce([]) do |result, node|
  node[:consts_defined].each do |const|
    result.concat create_relationship_query(node, const, relationship: :defines)
  end
  node[:consts_interacted_with].each do |const|
    result.concat create_relationship_query(node, const, relationship: :interacts_with)
  end
  result
end

queries.each_slice(100) do |qs|
  connection.queries do
    qs.each do |q|
      puts "====", q, "===="
      append q
    end
  end
end

# if you have an endpoint that returns a json in the format
# { spec_path: time_in_seconds, other_spec_path: time_in_seconds ... }
# configure the environment variable SPEC_TIMES_URL with the url
if ENV['SPEC_TIMES_URL']
  require 'faraday'

  puts 'Fetching spec times'
  specs = JSON.parse(Faraday.get(ENV['SPEC_TIMES_URL']).body)
  specs.each do |path, time|
    query = <<~QUERY
      MATCH (spec:Spec {path: "#{path}"})
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
