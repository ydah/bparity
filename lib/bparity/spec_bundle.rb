# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "yaml"

module Bparity
  module SpecBundle
    VERSION = 2

    module Checksum
      module_function

      def calculate(bundle)
        payload = deep_sort(bundle.reject { |key, _| key.to_s == "checksum" })
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
      end

      def deep_sort(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, deep_sort(item)] }
        when Array then value.map { |item| deep_sort(item) }
        else value
        end
      end
    end

    module Validator
      module_function

      def validate!(bundle, verify_checksum: true)
        unless bundle.is_a?(Hash) && bundle["spec_bundle_version"] == VERSION
          raise InvalidBundleError, "Spec Bundle version 2 is required. Run `bparity synthesize` again."
        end
        unless bundle["subjects"].is_a?(Array)
          raise InvalidBundleError,
                "The Spec Bundle has no subjects. Record a corpus and run `bparity synthesize`."
        end

        bundle["subjects"].each do |subject|
          next if subject["name"] && subject["operations"].is_a?(Array)

          raise InvalidBundleError,
                "Each Spec Bundle subject needs a name and operations. Run `bparity synthesize` again."
        end
        return bundle unless verify_checksum && bundle["checksum"]
        return bundle if bundle["checksum"] == Checksum.calculate(bundle)

        raise InvalidBundleError,
              "The Spec Bundle checksum does not match. Do not edit it by hand; run `bparity synthesize` again."
      end
    end

    module Writer
      module_function

      def write(path, bundle)
        data = stringify(bundle)
        data["checksum"] = Checksum.calculate(data)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, YAML.dump(data))
        data
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end

    module Loader
      module_function

      def load(path, verify_checksum: true)
        data = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
        Validator.validate!(data, verify_checksum:)
      rescue Psych::Exception => e
        raise InvalidBundleError, "Cannot read #{path}: #{e.message}. Fix the YAML or regenerate the bundle."
      end
    end
  end
end
