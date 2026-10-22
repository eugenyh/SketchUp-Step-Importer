# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
# Замер скорости построения геометрии из STL платы.
# Использование (Ruby Console):
#   load 'C:/путь/step_bench.rb'
#   EugenyH::StepBench.run('C:/путь/к/def_0004.stl')
# Результаты пишутся в %TEMP%\step_bench.log (читайте его в Блокноте во время работы).
# Модель не изменяется: каждый тест откатывается через abort_operation.

require 'sketchup.rb'
require 'tmpdir'

module EugenyH
  module StepBench
    OUT = File.join(Dir.tmpdir, 'step_bench.log')

    def self.log(m)
      File.open(OUT, 'a:UTF-8') { |f| f.puts("[#{Time.now.strftime('%H:%M:%S')}] #{m}") }
      puts m
    end

    # n треугольников бинарного STL, начиная с номера skip
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

    # Выполняет блок в откатываемой операции, возвращает секунды
    def self.timed_op(label)
      model = Sketchup.active_model
      model.start_operation('bench', true)
      g = model.active_entities.add_group
      t = Time.now
      yield g.entities
      dt = Time.now - t
      log format('%-48s %7.2f c', label, dt)
      dt
    ensure
      model.abort_operation
    end

    def self.run(stl_path)
      File.write(OUT, '')
      log "Файл: #{stl_path}, #{File.size(stl_path)} байт"

      last = 0
      [5_000, 10_000, 20_000, 40_000].each do |n|
        if last > 30
          log "Остановка: предыдущий тест занял #{last.round} c"
          break
        end
        mesh = mesh_from(stl_path, 0, n)
        log "--- #{n} треугольников, в меше #{mesh.polygons.size}, точек #{mesh.count_points}"
        last = timed_op("add_faces_from_mesh, #{n}") { |e| e.add_faces_from_mesh(mesh, 0) }
        timed_op("fill_from_mesh(weld=true), #{n}")  { |e| e.fill_from_mesh(mesh, true, 0) }
      end

      # те же 20 000 треугольников, но порциями по 1000
      if last <= 30
        chunks = (0...20).map { |k| mesh_from(stl_path, k * 1000, 1000) }
        timed_op('add_faces_from_mesh, 20 порций по 1000') do |e|
          chunks.each { |m| e.add_faces_from_mesh(m, 0) }
        end
      end

      log 'Готово'
    end
  end
end
