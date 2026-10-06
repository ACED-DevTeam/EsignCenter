# frozen_string_literal: true

namespace :starter_templates do
  desc 'Regenerate the committed starter-template PDFs and manifest.yml (lib/starter_templates)'
  task generate: :environment do
    StarterTemplates::Generator.call
  end
end
