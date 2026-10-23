# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
# Persistent settings stored in a small JSON file:
#   %APPDATA%\EugenyH\StepImport\settings.json
# Keys: "language" (locale code), "freecadcmd" (full path to FreeCADCmd.exe).
# The file is read on every access, so it can also be edited by hand.

require 'json'
require 'fileutils'

module EugenyH
  module StepImport
    module Settings
      module_function

      def path
        appdata = ENV['APPDATA'].to_s
        base = appdata.empty? ? Dir.home : appdata
        File.join(base, 'EugenyH', 'StepImport', 'settings.json')
      end

      def read
        data = JSON.parse(File.read(path, encoding: 'UTF-8').sub(/\A\uFEFF/, ''))
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end

      def get(key, default = nil)
        value = read[key]
        value.nil? || value == '' ? default : value
      end

      # changes: { 'key' => value }; a nil value removes the key. Returns true on success.
      def update(changes)
        data = read
        changes.each do |k, v|
          if v.nil?
            data.delete(k)
          else
            data[k] = v
          end
        end
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        File.write(tmp, JSON.pretty_generate(data), encoding: 'UTF-8')
        File.rename(tmp, path)
        true
      rescue StandardError
        false
      end
    end
  end
end
