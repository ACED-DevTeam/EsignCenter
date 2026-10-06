# frozen_string_literal: true

require 'tmpdir'

RSpec.describe PublicArtifacts do
  it 'rejects private artifacts while allowing source, fixture documents and example env files' do
    %w[.env .env.production preview.env evidence/build.log evidence/browser/page.png backups/db.sql db/export.dump
       docs/release-readiness-2026-10-03.md .playwright-cli/page.yml plans/private-review.md].each do |path|
      expect(described_class.forbidden?(path)).to be(true), path
    end

    %w[.env.example .env.production.example db/schema.rb db/structure.sql db/seeds.sql spec/fixtures/sample-document.pdf
       spec/fixtures/stripe/event-invoice.paid.json docs/operations.md].each do |path|
      expect(described_class.forbidden?(path)).to be(false), path
    end
  end

  it 'finds an ignored artifact that was force-added, without returning its contents' do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, '.gitignore'), "preview.env\n")
      File.write(File.join(directory, 'preview.env'), "SYNTHETIC_FIXTURE=value\n")
      system('git', 'init', '--quiet', directory, exception: true)
      system('git', '-C', directory, 'add', '--force', 'preview.env', exception: true)

      expect(described_class.tracked_failures(directory)).to eq(['preview.env'])
    end
  end
end
