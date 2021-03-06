module SimpleXml
  # Class representing an HQMF document
  class Document
    include SimpleXml::Utilities
    attr_reader :measure_period, :id, :nqf_id, :hqmf_set_id, :hqmf_version_number, :cms_id, :title, :description, :populations, :attributes, :source_data_criteria, :derived_data_criteria, :criteria_map, :attribute_map, :measure_period_map

    MEASURE_PERIOD_TITLES = {'Measurement Period'=>:measure_period, 'Measurement Start Date'=>:measure_period_start, 'Measurement End Date'=>:measure_period_end}
      
    # Create a new SimpleXml::Document instance by parsing at file at the supplied path
    # @param [String] path the path to the HQMF document
    def initialize(xml_contents)
      @doc = @entry = Document.parse(xml_contents)
      details = @doc.at_xpath('measure/measureDetails')
      @id = details.at_xpath('uuid').text.upcase
      @hqmf_set_id = details.at_xpath('guid').text.upcase
      @hqmf_version_number = details.at_xpath('version').text.to_i
      @title = details.at_xpath('title').text
      @description = details.at_xpath('description').text
      @cms_id = "CMS#{details.at_xpath('emeasureid').text}v#{@hqmf_version_number}"
      @nqf_id = details.at_xpath('nqfid/@extension').value

      @attributes = []
      details.children.reject {|e| e.name == 'text'}.each do |attribute|
        attribute_data = Utilities::MEASURE_ATTRIBUTES_MAP[attribute.name.to_sym]
        if (attribute_data)
          attribute_data['value'] = attribute.at_xpath('@extension').try(:value) || attribute.text
          @attributes << HQMF::Attribute.from_json(attribute_data)
        end
      end

      @criteria_map = {}
      @measure_period_map = {
        details.at_xpath('period/@uuid').value => :measure_period,
        details.at_xpath('period/startDate/@uuid').value => :measure_period_start,
        details.at_xpath('period/stopDate/@uuid').value => :measure_period_end
      }
      @measure_period_map.keys.each do |key|
        @criteria_map[key] = OpenStruct.new(id: HQMF::Document::MEASURE_PERIOD_ID, hqmf_id: key)
      end
      
      # Extract the data criteria
      @source_data_criteria = []
      @derived_data_criteria = []
      @attribute_map = {}
      @doc.xpath('measure/elementLookUp/qdm').each do |entry|
        data_type = entry.at_xpath('@datatype').value
        if !['Timing Element', 'attribute'].include? data_type
          criteria = DataCriteria.new(entry)
          @source_data_criteria << criteria
          @criteria_map[criteria.hqmf_id] = criteria
        elsif data_type == 'attribute'
          attribute = Attribute.new(entry.at_xpath('@id').value, entry.at_xpath('@oid').value, entry.at_xpath('@name').value)
          @attribute_map[attribute.id] = attribute
        elsif data_type == 'Timing Element'
          name = entry.at_xpath('@name').value
          if MEASURE_PERIOD_TITLES[name]
            hqmf_id = entry.at_xpath('@uuid').value
            @criteria_map[hqmf_id] = OpenStruct.new(id: HQMF::Document::MEASURE_PERIOD_ID, hqmf_id: hqmf_id)
            @measure_period_map[hqmf_id] = MEASURE_PERIOD_TITLES[name]
          end
        end
      end

      # Extract the population criteria and population collections
      @populations = []
      @population_criteria = []
      
      population_defs = @doc.xpath('measure/measureGrouping/group')
      population_defs.each_with_index do |population_def, population_index|

        population = {}
        population_def.xpath('clause').each do |criteria_def|

          criteria = PopulationCriteria.new(criteria_def, self, population_index)
          @population_criteria << criteria
          population[criteria.type] = criteria.id

        end

        @doc.xpath('measure/measureObservations').children.reject {|e| e.name == 'text'}.each_with_index do |observ_def, observ_index|
          observ = PopulationCriteria.new(observ_def, self, population_index)
          @population_criteria << observ
          population[observ.type] = observ.id
          raise "multiple observations... don't know how to tie to populations" if observ_index > 0
        end

        population['id'] = "Population#{population_index}"
        population['title'] = "Population #{population_index}" if population_defs.length > 1
        @populations << population

      end


      puts "\t NEED TO HANDLE STRATIFICATIONS"
      # stratifier_id_def = population_def.at_xpath('cda:templateId/cda:item[@root="'+HQMF::Document::STRATIFIED_POPULATION_TEMPLATE_ID+'"]/@controlInformationRoot', NAMESPACES)
      # population['stratification'] = stratifier_id_def.value if stratifier_id_def

    end
    
    # Get all the population criteria defined by the measure
    # @return [Array] an array of SimpleXml::PopulationCriteria
    def all_population_criteria
      @population_criteria
    end
    
    # Get a specific population criteria by id.
    # @param [String] id the population identifier
    # @return [SimpleXml::PopulationCriteria] the matching criteria, raises an Exception if not found
    def population_criteria(id)
      find(@population_criteria, :id, id)
    end
    
    # Get all the data criteria defined by the measure
    # @return [Array] an array of SimpleXml::DataCriteria describing the data elements used by the measure
    def all_data_criteria
      @derived_data_criteria + source_data_criteria
    end
    
    # Get a specific data criteria by id.
    # @param [String] id the data criteria identifier
    # @return [SimpleXml::DataCriteria] the matching data criteria, raises an Exception if not found
    def data_criteria(id)
      find(all_data_criteria, :id, id)
    end
    
    # Parse an XML document at the supplied path
    # @return [Nokogiri::XML::Document]
    def self.parse(hqmf_contents)
      doc = Nokogiri::XML(hqmf_contents)
      doc
    end

    def to_model
      dcs = all_data_criteria.collect {|dc| dc.to_model}
      pcs = all_population_criteria.collect {|pc| pc.to_model}
      sdc = source_data_criteria.collect{|dc| dc.to_model}
      HQMF::Document.new(nqf_id, id, hqmf_set_id, hqmf_version_number, cms_id, title, description, pcs, dcs, sdc, attributes, measure_period, populations)
    end

    def measure_period
      r = HQMF::Range.from_json({
        'type' => "IVL_TS",
        'low' => { 'type' => "TS", 'value' => "201201010000", 'inclusive?' => true, 'derived?' => false },
        'high' => { 'type' => "TS", 'value' => "201212312359", 'inclusive?' => true, 'derived?' => false },
        'width' => { 'type' => "PQ", 'unit' => "a", 'value' => "1", 'inclusive?' => true, 'derived?' => false }
      });
    end
    
    private
    
    def find(collection, attribute, value)
      collection.find {|e| e.send(attribute)==value}
    end
  end
end
