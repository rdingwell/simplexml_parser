module SimpleXml
  # Represents a data criteria specification
  class DataCriteria

    attr_accessor :id, :field_values, :value, :negation, :negation_code_list_id, :derivation_operator, :children_criteria, :subset_operators
    attr_reader :hqmf_id, :title, :display_name, :description, :code_list_id, 
        :definition, :status, :effective_time, :inline_code_list, 
        :temporal_references, :specific_occurrence, 
        :specific_occurrence_const, :source_data_criteria
  
    include SimpleXml::Utilities
    
    # Create a new instance based on the supplied HQMF entry
    # @param [Nokogiri::XML::Element] entry the parsed HQMF entry
    def initialize(entry, id=nil)
      @entry = entry

      if (@entry)
        create_criteria(@entry, id)
      else
        create_grouping_criteria(id)
      end

      @source_data_criteria = @id
      @negation = false
      
      # the following remain nil:
      # @display_name, @children_criteria, @derivation_operator, @value, @field_values,
      # @effective_time , @inline_code_list, @negation_code_list_id, @temporal_references, @subset_operators
    end

    def create_criteria(entry, id)
      @entry = entry

      type = attr_val('@datatype')
      name = attr_val('@name')
      instance = attr_val('@instance')

      @description = "#{type}: #{name}"
      @title = name
      @code_list_id = attr_val('@oid')

      @hqmf_id = attr_val('@id')

      specifics_counter = nil
      if instance
        specifics_counter = HQMF::Counter.instance.next
        @specific_occurrence = instance.split[1]
        @specific_occurrence_const = @description.gsub(/\W/,' ').upcase.split.join('_')
        @id = id || format_id("#{instance} #{@title}#{specifics_counter}")
      else
        @id = id || format_id("#{@description}")
      end

      parts = type.split(',')
      def_and_status = parse_definition_and_status(type)
      @definition = def_and_status[:definition]
      @status = def_and_status[:status]

    end

    def create_grouping_criteria(id)
      @id = id
      @definition = 'derived'
      @description = ""
      @title = @id
    end

    def self.get_criteria(element, precondition_id, doc, subset=nil, operator=nil, update_id=false)
      
      if element.name == Precondition::TEMPORAL_OP
        # we have a chain of temporal references
        criteria = convert_precondition_to_criteria(Precondition.new(element, doc), doc, operator)
      elsif element.name == Precondition::LOGICAL_OP
        # we have a logical group on the right
        criteria = convert_precondition_to_criteria(Precondition.new(element, doc), doc, operator)
      elsif element.name == Precondition::FUNCTIONAL_OP
        criteria = doc.data_criteria(Precondition.new(element, doc).reference.id)
      else
        criteria = doc.criteria_map[element.at_xpath('@id').value].dup
        return criteria if criteria.id == HQMF::Document::MEASURE_PERIOD_ID

        criteria.id = "#{criteria.id}_precondition_#{precondition_id}" if update_id
        doc.derived_data_criteria << criteria

        attributes = element.xpath('attribute')
        if (attributes)
          attributes.each do |attribute|
            
            orig_key = attribute.at_xpath('@name').value
            key = DataCriteria.translate_field(orig_key)
            value = Attribute.translate_attribute(attribute, doc)

            if key == 'RESULT'
              criteria.value = value
              # puts "\t RENAMING TITLE... WE ONLY WANT TO DO THIS FOR COMPARISON"
              # TODO: REMOVE ME!!!!!!!!!!!!!!!!!!!!
              # criteria.value.instance_variable_set(:@title, 'result') 
            elsif key == 'NEGATION_RATIONALE'
              criteria.negation = true
              criteria.negation_code_list_id = value.code_list_id
            else
              # if value.is_a? Coded
              #   puts "\t RENAMING TITLE... WE ONLY WANT TO DO THIS FOR COMPARISON"
              #   TODO: REMOVE ME!!!!!!!!!!!!!!!!!!!!
              #   value.instance_variable_set(:@title, orig_key) 
              # end

              criteria.field_values ||= {}
              criteria.field_values[key] = value
            end

          end
        end
      end

      if subset
        criteria.subset_operators ||= []
        criteria.subset_operators << subset
      end

      criteria
    end

    def self.convert_precondition_to_criteria(precondition, doc, operator)
      if (precondition.reference)
        # precondition is a single element
        criteria = doc.data_criteria(precondition.reference.id)
      else
        # precondition is a group
        criteria = convert_to_grouping(precondition, doc, operator)
        doc.derived_data_criteria << criteria
      end
      criteria
    end

    def self.convert_to_grouping(precondition, doc, operator)
      grouping = DataCriteria.new nil, "GROUP_#{operator}_CHILDREN_#{HQMF::Counter.instance.next}"
      grouping.children_criteria = precondition.preconditions.map {|p| convert_precondition_to_criteria(p, doc, operator).id}
      grouping.derivation_operator = (precondition.conjunction_code == HQMF::Precondition::ALL_TRUE) ? HQMF::DataCriteria::XPRODUCT : HQMF::DataCriteria::UNION
      grouping
    end
    
    def dup
      DataCriteria.new(@entry, @id)
    end

    def add_temporal(temporal)
      @temporal_references ||= []
      @temporal_references << temporal
    end
    
    def self.translate_field(name)
      name = name.tr(' ','_').upcase
      name = 'ORDINAL' if name == 'ORDINALITY'
      raise "Unknown field name: #{name}" unless HQMF::DataCriteria::FIELDS[name] || name == 'RESULT' || name == 'NEGATION_RATIONALE'
      name
    end

    def to_model

      trs = temporal_references.collect {|t| t.to_model} if temporal_references
      if field_values
        fv = {}
        field_values.each {|k, v| fv[k] = v.to_model}
      end
      val = value.to_model if value
      subs = subset_operators.collect {|o| o.to_model} if subset_operators

      HQMF::DataCriteria.new(@id, @title, @display_name, @description, @code_list_id, @children_criteria, 
        @derivation_operator, @definition, @status, val, fv, @effective_time, @inline_code_list, 
        @negation, @negation_code_list_id, trs, subs, @specific_occurrence, 
        @specific_occurrence_const, @source_data_criteria)
    end

    private

    def format_id(value)
      value.gsub(/\W/,' ').split.collect {|word| word.strip.capitalize }.join
    end

    def parse_definition_and_status(type)

      type.gsub!('Patient Characteristic', 'Patient Characteristic,') if type.starts_with? 'Patient Characteristic'
      case type
      when 'Patient Characteristic, Sex'
        type = 'Patient Characteristic, Gender'
      end

      settings = HQMF::DataCriteria.get_settings_map.values.select {|x| x['title'] == type.downcase}
      raise "multiple settings found for #{type}" if settings.length > 1
      settings = settings.first

      if (settings.nil?)
        parts = type.split(',')
        definition = parts[0].tr(':','').downcase.strip.tr(' ','_')
        status = parts[1].downcase.strip.tr(' ','_') if parts.length > 1
        settings = {'definition' => definition, 'status' => status}
      end

      definition = settings['definition']
      status = settings['status']

      # fix oddity with medication discharge having a bad definition
      if definition == 'medication_discharge'
        definition = 'medication'
        status = 'discharge'
      end 
      status = nil if status && status.empty?

      {definition: definition, status: status}
    end
 
  end
  
end