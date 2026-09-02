# frozen_string_literal: true

# config/initializers/hexapdf.rb re-implements CMSHandler#embedded_tsa_signature
# because HexaPDF strips every trailing zero byte from a signature's /Contents
# before decoding it — and one genuine CMS in 256 ends in a zero byte, which
# the strip took with it. An override shadows the gem silently, so this pins
# it to the bug rather than to a version: the day a HexaPDF upgrade drops the
# strip, the first example goes red and the override must go.
RSpec.describe HexaPDF::DigitalSignature::CMSHandler do
  let(:gem_source) do
    File.read(File.join(Gem.loaded_specs['hexapdf'].gem_dir, 'lib/hexapdf/digital_signature/cms_handler.rb'))
  end

  it 'is still needed: the installed gem strips trailing zero bytes before decoding the CMS' do
    upstream_method = gem_source[/def embedded_tsa_signature.*?def verify/m]

    expect(upstream_method).to include('signature_dict.contents.sub(/\x00*\z/'),
                               "HexaPDF #{HexaPDF::VERSION} no longer strips trailing zeros in " \
                               'embedded_tsa_signature: drop the override in config/initializers/hexapdf.rb ' \
                               'and delete this spec'
  end

  it 'is the method HexaPDF actually calls' do
    location = described_class.instance_method(:embedded_tsa_signature).source_location

    expect(location.first).to end_with('config/initializers/hexapdf.rb')
  end
end
