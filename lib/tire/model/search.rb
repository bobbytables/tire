module Tire
  module Model

    # Main module containing the search infrastructure for ActiveModel classes.
    #
    # By including this module, you'll provide the model with facilities to
    # perform searches against index, define index settings and mappings,
    # access the index object, etc.
    #
    # All the _Tire_ methods are accessible via the "proxy" class and instance
    # methods of the model, named `tire`, eg. `Article.tire.search 'foo'`.
    #
    # When there's no clash with a method in the class (your own, defined by another gem, etc)
    # _Tire_ will bring these methods to the top-level namespace of the class,
    # eg. `Article.search 'foo'`.
    #
    # You'll find the relevant methods in the ClassMethods and InstanceMethods module.
    #
    #
    module Search

      # Alias for Tire::Model::Naming::ClassMethods.index_prefix
      #
      def self.index_prefix(*args)
        Naming::ClassMethods.index_prefix(*args)
      end

      module ClassMethods

        # Returns search results for a given query.
        #
        # Query can be passed simply as a String:
        #
        #     Article.search 'love'
        #
        # Any options, such as pagination or sorting, can be passed as a second argument:
        #
        #     Article.search 'love', :per_page => 25, :page => 2
        #     Article.search 'love', :sort => 'title'
        #
        # For more powerful query definition, use the query DSL passed as a block:
        #
        #     Article.search do
        #       query { terms :tags, ['ruby', 'python'] }
        #       facet 'tags' { terms :tags }
        #     end
        #
        # You can pass options as the first argument, in this case:
        #
        #     Article.search :per_page => 25, :page => 2 do
        #       query { string 'love' }
        #     end
        #
        # This methods returns a Tire::Results::Collection instance, containing instances
        # of Tire::Results::Item, populated by the data available in _ElasticSearch, by default.
        #
        # If you'd like to load the "real" models from the database, you may use the `:load` option:
        #
        #     Article.search 'love', :load => true
        #
        # You can pass options as a Hash to the model's `find` method:
        #
        #     Article.search :load => { :include => 'comments' } do ... end
        #
        def search(*args, &block)
          default_options = {:type => document_type, :index => index.name}

          if block_given?
            options = args.shift || {}
          else
            query, options = args
            options ||= {}
          end

          sort      = Array( options[:order] || options[:sort] )
          options   = default_options.update(options)

          s = Tire::Search::Search.new(options.delete(:index), options)
          s.size( options[:per_page].to_i ) if options[:per_page]
          s.from( options[:page].to_i <= 1 ? 0 : (options[:per_page].to_i * (options[:page].to_i-1)) ) if options[:page] && options[:per_page]
          s.sort do
            sort.each do |t|
              field_name, direction = t.split(' ')
              by field_name, direction
            end
          end unless sort.empty?

          if block_given?
            block.arity < 1 ? s.instance_eval(&block) : block.call(s)
          else
            s.query { string query }
            # TODO: Actualy, allow passing all the valid options from
            # <http://www.elasticsearch.org/guide/reference/api/search/uri-request.html>
            s.fields Array(options[:fields]) if options[:fields]
          end

          s.perform.results
        end

        # Returns a Tire::Index instance for this model.
        #
        # Example usage: `Article.index.refresh`.
        #
        def index
          name = index_name.respond_to?(:to_proc) ? klass.instance_eval(&index_name) : index_name
          @index = Index.new(name)
        end

      end

      module InstanceMethods

        # Returns a Tire::Index instance for this instance of the model.
        #
        # Example usage: `@article.index.refresh`.
        #
        def index
          instance.class.tire.index
        end

        # Updates the index in _ElasticSearch_.
        #
        # On model instance create or update, it will store its serialized representation in the index.
        #
        # On model destroy, it will remove the corresponding document from the index.
        #
        # It will also execute any `<after|before>_update_elasticsearch_index` callback hooks.
        #
        def update_index
          instance.send :_run_update_elasticsearch_index_callbacks do
            if instance.destroyed?
              index.remove instance
            else
              response  = index.store( instance, {:percolate => percolator} )
              instance.id     ||= response['_id']      if instance.respond_to?(:id=)
              instance._index   = response['_index']   if instance.respond_to?(:_index=)
              instance._type    = response['_type']    if instance.respond_to?(:_type=)
              instance._version = response['_version'] if instance.respond_to?(:_version=)
              instance.matches  = response['matches']  if instance.respond_to?(:matches=)
              self
            end
          end
        end
        alias :update_elasticsearch_index  :update_index
        alias :update_elastic_search_index :update_index

        # The default JSON serialization of the model, based on its `#to_hash` representation.
        #
        # If you don't define any mapping, the model is serialized as-is.
        #
        # If you do define the mapping for _ElasticSearch_, only attributes
        # declared in the mapping are serialized.
        #
        def to_indexed_json
          if instance.class.tire.mapping.empty?
            instance.to_hash.reject {|key,_| key.to_s == 'id' || key.to_s == 'type' }.to_json
          else
            instance.to_hash.
            reject { |key, value| ! instance.class.tire.mapping.keys.map(&:to_s).include?(key.to_s) }.
            to_json
          end
        end

        def matches
          @attributes['matches']
        end

        def matches=(value)
          @attributes ||= {}; @attributes['matches'] = value
        end

      end

      module Loader

        # Load the "real" model from the database via the corresponding model's `find` method.
        #
        # Notice that there's an option to eagerly load models with the `:load` option
        # for the search method.
        #
        def load(options=nil)
          options ? self.class.find(self.id, options) : self.class.find(self.id)
        end

      end

      # An object containing _Tire's_ model class methods, accessed as `Article.tire`.
      #
      class ClassMethodsProxy
        include Tire::Model::Naming::ClassMethods
        include Tire::Model::Import::ClassMethods
        include Tire::Model::Indexing::ClassMethods
        include Tire::Model::Percolate::ClassMethods
        include ClassMethods

        INTERFACE = public_instance_methods.map(&:to_sym) - Object.public_instance_methods.map(&:to_sym)

        attr_reader :klass
        def initialize(klass)
          @klass = klass
        end

      end

      # An object containing _Tire's_ model instance methods, accessed as `@article.tire`.
      #
      class InstanceMethodsProxy
        include Tire::Model::Naming::InstanceMethods
        include Tire::Model::Percolate::InstanceMethods
        include InstanceMethods

        INTERFACE = public_instance_methods.map(&:to_sym) - Object.public_instance_methods.map(&:to_sym)

        attr_reader :instance
        def initialize(instance)
          @instance = instance
        end
      end

      # A hook triggered by the `include Tire::Model::Search` statement in the model.
      #
      def self.included(base)
        base.class_eval do

          # Returns proxy to the _Tire's_ class methods.
          #
          def self.tire &block
            @__tire__ ||= ClassMethodsProxy.new(self)

            @__tire__.instance_eval(&block) if block_given?
            @__tire__
          end

          # Returns proxy to the _Tire's_ instance methods.
          #
          def tire &block
            @__tire__ ||= InstanceMethodsProxy.new(self)

            @__tire__.instance_eval(&block) if block_given?
            @__tire__
          end

          # Define _Tire's_ callbacks (<after|before>_update_elasticsearch_index).
          #
          define_model_callbacks(:update_elasticsearch_index, :only => [:after, :before]) if \
            respond_to?(:define_model_callbacks)

          # Serialize the model as a Hash.
          #
          # Uses `serializable_hash` representation of the model,
          # unless implemented in the model already.
          #
          def to_hash
            self.serializable_hash
          end unless instance_methods.map(&:to_sym).include?(:to_hash)

        end

        # Alias _Tire's_ class methods in the top-level namespace of the model,
        # unless there's a conflict with existing method.
        #
        ClassMethodsProxy::INTERFACE.each do |method|
          base.class_eval <<-"end;", __FILE__, __LINE__ unless base.public_methods.map(&:to_sym).include?(method.to_sym)
            def self.#{method}(*args, &block)                     # def search(*args, &block)
              tire.__send__(#{method.inspect}, *args, &block)     #   tire.__send__(:search, *args, &block)
            end                                                   # end
          end;
        end

        # Alias _Tire's_ instance methods in the top-level namespace of the model,
        # unless there's a conflict with existing method
        InstanceMethodsProxy::INTERFACE.each do |method|
          base.class_eval <<-"end;", __FILE__, __LINE__ unless base.instance_methods.map(&:to_sym).include?(method.to_sym)
            def #{method}(*args, &block)                          # def to_indexed_json(*args, &block)
              tire.__send__(#{method.inspect}, *args, &block)     #   tire.__send__(:to_indexed_json, *args, &block)
            end                                                   # end
          end;
        end

        # Include the `load` functionality in Results::Item
        #
        Results::Item.send :include, Loader
      end

      
    end

  end
end
