# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH

require 'sketchup.rb'
require 'extensions.rb'

module EugenyH
  module StepImportLoader
    unless file_loaded?(__FILE__)
      # main.rb uses Ruby 2.7 syntax (SketchUp 2021+)
      if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.7')
        UI.messagebox('STEP Import (FreeCAD) requires SketchUp 2021 or newer.')
      else
        ex = SketchupExtension.new('STEP Import (FreeCAD)', 'eugenyh_step_import/main')
        ex.version     = '1.0.1'
        ex.creator     = 'EugenyH'
        ex.copyright   = '2026 EugenyH'
        ex.description = 'Imports STEP assemblies via FreeCAD: parts become groups, ' \
                         'repeated parts become components, the result is saved as .skp.'
        Sketchup.register_extension(ex, true)
      end
      file_loaded(__FILE__)
    end
  end
end
