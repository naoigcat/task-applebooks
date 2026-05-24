# frozen_string_literal: true

require "json"

module Books
  class Formatter
    VALID_FORMATS = %w[text json].freeze

    def initialize(format:)
      raise ArgumentError, "Invalid format: #{format}. Supported formats: #{VALID_FORMATS.join(', ')}" unless VALID_FORMATS.include?(format)

      @format = format
    end

    def format(collections)
      case @format
      when "text"
        render_text(collections)
      when "json"
        JSON.pretty_generate(collections)
      else
        raise ArgumentError, "Unsupported format: #{@format}"
      end
    end

    private

    def render_text(collections)
      collections.map do |collection|
        lines = ["#{collection[:title]} (#{collection[:books].length} books)"]
        collection[:books].each.with_index(1) do |book, index|
          details = [
            book[:author],
            book[:identifier] && "ID: #{book[:identifier]}"
          ].compact.join(" / ")

          lines << "#{index}. #{book[:title]}"
          lines << "   #{details}" unless details.empty?
        end
        lines.join("\n")
      end.join("\n\n")
    end
  end
end
