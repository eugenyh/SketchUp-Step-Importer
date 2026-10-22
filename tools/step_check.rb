# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
# Диагностика: куда деваются грани портов при построении платы.
# Использование (Ruby Console):
#   load 'C:/путь/step_check.rb'
#   EugenyH::StepCheck.run('C:/путь/к/def_0004.stl')
# Результат: %TEMP%\step_check.log (читайте в Блокноте). Модель не меняется (abort_operation).

require 'sketchup.rb'
require 'tmpdir'

module EugenyH
  module StepCheck
    OUT = File.join(Dir.tmpdir, 'step_check.log')
    Z_LIMIT = -2.0          # мм: ниже этого уровня лежат порты (за краем платы)
    EXPECTED_LOW = 2689     # ожидаемое число граней ниже Z_LIMIT (расчёт по STL)

    def self.log(m)
      File.open(OUT, 'a:UTF-8') { |f| f.puts("[#{Time.now.strftime('%H:%M:%S')}] #{m}") }
      puts m
    end

    # n треугольников бинарного STL начиная с номера skip
    def self.mesh_from(path, skip, n)
      mesh = Geom::PolygonMesh.new
      pts  = {}
      File.open(path, 'rb') do |f|
        f.seek(84 + 50 * skip)
        buf = f.read(50 * n)
        cnt = buf.bytesize / 50
        v   = buf.unpack('x12e9x2' * cnt)
        cnt.times do |k|
          o = k * 9
          ids = [0, 3, 6].map do |d|
            x = v[o + d]; y = v[o + d + 1]; z = v[o + d + 2]
            pts[[x, y, z]] ||= mesh.add_point(Geom::Point3d.new(x.mm, y.mm, z.mm))
          end
          next if ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2]
          mesh.add_polygon(ids)
        end
      end
      mesh
    end

    def self.low_faces(entities)
      lim = Z_LIMIT.mm
      entities.grep(Sketchup::Face).count { |fc| fc.bounds.center.z < lim }
    end

    def self.build(path, chunk, label)
      model = Sketchup.active_model
      total = (File.size(path) - 84) / 50
      chunk = total if chunk <= 0
      model.start_operation('check', true)
      begin
        g = model.active_entities.add_group
        skip = 0
        k = 0
        while skip < total
          n    = [chunk, total - skip].min
          mesh = mesh_from(path, skip, n)
          before = g.entities.grep(Sketchup::Face).size
          g.entities.fill_from_mesh(mesh, true, 0)
          after  = g.entities.grep(Sketchup::Face).size
          log format('  %s порция %d: треугольники %d..%d, полигонов в меше %d, граней добавлено %d',
                     label, k, skip, skip + n - 1, mesh.polygons.size, after - before)
          skip += n
          k += 1
        end
        faces = g.entities.grep(Sketchup::Face).size
        low   = low_faces(g.entities)
        log format('%s: всего граней %d, граней ниже z=%.1f мм: %d (в STL ожидается ~%d)',
                   label, faces, Z_LIMIT, low, EXPECTED_LOW)
      ensure
        model.abort_operation
      end
    end

    def self.run(stl_path)
      File.write(OUT, '')
      log "Файл: #{stl_path}"
      build(stl_path, 30_000, 'порции по 30000')
      build(stl_path, 0,      'весь STL одним мешем')
      log 'Готово'
    end
  end
end
