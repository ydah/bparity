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
      PROVENANCE_LEVELS = %w[A B C D].freeze
      FORMAL_LEVELS = %w[F0 F1 F2 F3 F4].freeze
      CONFORMANCE_MODES = %w[strict refinement contract].freeze

      module_function

      def validate!(bundle, verify_checksum: true)
        unless bundle.is_a?(Hash) && bundle["spec_bundle_version"] == VERSION
          raise InvalidBundleError, "Spec Bundle version 2 is required. Run `bparity synthesize` again."
        end
        unless bundle["subjects"].is_a?(Array) && !bundle["subjects"].empty?
          raise InvalidBundleError,
                "The Spec Bundle has no subjects. Record a corpus and run `bparity synthesize`."
        end

        mode = bundle.fetch("conformance_mode", "refinement")
        invalid!("conformance_mode must be strict, refinement, or contract") unless CONFORMANCE_MODES.include?(mode)
        validate_subjects!(bundle.fetch("subjects"))
        return bundle unless verify_checksum
        unless bundle["checksum"]
          raise InvalidBundleError,
                "The Spec Bundle has no checksum. Run `bparity synthesize` again."
        end
        return bundle if bundle["checksum"] == Checksum.calculate(bundle)

        raise InvalidBundleError,
              "The Spec Bundle checksum does not match. Do not edit it by hand; run `bparity synthesize` again."
      end

      def validate_subjects!(subjects)
        ids = []
        subject_names = []
        subjects.each do |subject|
          invalid!("each subject needs a non-empty name and an operations array") unless
            subject.is_a?(Hash) && present?(subject["name"]) && subject["operations"].is_a?(Array)
          subject_names << subject["name"]
          operation_names = []
          subject["operations"].each do |operation|
            validate_operation!(operation, ids)
            operation_names << operation["name"]
          end
          invalid!("operation names must be unique within #{subject['name']}") unless unique?(operation_names)
        end
        invalid!("subject names must be unique") unless unique?(subject_names)
        invalid!("example IDs must be unique") unless unique?(ids)
      end
      private_class_method :validate_subjects!

      def validate_operation!(operation, ids)
        invalid!("each operation needs a non-empty name and an examples array") unless
          operation.is_a?(Hash) && present?(operation["name"]) && operation["examples"].is_a?(Array)
        %w[params preconditions postconditions invariants].each do |field|
          invalid!("operation #{field} must be an array") if operation.key?(field) && !operation[field].is_a?(Array)
        end
        operation.fetch("examples").each { |example| validate_example!(example, ids) }
      end
      private_class_method :validate_operation!

      def validate_example!(example, ids)
        required = %w[id provenance_level formal_level provenance given expect]
        missing = required.reject { |field| example.is_a?(Hash) && example.key?(field) }
        invalid!("each example needs #{required.join(', ')}") unless missing.empty?
        invalid!("each example needs a non-empty ID") unless present?(example["id"])
        invalid!("example #{example['id']} has an invalid provenance level") unless
          PROVENANCE_LEVELS.include?(example["provenance_level"])
        invalid!("example #{example['id']} has an invalid formal level") unless
          FORMAL_LEVELS.include?(example["formal_level"])
        invalid!("example #{example['id']} provenance, given, and expect must be objects") unless
          %w[provenance given expect].all? { |field| example[field].is_a?(Hash) }
        ids << example["id"]
      end
      private_class_method :validate_example!

      def unique?(values) = values.length == values.uniq.length
      private_class_method :unique?

      def present?(value) = !value.to_s.strip.empty?
      private_class_method :present?

      def invalid!(detail)
        raise InvalidBundleError, "Invalid Spec Bundle: #{detail}. Run `bparity synthesize` again."
      end
      private_class_method :invalid!
    end

    module Writer
      module_function

      def write(path, bundle)
        data = stringify(bundle)
        Validator.validate!(data, verify_checksum: false)
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
      rescue Errno::ENOENT
        raise InvalidBundleError, "Cannot read #{path}. Run `bparity synthesize` or check the path."
      rescue Psych::Exception => e
        raise InvalidBundleError, "Cannot read #{path}: #{e.message}. Fix the YAML or regenerate the bundle."
      end
    end
  end
end
