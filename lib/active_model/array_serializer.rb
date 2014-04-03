require 'active_model/default_serializer'
require 'active_model/serializable'
require 'active_model/serializer'

module ActiveModel
  class ArraySerializer
    include Serializable

    class << self
      attr_accessor :_root
      alias root  _root=
      alias root= _root=
    end

    def initialize(object, options={})
      @object          = object
      @scope           = options[:scope]
      @root            = options.fetch(:root, self.class._root)
      @meta_key        = options[:meta_key] || :meta
      @meta            = options[@meta_key]
      @each_serializer = options[:each_serializer]
      @resource_name   = options[:resource_name]
      @options         = options.merge(root: nil)
    end
    attr_accessor :object, :scope, :root, :meta_key, :meta, :options

    def json_key
      if root.nil?
        @resource_name
      else
        root
      end
    end

    def serializer_for(item)
      serializer_class = @each_serializer || Serializer.serializer_for(item, options) || DefaultSerializer
      serializer_class.new(item, @options)
    end

    def serializable_object
      @object.map do |item|
        serializer_for(item).serializable_object
      end
    end
    alias_method :serializable_array, :serializable_object

    def embedded_in_root_associations
      @object.each_with_object({}) do |item, hash|
        serializer_for(item).embedded_in_root_associations.each_pair do |type, objects|
          next if !objects || objects.flatten.empty?

          if hash.has_key?(type)
            hash[type].concat(objects).uniq!
          else
            hash[type] = objects
          end
        end
      end
    end
  end
end
