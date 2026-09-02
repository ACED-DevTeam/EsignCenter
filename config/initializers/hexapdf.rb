# frozen_string_literal: true

module HexaPDF
  module DigitalSignature
    # HexaPDF 1.7.0 strips every trailing zero byte from a signature's
    # /Contents before decoding it (the PDF pads the reserved slot with
    # zeros) — including a zero that is the last byte of the CMS itself: the
    # final byte of the RSA value, in one signature out of 256. The truncated
    # DER raised OpenSSL::ASN1::ASN1Error on every check of such a document,
    # so /verify called a genuine one "not verified" and the API verify tool
    # failed. Decoding the structure OpenSSL already parsed (it ignores the
    # padding) uses exactly the CMS length. Same structure walk as upstream.
    #
    # Pinned to the bug, not the version:
    # spec/lib/hexa_pdf/digital_signature/cms_handler_override_spec.rb reads the
    # installed gem's source and goes red the day an upgrade drops the strip —
    # delete this override (and that spec) then.
    class CMSHandler
      def embedded_tsa_signature
        return @embedded_tsa_signature if defined?(@embedded_tsa_signature)

        @embedded_tsa_signature = nil
        p7 = OpenSSL::ASN1.decode(@pkcs7.to_der)
        signed_data = p7.value[1].value[0]
        signer_info = signed_data.value[-1].value[0] # first (and only) signer info
        return unless signer_info.value[-1].tag == 1 # check for unsigned attributes

        timestamp_token = signer_info.value[-1].value.find do |unsigned_attr|
          unsigned_attr.value[0].value == 'id-smime-aa-timeStampToken'
        end
        return unless timestamp_token

        @embedded_tsa_signature = OpenSSL::PKCS7.new(timestamp_token.value[1].value[0])
      end
    end

    class Signatures
      private

      def generate_field_name
        index = (@document.acro_form.each_field
                 .map { |field| field.full_field_name.to_s.scan(/\ASignature(\d+)/).first&.first.to_i }
                 .max || 0) + 1
        "Signature#{index}"
      end
    end
  end

  module Encryption
    class SecurityHandler
      def encrypt_string(str, obj)
        return str.dup if str.empty? || obj == document.trailer[:Encrypt] || obj.type == :XRef ||
                          (obj.type == :Sig && obj[:Contents].equal?(str))

        key = object_key(obj.oid, obj.gen, string_algorithm)
        string_algorithm.encrypt(key, str).dup
      end
    end

    module AES
      module ClassMethods
        def unpad(data)
          padding_length = data.getbyte(-1)
          if !padding_length || padding_length > BLOCK_SIZE || padding_length.zero? ||
             data[-padding_length, padding_length].each_byte.any? { |byte| byte != padding_length }
            data
          else
            data[0...-padding_length]
          end
        end
      end
    end
  end

  module Type
    class Page
      # fix NoMethodError (undefined method `color_space' for an instance of HexaPDF::Type::Page)
      def color_space(name)
        GlobalConfiguration.constantize('color_space.map', name).new
      end
    end

    # fix NoMethodError: undefined method `field_value' for #<HexaPDF::Type::AcroForm::Field
    module AcroForm
      class Field
        def field_value
          ''
        end

        def terminal_field?
          kids = self[:Kids]

          # rubocop:disable Rails/Blank
          kids.nil? || kids.empty? || kids.none? { |kid| kid&.key?(:T) }
          # rubocop:enable Rails/Blank
        end
      end

      # fix NoMethodError: undefined method `stream' for an instance of Symbol
      class TextField
        def field_value
          return unless value[:V]
          return self[:V].to_s if self[:V].is_a?(Symbol)

          self[:V].is_a?(String) ? self[:V] : self[:V].stream
        end
      end

      class AppearanceGenerator
        def create_push_button_appearances
          nil
        end
      end
    end

    # comparison of Integer with HexaPDF::PDFArray failed
    class CIDFont < Font
      private

      def widths
        cache(:widths) do
          result = {}
          index = 0
          array = self[:W] || []

          while index < array.size
            entry = array[index]
            value = array[index + 1]

            if value.is_a?(Array) || value.is_a?(HexaPDF::PDFArray)
              value.each_with_index { |width, i| result[entry + i] = width }
              index += 2
            else
              width = array[index + 2]
              entry.upto(value) { |cid| result[cid] = width }
              index += 3
            end
          end

          result
        end
      end
    end
  end
end
