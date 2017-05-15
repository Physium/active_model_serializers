# frozen_string_literal: true

require 'json'
module AMS
  # Lightweight mapping of a model to a JSON API resource object
  # with attributes and relationships
  #
  # The fundamental building block of AMS is the Serializer.
  # A Serializer is used by subclassing it, and then declaring its
  # type, attributes, relations, and uniquely identifying field.
  #
  # The term 'fields' may refer to attributes of the model or the names of related
  # models, as in {http://jsonapi.org/format/#document-resource-object-fields
  # JSON:API resource object fields}
  #
  # @example:
  #
  #  class ApplicationSerializer < AMS::Serializer; end
  #  class UserModelSerializer < ApplicationSerializer
  #    type :users
  #    id_field :id
  #    attribute :first_name, key: 'first-name'
  #    attribute :last_name, key: 'last-name'
  #    attribute :email
  #    relation :department, type: :departments, to: :one
  #    relation :roles, type: :roles, to: :many
  #  end
  #
  #  user = User.last
  #  ums = UserModelSerializer.new(user)
  #  ums.to_json
  class Serializer < BasicObject
    # delegate constant lookup to Object
    def self.const_missing(name)
      ::Object.const_get(name)
    end

    class << self
      attr_accessor :_attributes, :_relations, :_id_field, :_type

      def add_instance_method(body, receiver=self)
        cl = caller_locations[0]
        silence_warnings { receiver.module_eval body, cl.absolute_path, cl.lineno }
      end

      def add_class_method(body, receiver)
        cl = caller_locations[0]
        silence_warnings { receiver.class_eval body, cl.absolute_path, cl.lineno }
      end

      def silence_warnings
        original_verbose = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = original_verbose
      end

      def inherited(base)
        super
        base._attributes = _attributes.dup
        base._relations = _relations.dup
        base._type = base.name.split('::')[-1].sub('Serializer', '').downcase
        add_class_method "def class; #{base}; end", base
        add_instance_method "def id; object.id; end", base
      end

      def type(type)
        self._type = type
      end

      def id_field(id_field)
        self._id_field = id_field
        add_instance_method <<-METHOD
        def id
          object.#{id_field}
        end
        METHOD
      end

      def attribute(attribute_name, key: attribute_name)
        fail 'ForbiddenKey' if attribute_name == :id
        _attributes[attribute_name] = { key: key }
        add_instance_method <<-METHOD
        def #{attribute_name}
          object.#{attribute_name}
        end
        METHOD
      end

      def relation(relation_name, type:, to:, key: relation_name, **options)
        _relations[relation_name] = { key: key, type: type, to: to }
        case to
        when :many then _relation_to_many(relation_name, type: type, key: key, **options)
        when :one then _relation_to_one(relation_name, type: type, key: key, **options)
        else
          fail ArgumentError, "UnknownRelationship to='#{to}'"
        end
      end

      def _relation_to_many(relation_name, type:, key: relation_name, **options)
        ids_method = options.fetch(:ids) do
          "object.#{relation_name}.pluck(:id)"
        end
        add_instance_method <<-METHOD
          def related_#{relation_name}_ids
            #{ids_method}
          end

          def #{relation_name}
            related_#{relation_name}_ids.map do |id|
              relationship_object(id, "#{type}")
            end
          end
        METHOD
      end

      def _relation_to_one(relation_name, type:, key: relation_name, **options)
        id_method = options.fetch(:id) do
          "object.#{relation_name}.id"
        end
        add_instance_method <<-METHOD
          def related_#{relation_name}_id
            #{id_method}
          end

          def #{relation_name}
            id = related_#{relation_name}_id
            relationship_object(id, "#{type}")
          end
        METHOD
      end
    end
    self._attributes = {}
    self._relations = {}

    attr_reader :object

    # @param model [Object] the model whose data is used in serialization
    def initialize(object)
      @object = object
    end

    def as_json
      {
        id: id,
        type: type
      }.merge({
        attributes: attributes,
        relationships: relations
      }.reject { |_, v| v.empty? })
    end

    def to_json
      dump(as_json)
    end

    def attributes
      fields = {}
      _attributes.each do |attribute_name, config|
        fields[config[:key]] = send(attribute_name)
      end
      fields
    end

    def relations
      fields = {}
      _relations.each do |relation_name, config|
        fields[config[:key]] = send(relation_name)
      end
      fields
    end

    def type
      self.class._type
    end

    def _attributes
      self.class._attributes
    end

    def _relations
      self.class._relations
    end

    def relationship_object(id, type)
      {
        "data": { "id": id, "type": type }, # resource linkage
      }
    end

    def dump(obj)
      JSON.dump(obj)
    end

    def send(*args)
      __send__(*args)
    end
  end
end