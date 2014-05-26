require 'active_model/array_serializer'
require 'active_model/serializable'
require 'active_model/serializer/associations'
require 'active_model/serializer/config'

require 'thread'

module ActiveModel
  class Serializer
    include Serializable

    @mutex = Mutex.new

    class << self
      def inherited(base)
        base._root = _root
        base._attributes = (_attributes || []).dup
        base._associations = (_associations || {}).dup
      end

      def setup
        @mutex.synchronize do
          yield CONFIG
        end
      end

      def embed(type, options={})
        CONFIG.embed = type
        CONFIG.embed_in_root = true if options[:embed_in_root] || options[:include]
        ActiveSupport::Deprecation.warn <<-WARN
** Notice: embed is deprecated. **
The use of .embed method on a Serializer will be soon removed, as this should have a global scope and not a class scope.
Please use the global .setup method instead:
ActiveModel::Serializer.setup do |config|
  config.embed = :#{type}
  config.embed_in_root = #{CONFIG.embed_in_root || false}
end
        WARN
      end

      if RUBY_VERSION >= '2.0'
        def serializer_for(resource, options={})
          if resource.respond_to?(:to_ary)
            ArraySerializer
          else
            begin
              namespace = options.fetch(:namespace, Object).name
              resource_namespace, resource_name = resource.class.name.split('::')
              _module = "#{namespace}::#{resource_namespace}".constantize
              _module.const_get "#{resource_name}Serializer"
            rescue NameError
              nil
            end
          end
        end
      else
        def serializer_for(resource, options={})
          if resource.respond_to?(:to_ary)
            ArraySerializer
          else
            _module  = options[:namespace]
            klass, _namespace = "#{resource.class.name}Serializer", _module

            if _namespace
              "#{_namespace}::#{klass}".safe_constantize || klass.safe_constantize
            else
              klass.safe_constantize
            end
          end
        end
      end

      attr_accessor :_root, :_attributes, :_associations
      alias root  _root=
      alias root= _root=

      def root_name
        name.demodulize.underscore.sub(/_serializer$/, '') if name
      end

      def attributes(*attrs)
        @_attributes.concat attrs

        attrs.each do |attr|
          define_method attr do
            object.read_attribute_for_serialization attr
          end unless method_defined?(attr)
        end
      end

      def has_one(*attrs)
        associate(Association::HasOne, *attrs)
      end

      def has_many(*attrs)
        associate(Association::HasMany, *attrs)
      end

      private

      def associate(klass, *attrs)
        options = attrs.extract_options!

        attrs.each do |attr|
          define_method attr do
            object.send attr
          end unless method_defined?(attr)

          @_associations[attr] = klass.new(attr, options)
        end
      end
    end

    def initialize(object, options={})
      @object        = object
      @scope         = options[:scope]
      @root          = options.fetch(:root, self.class._root)
      @meta_key      = options[:meta_key] || :meta
      @meta          = options[@meta_key]
      @wrap_in_array = options[:_wrap_in_array]
      @only          = Array(options[:only]) if options[:only]
      @except        = Array(options[:except]) if options[:except]
    end
    attr_accessor :object, :scope, :root, :meta_key, :meta

    def json_key
      if root == true || root.nil?
        self.class.root_name
      else
        root
      end
    end

    def attributes
      filter(self.class._attributes.dup).each_with_object({}) do |name, hash|
        hash[name] = send(name)
      end
    end

    def associations
      associations = self.class._associations
      included_associations = filter(associations.keys)
      associations.each_with_object({}) do |(name, association), hash|
        if included_associations.include? name
          if association.embed_ids?
            hash[association.key] = serialize_ids association
          elsif association.embed_objects?
            hash[association.embedded_key] = serialize association
          end
        end
      end
    end

    def filter(keys)
      if @only
        keys & @only
      elsif @except
        keys - @except
      else
        keys
      end
    end

    def embedded_in_root_associations
      associations = self.class._associations
      included_associations = filter(associations.keys)
      associations.each_with_object({}) do |(name, association), hash|
        if included_associations.include? name
          if association.embed_in_root?
            association_serializer = build_serializer(association)
            hash.merge! association_serializer.embedded_in_root_associations

            serialized_data = association_serializer.serializable_object
            key = association.root_key
            if hash.has_key?(key)
              hash[key].concat(serialized_data).uniq!
            else
              hash[key] = serialized_data
            end
          end
        end
      end
    end

    def association_options_for_serializer
      { scope: scope }.tap do |hash|
        hash[:namespace] = namespace if namespace
      end
    end

    def build_serializer(association)
      object = send(association.name)
      association.build_serializer(object, association_options_for_serializer)
    end

    def serialize(association)
      build_serializer(association).serializable_object
    end

    def serialize_ids(association)
      associated_data = send(association.name)
      if associated_data.respond_to?(:to_ary)
        associated_data.map { |elem| elem.read_attribute_for_serialization(association.embed_key) }
      else
        associated_data.read_attribute_for_serialization(association.embed_key) if associated_data
      end
    end

    def serializable_object(options={})
      return @wrap_in_array ? [] : nil if @object.nil?
      hash = attributes
      hash.merge! associations
      @wrap_in_array ? [hash] : hash
    end
    alias_method :serializable_hash, :serializable_object

    def namespace
      @namespace ||= begin
        if ActiveModel::Serializer::CONFIG.namespace
          get_namespace_name && Object.const_get(get_namespace_name)
        end
      end
    end

    def get_namespace_name
      modules = self.class.name.split('::')
      modules[0..-2].join('::') if modules.size > 1
    end
  end
end
