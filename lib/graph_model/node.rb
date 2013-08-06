module GraphModel
  
  class NodeError < StandardError; end
  class RelationshipError < StandardError; end
  
  module Node
    FIXED_ATTRIBUTES  = [:id].freeze

    module ClassMethods
      def setup_graph_model_node(options = {})
        options             = default_model_options.merge(options)
        class_attribute :model_options
        self.model_options  = options 
        
        attr_accessor :neo4j, :new_attributes

        attribute :id, type: Integer
        attribute :updated_at_i, type: Integer
        attribute :created_at_i, type: Integer
        
        setup_relationships
      end

      def property(name, options)
        if options.has_key? :index
          index = options.delete :index
          Neography::Rest.new.create_node_index("#{self.to_s.tableize}_index", index.to_s)
        end
        attribute name, options
      end
      
      def default_model_options
        {}
      end
      
      def build_object_from_neo4j(neo4j_object)
        new_node              = new
        new_node.neo4j        = neo4j_object
      
        # assign attributes
        attributes_to_assign  = attributes.keys
        
        attributes_to_assign.each do |attribute|
          new_node[attribute.to_sym] = new_node.neo4j[attribute.to_sym]
        end
      
        new_node.id           = new_node.neo4j.neo_id.to_i
        new_node
      end

      def create(attributes_hash = {})
        new_node                = new
        new_node.new_attributes = attributes_hash.stringify_keys!
        new_node.set_attributes
        
        # check for invalid attributes
        if new_node.valid?
          # store related_attributes for after node creation
          saved_related_attributes  = new_node.related_attributes
          new_node.allowed_attributes.merge!({ created_at_i: Time.now.to_i, updated_at_i: Time.now.to_i })

          node = Neography::Node.create(new_node.allowed_attributes)
          Neography::Rest.new.add_label node.neo_id, self.to_s


          new_node.allowed_attributes.each_pair do |key, value|
            Neography::Rest.new.add_to_index "#{self.to_s.tableize}_index",
                                             key,
                                             value,
                                             node.neo_id
          end


          new_node                  = build_object_from_neo4j node

          new_node.new_attributes   = saved_related_attributes
          new_node.manage_relationships if new_node.related_attributes
        end
        return new_node
      end
    
      def find(neo_id)
        build_object_from_neo4j Neography::Node.load(neo_id)
      end
    
      def all
        Neography::Rest.new.execute_query("MATCH (nodes:#{self.to_s}) RETURN nodes")["data"].map do |data|
          node = Neography::Node.load(parse_id data.first)
          build_object_from_neo4j node
        end
      end
    
      def first
        all.first
      end
    
      def last
        all.last
      end
    
      def count
        all.size
      end

      def parse_id(node)
        node["self"].gsub(/(\d+)$/).first.to_i
      end
      private :parse_id
      
      def method_missing(meth, *args, &block)
        if meth.to_s =~ /^find_by_(.+)$/
          run_find_by_method($1, *args, &block)
        elsif meth.to_s =~ /^find_first_by_(.+)$/
          run_find_first_by_method($1, *args, &block)
        else
          super # You *must* call super if you don't handle the
                # method, otherwise you'll mess up Ruby's method
                # lookup.
        end
      end

      def run_find_by_method(attrs, *args, &block)
        # Make an array of attribute names
        attrs = attrs.split('_and_')
        #
        ## #transpose will zip the two arrays together like so:
        ##   [[:a, :b, :c], [1, 2, 3]].transpose
        ##   # => [[:a, 1], [:b, 2], [:c, 3]]
        attrs_with_args = [attrs, args].transpose
        #
        ## Hash[] will take the passed associative array and turn it
        ## into a hash like so:
        ##   Hash[[[:a, 2], [:b, 4]]] # => { :a => 2, :b => 4 }
        conditions = Hash[attrs_with_args]
        #
        # build_query = ["it.object_type == '#{self.new.class.to_s}'"]
        build_query = []
        #
        conditions.each do |attr, value|
          build_query.push "n.#{attr} =~ '(?i)#{value}.*'"
        end
        cond_string = build_query.join(" AND ")

        # puts "g.V.filter{#{query}}.id".color(:green)
        #Neography::Rest.new.execute_script("g.V.filter{#{query}}.id").map do |neo_id|
        #  build_object_from_neo4j Neography::Node.load(neo_id)
        #end
        cypher = "MATCH n:#{self.to_s} WHERE #{cond_string} RETURN n"
        Neography::Rest.new.execute_query(cypher)["data"].map do |neo_id|
          id = parse_id(neo_id.first)
          build_object_from_neo4j Neography::Node.load(neo_id)
        end
      end
      
      def run_find_first_by_method(attrs, *args, &block)
        run_find_by_method(attrs, *args, &block).first
      end
    end

    module InstanceMethods
      def initialize(*args)
        self.neo4j        = Neography::Node.new
        neo4j.neo_server  = GraphModel.configuration.conn
        super(*args)
      end

      def save
      end

      def update(attributes_hash = {})
        raise GraphModel::NodeError, "object has no Neography::Node" unless neo4j

        self.new_attributes = attributes_hash.stringify_keys!
        allowed_attributes.merge!({updated_at_i: Time.now.to_i})
        self.attributes     = attributes.merge(allowed_attributes)

        # check for invalid attributes
        if valid?
          Neography::Rest.new.set_node_properties(neo4j, allowed_attributes)
          reset_related_attributes
          manage_relationships
          true
        else
          false
        end
      end

      def destroy
        neo4j.del
        nil
      end

      def persisted?
        !id.nil?
      end

      def new_record?
        !persisted?
      end

      def to_param
        id
      end

      def incoming
        neo4j.incoming.map { |n| self.class.build_object_from_neo4j n }
      end

      def outgoing
        neo4j.outgoing.map { |n| self.class.build_object_from_neo4j n }
      end

      def created_at
        DateTime.strptime(created_at_i.to_s, "%s")
      end

      def updated_at
        DateTime.strptime(updated_at_i.to_s, "%s")
      end

      def set_attributes
        self.attributes = attributes.merge(allowed_attributes)
      end

      def allowed_attributes
        @allowed_attributes ||= new_attributes.select {|key, value| attributes.has_key?(key) }.stringify_keys!
      end

      def related_attributes
        @related_attributes ||= new_attributes.select {|key, value| !attributes.has_key?(key) }.stringify_keys!
      end

      def reset_related_attributes
        @related_attributes = new_attributes.select {|key, value| !attributes.has_key?(key) }.stringify_keys!
      end
    end

    def self.included(receiver)
      receiver.extend         ClassMethods
      receiver.extend         GraphModel::RelationshipMethods::ClassMethods
      receiver.send :include, ::ActiveAttr::Model
      receiver.send :include, InstanceMethods
      receiver.send :include, GraphModel::RelationshipMethods::InstanceMethods
      receiver.send :setup_graph_model_node
    end
  end
end
