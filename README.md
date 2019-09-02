# trelawney

Generates a dependency graph of ruby files by checking which constants are defined in each file and then which constants are interacted with in each file.

# Dependencies
- neo4j

## Usage

- Adapt neo4j credentials
- `ruby save_dependencies.rb path/to/ruby/project/root`
