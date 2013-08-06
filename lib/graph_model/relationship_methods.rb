module GraphModel
    
  module RelationshipMethods
      
    RELATIONSHIP_TYPES  = {:relationship_out => :outgoing, :relationship_in => :incoming}.freeze
    
    module ClassMethods
      
      def setup_relationships
        class_attribute :relationships
        self.relationships  = []
      end
      
      
      [:relationship_out, :relationship_in].each do |relationship_method|
        define_method relationship_method do |name, options = {}|
      
          # Add Relationship instance methods
          RelationshipDefinition.new(RELATIONSHIP_TYPES[relationship_method], name, options).tap do |relationship_definition|
            define_relationship_methods(relationship_definition)
            relationships.push relationship_definition       
          end
      
        end
      end
    
      def define_relationship_methods(relationship_definition)
                
        # see the relationship object
        # for relationship :friends - friends
        define_method relationship_definition.name do
          direction = relationship_definition.direction.to_s
          name      = relationship_definition.name
          eval("self.neo4j.#{direction}(name)")
        end
        
        # get the relationship object
        # for relationship :friends - get_friends_relationship(other_node)
        define_method "get_#{relationship_definition.name.to_s}_relationship" do |other_node|
          
          if relationship_definition.direction == :outgoing
            script  = "g.v(#{self.id}).outE.filter{it.label == '#{relationship_definition.name.to_s}'}.inV.filter{it.id == #{other_node.id}}.back(2).id"
          elsif relationship_definition.direction == :incoming
            script  = "g.v(#{self.id}).inE.filter{it.label == '#{relationship_definition.name.to_s}'}.outV.filter{it.id == #{other_node.id}}.back(2).id"
          end
          
          GraphModel.configuration.conn.execute_script(script).map do |rel_id| 
            Neography::Relationship.load(GraphModel.configuration.conn, rel_id)
          end.first
          
        end        
      
        define_method "built_#{relationship_definition[:with].name.tableize.singularize}_nodes" do
          eval("@built_#{relationship_definition[:with].name.tableize.singularize}_nodes ||= []")
        end
        
        # see all the node objects at the other end of this relationship
        # for relationship :friends - friends_nodes
        define_method "#{relationship_definition.name.to_s}_nodes" do
          persisted_nodes = send(relationship_definition.name).map{|node| eval(node.object_type).find(node.neo_id) }
          persisted_nodes + eval("built_#{relationship_definition[:with].name.tableize.singularize}_nodes")
        end
        
        # build an un-persisted node from the :with option
        # for relationship :friends - build_friends
        define_method "build_#{relationship_definition.name.to_s}" do
          eval("built_#{relationship_definition[:with].name.tableize.singularize}_nodes").push(relationship_definition[:with].new)
        end
      
        # add a new node object to the relationship
        # for relationship :friends - add_friends(other_node)
        define_method "add_#{relationship_definition.name.to_s}" do |other_node|
          
          if relationship_definition[:with] != other_node.class
            msg = "cannot add a node of type #{other_node.class.to_s} to the #{relationship_definition.name.to_s} relationship. "
            msg +=  "Only #{relationship_definition[:with].name} nodes allowed."
            raise GraphModel::RelationshipError, msg
          end
        
          raise GraphModel::RelationshipError, "Can't add a node to this relationship unless it has first been saved to the database." unless other_node.persisted?
        
          send(relationship_definition.name) << other_node.neo4j
        end
      
        # remove a node object from the relationship
        # for relationship :friends - remove_friends(other_node)
        define_method "remove_#{relationship_definition.name.to_s}" do |other_node|
        
          relationship  = send("get_#{relationship_definition.name.to_s}_relationship", other_node)
          if relationship
            relationship.del
            return true
          else
            raise GraphModel::RelationshipError, "This relationship does not exist"
          end
          
        end
      
        # alias methods for related models
        
        # get all the node objects for this klass
        # for relationship :friends that are Doctor type - doctors
        define_method relationship_definition[:with].to_s.tableize do
          if related_nodes = send("#{relationship_definition.name.to_s}_nodes")
            related_nodes
          else
            []
          end
        end
        
        # assign all the node objects for this klass
        # for relationship :friends that are Doctor type - doctors_attributes(attributes)
        # does nothing at the moment - allows for use of fields_for helper
        define_method "#{relationship_definition[:with].to_s.tableize}_attributes=" do |attributes|
          # STUB
        end

      end
      
    end
    
    module InstanceMethods
      
      def relationships
        "instance relationships"
      end

      def incoming_relationships
        neo4j.rels.incoming
      end

      def outgoing_relationships
        neo4j.rels.outgoing
      end
      
      # the assumption here is that all relationships are many-to-many
      # as far as Neography / Neo4J is concerned this needn't be the case, but it's a good starting point
      def manage_relationships
        self.class.relationships.each do |relationship_definition|
          manage_relationship(relationship_definition)
        end
      end
      
      # manage a specific relationship
      def manage_relationship(relationship_definition)
        related_klass = relationship_definition[:with]
        attributes_key  = "#{related_klass.to_s.tableize}_attributes"
        
        # do this related_klass match any of the related_attributes.keys
        return false unless related_attributes.keys.include?(attributes_key) 
        
        # loop through attribute hashes for this related_klass
        related_attributes[attributes_key].each do |_, related_klass_attributes|
          
          related_klass_attributes.stringify_keys!

          # we are attempting to make a relationship by searching the :on_field option of the relationship
          realtionship_key    = relationship_definition[:on_field].to_s
          new_related_object  = related_klass.send("find_first_by_#{realtionship_key}", related_klass_attributes[realtionship_key]) ||
            related_klass.create(realtionship_key => related_klass_attributes[realtionship_key])
          
          # is this relationship due to be destroyed?
          if related_klass_attributes["_destroy"].to_i == 1
            # remove relationship
            send("remove_#{relationship_definition.name.to_s}", new_related_object)
            next
          end
          
          # update the related object if there are other attributes
          new_related_object.update(related_klass_attributes)
          
          make_relationship(relationship_definition, new_related_object) if new_related_object.persisted?
          
        end
          
          
      end
      
      def make_relationship(relationship_definition, new_related_object)
        nodes = send("#{relationship_definition.name.to_s}_nodes")
        # make the relationship if it does not aleady exist
        unless send("#{relationship_definition.name.to_s}_nodes").map(&:id).include?(new_related_object.id)
          send("add_#{relationship_definition.name.to_s}", new_related_object)
        end
      end
      
    end
          
  end
    
end