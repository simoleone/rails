module ActiveRecord
  class Relation
    delegate :to_sql, :to => :relation
    delegate :length, :collect, :find, :map, :each, :to => :to_a
    attr_reader :relation, :klass

    def initialize(klass, relation, readonly = false, preload = [], eager_load = [])
      @klass, @relation = klass, relation
      @readonly = readonly
      @associations_to_preload = preload
      @eager_load_associations = eager_load
      @loaded = false
    end

    def preload(*associations)
      create_new_relation(@relation, @readonly, @associations_to_preload + Array.wrap(associations))
    end

    def eager_load(*associations)
      create_new_relation(@relation, @readonly, @associations_to_preload, @eager_load_associations + Array.wrap(associations))
    end

    def readonly
      create_new_relation(@relation, true)
    end

    def select(selects)
      create_new_relation(@relation.project(selects))
    end

    def group(groups)
      create_new_relation(@relation.group(groups))
    end

    def order(orders)
      create_new_relation(@relation.order(orders))
    end

    def limit(limits)
      create_new_relation(@relation.take(limits))
    end

    def offset(offsets)
      create_new_relation(@relation.skip(offsets))
    end

    def on(join)
      create_new_relation(@relation.on(join))
    end

    def joins(join, join_type = nil)
      return self if join.blank?

      join_relation = case join
      when String
        @relation.join(join)
      when Hash, Array, Symbol
        if @klass.send(:array_of_strings?, join)
          @relation.join(join.join(' '))
        else
          @relation.join(@klass.send(:build_association_joins, join))
        end
      else
        @relation.join(join, join_type)
      end

      create_new_relation(join_relation)
    end

    def where(*args)
      if [String, Hash, Array].include?(args.first.class)
        conditions = @klass.send(:merge_conditions, args.size > 1 ? Array.wrap(args) : args.first)
      else
        conditions = args.first
      end

      create_new_relation(@relation.where(conditions))
    end

    def respond_to?(method)
      @relation.respond_to?(method) || Array.method_defined?(method) || super
    end

    def to_a
      return @records if loaded?

      @records = if @eager_load_associations.any?
        catch :invalid_query do
          return @klass.send(:find_with_associations, {
            :select => @relation.send(:select_clauses).join(', '),
            :joins => @relation.joins(relation),
            :group => @relation.send(:group_clauses).join(', '),
            :order => @relation.send(:order_clauses).join(', '),
            :conditions => @relation.send(:where_clauses).join("\n\tAND "),
            :limit => @relation.taken,
            :offset => @relation.skipped
            },
            ActiveRecord::Associations::ClassMethods::JoinDependency.new(@klass, @eager_load_associations, nil))
        end
        []
      else
        @klass.find_by_sql(@relation.to_sql)
      end

      @associations_to_preload.each {|associations| @klass.send(:preload_associations, @records, associations) }
      @records.each { |record| record.readonly! } if @readonly

      @loaded = true
      @records
    end

    alias all to_a

    def first
      if loaded?
        @records.first
      else
        @first ||= limit(1).to_a[0]
      end
    end

    def loaded?
      @loaded
    end

    def reload
      @loaded = false
      @records = @first = nil
      self
    end

    protected

    def method_missing(method, *args, &block)
      if @relation.respond_to?(method)
        @relation.send(method, *args, &block)
      elsif Array.method_defined?(method)
        to_a.send(method, *args, &block)
      elsif match = DynamicFinderMatch.match(method)
        attributes = match.attribute_names
        super unless @klass.send(:all_attributes_exists?, attributes)

        if match.finder?
          find_by_attributes(match, attributes, *args)
        elsif match.instantiator?
          find_or_instantiator_by_attributes(match, attributes, *args, &block)
        end
      else
        super
      end
    end

    def find_by_attributes(match, attributes, *args)
      conditions = attributes.inject({}) {|h, a| h[a] = args[attributes.index(a)]; h}
      result = where(conditions).send(match.finder)

      if match.bang? && result.blank?
        raise RecordNotFound, "Couldn't find #{@klass.name} with #{conditions.to_a.collect {|p| p.join(' = ')}.join(', ')}"
      else
        result
      end
    end

    def find_or_instantiator_by_attributes(match, attributes, *args)
      guard_protected_attributes = false

      if args[0].is_a?(Hash)
        guard_protected_attributes = true
        attributes_for_create = args[0].with_indifferent_access
        conditions = attributes_for_create.slice(*attributes).symbolize_keys
      else
        attributes_for_create = conditions = attributes.inject({}) {|h, a| h[a] = args[attributes.index(a)]; h}
      end

      record = where(conditions).first

      unless record
        record = @klass.new { |r| r.send(:attributes=, attributes_for_create, guard_protected_attributes) }
        yield(record) if block_given?
        record.save if match.instantiator == :create
      end

      record
    end

    def create_new_relation(relation, readonly = @readonly, preload = @associations_to_preload, eager_load = @eager_load_associations)
      Relation.new(@klass, relation, readonly, preload, eager_load)
    end

  end
end
