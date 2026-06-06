# frozen_string_literal: true

module Params
  class TemplateCreateValidator < BaseValidator
    FIELD_TYPES = %w[
      text date checkbox radio signature number multiple
      select initials image file stamp cells phone payment
    ].freeze

    OPTION_FIELD_TYPES = %w[radio multiple].freeze

    MAX_DOCUMENTS = 20
    MAX_SUBMITTERS = 100
    MAX_FIELDS = 1000
    MAX_AREAS = 200
    MAX_OPTIONS = 200

    def call
      data = params[:template].presence || params

      required(data, :documents)
      type(data, :documents, Array)
      type(data, :name, String)
      type(data, :external_id, String)
      type(data, :folder_name, String)
      type(data, :submitters, Array)
      type(data, :fields, Array)

      validate_sizes(data)

      in_path(data, :documents) do |documents|
        raise_error('documents must include at least one document') if documents.blank?
      end

      @document_count = Array.wrap(data[:documents]).size
      @submitter_names = submitter_names(data)

      validate_unique_submitter_names(data)

      in_path_each(data, :documents) { |document| validate_document(document) }
      in_path_each(data, :submitters) { |submitter| validate_submitter(submitter) }
      in_path_each(data, :fields) { |field| validate_field(field) }

      true
    end

    def validate_sizes(data)
      raise_error("documents must not exceed #{MAX_DOCUMENTS} items") if oversized?(data[:documents], MAX_DOCUMENTS)
      raise_error("submitters must not exceed #{MAX_SUBMITTERS} items") if oversized?(data[:submitters], MAX_SUBMITTERS)
      raise_error("fields must not exceed #{MAX_FIELDS} items") if oversized?(data[:fields], MAX_FIELDS)
    end

    def validate_document(document)
      required(document, :file, message: 'file is required (base64-encoded document)')
      type(document, :file, String)
      type(document, :name, String)
    end

    def validate_submitter(submitter)
      type(submitter, :name, String)
      type(submitter, :role, String)
    end

    def validate_field(field)
      type(field, :name, String)
      value_in(field, :type, FIELD_TYPES, allow_nil: true)
      type(field, :role, String)
      boolean(field, :required)
      boolean(field, :readonly)
      type(field, :areas, Array)
      type(field, :options, Array)

      raise_error("areas must not exceed #{MAX_AREAS} items") if oversized?(field[:areas], MAX_AREAS)
      raise_error("options must not exceed #{MAX_OPTIONS} items") if oversized?(field[:options], MAX_OPTIONS)

      validate_field_role(field)
      validate_field_options(field)

      in_path_each(field, :options) { |option| required(option, :value, message: 'option value is required') }
      in_path_each(field, :areas) { |area| validate_area(field, area) }
    end

    def validate_field_role(field)
      return if field[:role].blank?
      return if @submitter_names.include?(field[:role])

      raise_error("role '#{field[:role]}' does not match any submitter (#{@submitter_names.join(', ')})")
    end

    def validate_field_options(field)
      return unless OPTION_FIELD_TYPES.include?(field[:type])

      required(field, :options, message: "#{field[:type]} field requires options")

      return if Array.wrap(field[:areas]).present?

      raise_error("#{field[:type]} field requires an area for each option")
    end

    def validate_area(field, area)
      required(area, %i[x y w h])

      validate_coordinate(area, :x)
      validate_coordinate(area, :y)
      validate_coordinate(area, :w)
      validate_coordinate(area, :h)
      validate_page(area)
      validate_area_document(area)
      validate_area_option(field, area)
    end

    def validate_coordinate(area, key)
      value = area[key]

      return if numeric?(value) && value.to_f >= 0 && value.to_f <= 1

      raise_error("#{key} must be a number between 0 and 1")
    end

    def validate_page(area)
      return if area[:page].nil?
      return if non_negative_integer?(area[:page])

      raise_error('page must be a non-negative integer')
    end

    def validate_area_document(area)
      index = area[:document].present? ? area[:document].to_i : 0

      return if @document_count.positive? && index >= 0 && index < @document_count

      raise_error("area document index #{index} is out of range (#{@document_count} document(s) provided)")
    end

    def validate_area_option(field, area)
      return unless OPTION_FIELD_TYPES.include?(field[:type])

      values = Array.wrap(field[:options]).filter_map { |option| option[:value].presence }
      ref = area[:option]

      return if ref.present? && (values.include?(ref.to_s) || valid_option_index?(ref, values.size))

      raise_error("each area of a #{field[:type]} field must reference an option via `option`")
    end

    private

    def effective_submitter_names(data)
      Array.wrap(data[:submitters]).filter_map { |submitter| submitter[:name].presence || submitter[:role].presence }
    end

    def submitter_names(data)
      effective_submitter_names(data).presence || [Template::DEFAULT_SUBMITTER_NAME]
    end

    def validate_unique_submitter_names(data)
      names = effective_submitter_names(data)

      raise_error('submitters must have unique names') if names.uniq.size != names.size
    end

    def oversized?(value, limit)
      Array.wrap(value).size > limit
    end

    def valid_option_index?(ref, size)
      integer?(ref) && ref.to_i >= 0 && ref.to_i < size
    end

    def non_negative_integer?(value)
      case value
      when Integer then value >= 0
      when String then value.match?(/\A\d+\z/)
      else false
      end
    end

    def numeric?(value)
      Float(value)
      true
    rescue ArgumentError, TypeError
      false
    end

    def integer?(value)
      Integer(value)
      true
    rescue ArgumentError, TypeError
      false
    end
  end
end
