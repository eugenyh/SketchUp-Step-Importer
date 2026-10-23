# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
# Minimal localisation: flat JSON files in locales/<code>.json.
#
# To add a language: copy locales/en.json to locales/<code>.json, translate the values and
# set "_language_name" to the name shown in the Settings dialog. Keys missing from a
# translation fall back to English. Placeholders like %{name} must be kept as they are.

require 'json'

module EugenyH
  module StepImport
    module Lang
      DIR     = File.join(__dir__, 'locales').freeze
      DEFAULT = 'en'.freeze
      CODE_RE = /\A[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})?\z/.freeze

      @current = DEFAULT
      @cache   = {}

      class << self
        attr_reader :current

        def current=(code)
          @current = valid?(code) ? code.to_s : DEFAULT
        end

        # { 'en' => 'English', 'ru' => 'Русский' }, English first
        def available
          codes = Dir.glob(File.join(DIR, '*.json')).map { |p| File.basename(p, '.json') }
          codes = codes.select { |c| c =~ CODE_RE }
          codes = codes.sort_by { |c| [c == DEFAULT ? 0 : 1, c] }
          codes.each_with_object({}) { |c, h| h[c] = (strings(c)['_language_name'] || c).to_s }
        end

        def valid?(code)
          !!(code.to_s =~ CODE_RE && File.file?(file_for(code)))
        end

        # Translates key; vars (a Hash) fills %{name} placeholders.
        # Falls back to English, then to the key itself.
        def t(key, vars = nil)
          text = (strings(@current)[key] || strings(DEFAULT)[key] || key).to_s
          return text if vars.nil? || vars.empty?
          format(text, vars)
        rescue StandardError
          text || key.to_s
        end

        private

        def file_for(code)
          File.join(DIR, "#{code}.json")
        end

        def strings(code)
          @cache[code] ||= begin
            raw = File.read(file_for(code), encoding: 'UTF-8').sub(/\A\uFEFF/, '')
            JSON.parse(raw)
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
