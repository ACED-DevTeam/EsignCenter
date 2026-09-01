# frozen_string_literal: true

module LoadActiveStorageConfigs
  module_function

  def call
    reload unless loaded?
  end

  def loaded?
    @loaded
  end

  def reload
    @loaded = true
  end
end
