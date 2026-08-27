# frozen_string_literal: true

require "json"
require "fileutils"

module Bparity
  module Corpus
    class Writer
      attr_reader :path

      def initialize(path)
        @path = path
        FileUtils.mkdir_p(File.dirname(path))
        @io = File.open(path, "a")
      end

      def write(record)
        @io.puts(JSON.generate(record))
        @io.flush
      end

      def close = @io.close
    end

    class Reader
      include Enumerable

      def initialize(path)
        @path = path
      end

      def each
        return enum_for(__method__) unless block_given?

        File.foreach(@path).with_index(1) do |line, number|
          yield JSON.parse(line)
        rescue JSON::ParserError => e
          raise Error, "Invalid JSONL at #{@path}:#{number}: #{e.message}. Record the corpus again."
        end
      end
    end
  end
end
