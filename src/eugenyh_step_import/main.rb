# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
# STEP assembly import for SketchUp via FreeCAD (Windows).
# STEP -> (FreeCADCmd + step2stl_fc.py) -> def_XXXX.stl + manifest.json -> groups/components -> .skp
#
# step2stl_fc.py must sit next to this file.
# Progress is logged to %TEMP%\step_import.log (and to the Ruby Console).
# Импорт сборки STEP через FreeCAD; журнал работы: %TEMP%\step_import.log

require 'sketchup.rb'
require 'tmpdir'
require 'fileutils'
require 'json'

module EugenyH
  module StepImport
    PREF   = 'EugenyH_StepImport'
    SCRIPT = File.join(__dir__, 'step2stl_fc.py')

    # Файл настроек: %APPDATA%\EugenyH\StepImport\config.json
    # Лежит вне папки расширения, поэтому переживает обновление и переустановку.
    CONFIG_DIR  = File.join(ENV['APPDATA'] || Dir.home, 'EugenyH', 'StepImport')
    CONFIG_FILE = File.join(CONFIG_DIR, 'config.json')

    # Параметры конвертации (мм)
    TOL        = '0.1'   # допуск триангуляции обычных деталей
    TOL_MERGED = '0.5'   # допуск для склеенных контейнеров (плата)
    MERGE_MIN  = '50'    # контейнер с таким числом деталей и больше склеивается в один STL

    SAVE_SKP   = true    # сохранять итоговую модель в .skp рядом с исходным STEP

    BIG_TRIS   = 300_000 # больше этого числа треугольников в одном STL - предупреждаем
    SOFTEN_MAX = 20_000  # сглаживание рёбер только для мешей не больше этого размера
    SOFTEN_ANGLE = 10    # рёбра между гранями с углом меньше этого (градусы) скрываются и сглаживаются
    CHUNK      = 20_000  # треугольников за один разбор бинарного STL

    FREECAD_TIMEOUT = 900 # секунд; после этого FreeCAD принудительно завершается
    HIDE_FREECAD    = true # скрывать окно FreeCADCmd (если wscript недоступен - обычный запуск)

    HEAVY_TRIS     = 40_000 # меши крупнее строятся с предварительным сообщением в окне
    TRIS_PER_SEC   = 5_000  # грубая оценка скорости чтения STL, для подсказки времени
    FC_SHARE       = 0.80   # доля общей полосы, отведённая работе FreeCAD
    BUILD_FROM     = 80.0   # проценты общей полосы: построение модели
    BUILD_TO       = 97.0
    LOG_FILE   = File.join(Dir.tmpdir, 'step_import.log')  # журнал, можно открывать во время работы

    # Пишет в файл (сразу, с закрытием) и в Ruby Console.
    # Консоль SketchUp не обновляется, пока главный поток занят, а файл можно читать снаружи.
    def self.log(msg)
      line = "[STEP #{Time.now.strftime('%H:%M:%S')}] #{msg}"
      File.open(LOG_FILE, 'a:UTF-8') { |f| f.puts(line) }
      puts line
    rescue
      nil
    end

    # ---------- Настройки (config.json) ----------

    def self.load_config
      data = JSON.parse(File.read(CONFIG_FILE, encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    # Возвращает true, если файл записан.
    def self.save_config(cfg)
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(CONFIG_FILE, JSON.pretty_generate(cfg), encoding: 'UTF-8')
      true
    rescue StandardError => e
      log "Не удалось записать #{CONFIG_FILE}: #{e.class}: #{e.message}"
      false
    end

    # ---------- FreeCAD ----------

    # Сохранённый путь: сначала config.json, затем реестр (настройки версии 1.0.0).
    # Возвращает путь, только если файл по нему существует.
    def self.saved_freecad_path
      cfg = load_config
      reg = Sketchup.read_default(PREF, 'freecadcmd')
      [cfg['freecadcmd'], reg].each do |p|
        next if p.nil? || p.to_s.empty?
        p = p.to_s.dup.force_encoding('UTF-8').tr('\\', '/')
        if File.exist?(p)
          # Путь нашёлся только в реестре - переносим в config.json
          store_freecad_path(p) if cfg['freecadcmd'].to_s.empty?
          return p
        end
        log "Сохранённый путь к FreeCADCmd недоступен: #{p}"
      end
      nil
    end

    def self.store_freecad_path(path)
      cfg = load_config
      cfg['freecadcmd'] = path
      ok = save_config(cfg)
      Sketchup.write_default(PREF, 'freecadcmd', path)   # запасной вариант
      log "Путь к FreeCADCmd сохранён (#{ok ? CONFIG_FILE : 'только реестр'}): #{path}"
    end

    # force = true: не использовать сохранённый путь и автопоиск, всегда спросить.
    def self.freecad_exe(force = false)
      unless force
        saved = saved_freecad_path
        return saved if saved
        found = Dir.glob('C:/Program Files/FreeCAD*/bin/FreeCADCmd.exe').max
      end

      unless found
        start = File.dirname(saved_freecad_path || 'C:/Program Files/x')
        start = 'C:/Program Files' unless File.directory?(start)
        found = UI.openpanel('Укажите FreeCADCmd.exe', start,
                             'FreeCADCmd.exe|FreeCADCmd.exe||')
      end

      if found
        found = found.to_s.tr('\\', '/')
        store_freecad_path(found)
      end
      found
    end

    # Пункт меню: сменить путь к FreeCADCmd вручную.
    def self.choose_freecad
      exe = freecad_exe(true)
      UI.messagebox("Путь к FreeCADCmd сохранён:\n#{exe}") if exe
    end

    # ---------- Окно прогресса ----------

    class ProgressDialog
      HTML = <<~'HTML'
        <!DOCTYPE html>
        <html lang="ru"><head><meta charset="utf-8">
        <style>
          :root{--bg:#f3f3f3;--fg:#202020;--muted:#6b6b6b;--track:#d9d9d9;--accent:#1a73e8;--ok:#1e9e55;--card:#fff;--border:#d0d0d0}
          @media (prefers-color-scheme: dark){:root{--bg:#2b2b2b;--fg:#ececec;--muted:#a8a8a8;--track:#454545;--card:#333;--border:#555;--accent:#5b9dff}}
          html,body{height:100%}
          body{margin:0;background:var(--bg);color:var(--fg);font:13px 'Segoe UI',Arial,sans-serif;user-select:none;cursor:default}
          .wrap{padding:16px 18px;display:flex;flex-direction:column;height:100%;box-sizing:border-box}
          .file{font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
          .stage{font-size:16px;font-weight:600;margin:6px 0 10px}
          .bar{height:10px;background:var(--track);border-radius:5px;overflow:hidden;position:relative}
          .fill{height:100%;width:0;background:var(--accent);border-radius:5px;transition:width .25s}
          .bar.ind .fill{width:35%;position:absolute;animation:slide 1.2s ease-in-out infinite;transition:none}
          .bar.done .fill{background:var(--ok)}
          @keyframes slide{0%{left:-35%}100%{left:100%}}
          .row{display:flex;justify-content:space-between;color:var(--muted);margin:6px 0 8px;font-variant-numeric:tabular-nums}
          .detail{min-height:18px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
          .log{flex:1;margin:10px 0;padding:8px 10px;list-style:none;background:var(--card);border:1px solid var(--border);border-radius:4px;overflow:hidden;font-size:12px;color:var(--muted)}
          .log li{padding:1px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
          .log li:last-child{color:var(--fg)}
          .buttons{text-align:right;min-height:30px}
          button{font:13px 'Segoe UI',Arial,sans-serif;padding:5px 22px;border:1px solid var(--border);border-radius:4px;background:var(--card);color:var(--fg);cursor:pointer}
          button:hover{border-color:var(--accent)}
        </style></head>
        <body><div class="wrap">
          <div class="file" id="file"></div>
          <div class="stage" id="stage">Подготовка…</div>
          <div class="bar ind" id="bar"><div class="fill" id="fill"></div></div>
          <div class="row"><span id="pct"></span><span id="elapsed">0:00</span></div>
          <div class="detail" id="detail"></div>
          <ul class="log" id="log"></ul>
          <div class="buttons"><button id="cancel" onclick="sketchup.cancel()">Отмена</button></div>
        </div>
        <script>
          var t0 = null, timer = null;
          function fmt(s){var m = Math.floor(s/60), r = s % 60; return m + ':' + (r < 10 ? '0' : '') + r;}
          function tick(){ if (t0 !== null) document.getElementById('elapsed').textContent = fmt(Math.floor((Date.now() - t0)/1000)); }
          function render(s){
            if (t0 === null) { t0 = Date.now(); timer = setInterval(tick, 500); }
            var done = s.mode === 'done';
            document.getElementById('file').textContent = s.file;
            document.getElementById('stage').textContent = s.stage;
            document.getElementById('detail').textContent = s.detail;
            document.getElementById('bar').className = 'bar' + (s.pct < 0 ? ' ind' : '') + (done ? ' done' : '');
            document.getElementById('fill').style.width = (s.pct < 0 ? 35 : Math.min(100, s.pct)) + '%';
            document.getElementById('pct').textContent = s.pct < 0 ? '' : Math.round(s.pct) + '%';
            var ul = document.getElementById('log'); ul.innerHTML = '';
            s.logs.forEach(function(t){ var li = document.createElement('li'); li.textContent = t; ul.appendChild(li); });
            if (done) { clearInterval(timer); tick(); document.getElementById('cancel').style.display = 'none'; }
          }
          window.onload = function(){ sketchup.ready(); };
        </script></body></html>
      HTML

      def initialize(title, file, &on_cancel)
        @on_cancel = on_cancel
        @ready   = false
        @closing = false
        @state = { 'pct' => -1, 'stage' => 'Подготовка', 'detail' => '',
                   'file' => file, 'logs' => [], 'mode' => 'run' }
        @dlg = UI::HtmlDialog.new(dialog_title: title, scrollable: false, resizable: false,
                                  width: 480, height: 400, style: UI::HtmlDialog::STYLE_DIALOG)
        @dlg.set_html(HTML)
        @dlg.add_action_callback('ready')  { |_c| @ready = true; push }
        @dlg.add_action_callback('cancel') { |_c| @on_cancel.call }
        @dlg.set_on_closed { @on_cancel.call unless @closing }
        @dlg.show
        @dlg.center if @dlg.respond_to?(:center)
      end

      # pct < 0 - неопределённый прогресс (бегущая полоса)
      def update(pct, stage, detail = '')
        @state['pct']    = pct
        @state['stage']  = stage
        @state['detail'] = detail
        push
      end

      def add_log(line)
        return if @state['logs'].last == line
        @state['logs'] << line
        @state['logs'].shift while @state['logs'].size > 8
        push
      end

      def finish(stage, detail = '')
        @state['mode'] = 'done'
        update(100, stage, detail)
      end

      def close
        @closing = true
        @dlg.close
      rescue StandardError
        nil
      end

      private

      def push
        return unless @ready
        @dlg.execute_script("render(#{JSON.generate(@state)})")
      rescue StandardError
        nil
      end
    end

    # ---------- Задание импорта ----------

    class Job
      def initialize(exe, step)
        @exe      = exe
        @step     = step
        @name     = File.basename(step, '.*')
        @t0       = Time.now
        @active   = true
        @op_open  = false
        @keep_tmp = false
        @fc_pid   = nil
        @mode     = nil      # :hidden (через wscript) или :direct
        @timer    = nil
        @tick     = nil
      end

      def active?
        @active
      end

      def start
        File.write(LOG_FILE, '')
        @tmp = Dir.mktmpdir('step2stl')               # ASCII-путь, без кириллицы
        StepImport.log "Старт: #{@step}"
        StepImport.log "FreeCADCmd: #{@exe}"
        StepImport.log "Временная папка: #{@tmp}"

        @dlg = ProgressDialog.new('Импорт STEP', @name) { cancel }
        @dlg.update(-1, 'Подготовка', 'Копирование файлов')
        FileUtils.cp(@step, File.join(@tmp, 'in.step'))
        FileUtils.cp(SCRIPT, File.join(@tmp, 'conv.py'))

        launch_freecad
        @t_fc = Time.now
        @dlg.add_log('FreeCAD запущен')
        @dlg.update(-1, 'Чтение STEP', 'FreeCAD загружает файл (для больших сборок это может занять минуту)')
        @timer = UI.start_timer(0.3, true) { guarded { poll_freecad } }
      rescue => e
        fail!("Не удалось запустить импорт: #{e.message}", e)
      end

      # Отмена (кнопка или закрытие окна)
      def cancel
        return unless @active
        @active = false
        StepImport.log 'Отменено пользователем'
        stop_timers
        kill_freecad
        abort_op
        @dlg.close if @dlg
        cleanup_tmp
        Sketchup.status_text = 'Импорт STEP отменён'
      end

      private

      def guarded
        yield
      rescue => e
        fail!("Ошибка: #{e.class}: #{e.message}", e)
      end

      # ----- FreeCAD -----

      def launch_freecad
        @env = { 'STEP_IN'         => File.join(@tmp, 'in.step'),
                 'OUT_DIR'         => @tmp,
                 'STEP_TOL'        => TOL,
                 'STEP_TOL_MERGED' => TOL_MERGED,
                 'MERGE_MIN'       => MERGE_MIN }
        @py = File.join(@tmp, 'conv.py')

        wscript = File.join(ENV['SystemRoot'] || 'C:/Windows', 'System32', 'wscript.exe')
        if HIDE_FREECAD && File.exist?(wscript)
          # Окно консоли FreeCADCmd создаётся скрытым: WScript.Shell.Run со стилем 0.
          cmd  = %("#{@exe.tr('/', '\\')}" "#{@py.tr('/', '\\')}")
          body = %(CreateObject("WScript.Shell").Run "#{cmd.gsub('"', '""')}", 0, False\r\n)
          vbs  = File.join(@tmp, 'run.vbs')
          File.binwrite(vbs, "\uFEFF".encode('UTF-16LE') + body.encode('UTF-16LE'))
          pid = Process.spawn(@env, wscript, '//B', '//Nologo', vbs.tr('/', '\\'))
          Process.detach(pid)
          @mode = :hidden
          StepImport.log 'FreeCAD запущен скрыто (wscript)'
        else
          launch_direct
        end
      end

      def launch_direct
        @fc_pid = Process.spawn(@env, @exe, @py,
                                [:out, :err] => File.join(@tmp, 'freecad_console.log'),
                                :in => File::NULL)
        @mode = :direct
        StepImport.log "FreeCAD запущен обычным способом, pid #{@fc_pid}"
      end

      def read_pid
        p = File.join(@tmp, 'pid.txt')
        return nil unless File.exist?(p)
        v = File.read(p).to_i
        v > 0 ? v : nil
      rescue StandardError
        nil
      end

      def fc_alive?
        return true unless @fc_pid
        if @mode == :direct
          Process.wait2(@fc_pid, Process::WNOHANG).nil?
        else
          Process.kill(0, @fc_pid)
          true
        end
      rescue Errno::ECHILD, Errno::ESRCH
        false
      rescue StandardError
        true                       # не уверены - считаем живым, спасёт таймаут
      end

      def kill_freecad
        pid = @fc_pid || read_pid
        return unless pid
        return unless fc_alive?
        Process.kill('KILL', pid)
        StepImport.log "Процесс FreeCAD #{pid} завершён принудительно"
      rescue StandardError => e
        StepImport.log "Не удалось завершить FreeCAD #{pid}: #{e.class}"
      end

      def read_json(name)
        JSON.parse(File.read(File.join(@tmp, name), encoding: 'UTF-8'))
      rescue StandardError
        nil
      end

      def read_text(name)
        File.binread(File.join(@tmp, name)).force_encoding('UTF-8').scrub
      rescue StandardError
        ''
      end

      def poll_freecad
        return unless @active
        elapsed = Time.now - @t_fc
        @fc_pid ||= read_pid

        if File.exist?(File.join(@tmp, 'error.txt'))
          txt = read_text('error.txt')
          return fail!("FreeCAD сообщил об ошибке:\n#{txt[-900..] || txt}")
        end

        if (prog = read_json('progress.json'))
          f = prog['fraction']
          pct = f.nil? ? -1 : (f.to_f * FC_SHARE * 100).round(1)
          stage = prog['stage'].to_s
          @dlg.update(pct, stage, prog['detail'].to_s)
          if stage != @last_stage
            @last_stage = stage
            @dlg.add_log(stage)
          end
        end

        if File.exist?(File.join(@tmp, 'done.flag'))
          stop_timers
          StepImport.log format('FreeCAD готов за %.1f c', elapsed)
          kill_freecad                       # на случай, если процесс не вышел сам
          return begin_build
        end

        if @mode == :hidden && @fc_pid.nil? && elapsed > 20
          StepImport.log 'Скрытый запуск не сработал, запускаю обычным способом'
          @dlg.add_log('Скрытый запуск недоступен, обычный запуск')
          launch_direct
          @t_fc = Time.now
          return
        end

        if @fc_pid && !fc_alive?
          return if File.exist?(File.join(@tmp, 'done.flag'))   # успел дописать - обработаем на следующем тике
          return fail!("FreeCAD завершился без результата.\n#{read_text('freecad.log')[-600..]}")
        end

        if elapsed > FREECAD_TIMEOUT
          fail!("FreeCAD работает дольше #{FREECAD_TIMEOUT / 60} минут, остановлен.")
        else
          Sketchup.status_text = format('STEP: работает FreeCAD, %d c...', elapsed)
        end
      end

      # ----- Построение модели (шагами, по таймеру) -----

      def begin_build
        data = JSON.parse(File.read(File.join(@tmp, 'manifest.json'), encoding: 'UTF-8'))
        @defs  = data['definitions']
        @insts = data['instances']
        StepImport.log "Манифест: определений #{@defs.size}, вхождений #{@insts.size}"
        return fail!('В STEP не найдено деталей') if @insts.empty?

        big = []
        @defs.each do |d|
          size = File.size(File.join(@tmp, d['file']))
          d['tris_est'] = [(size - 84) / 50, 0].max
          StepImport.log format('%s  %s: %.1f МБ, ~%d треугольников', d['file'], d['name'], size / 1048576.0, d['tris_est'])
          big << d if d['tris_est'] > BIG_TRIS
        end
        unless big.empty?
          txt = big.map { |d| "#{d['name']}: ~#{d['tris_est']} треугольников" }.join("\n")
          answer = UI.messagebox("Крупные меши:\n#{txt}\n\nИмпорт может занять несколько минут. Продолжить?", MB_YESNO)
          return cancel unless answer == IDYES
        end

        @model = Sketchup.active_model
        @guid  = @model.guid
        @model.start_operation('Import STEP assembly', true)
        @op_open = true
        @root = @model.active_entities.add_group
        @root.name = @name
        @cache = {}          # путь контейнеров -> группа
        @comps = {}          # индекс определения -> ComponentDefinition
        @idx = 0
        @announced = {}
        @t_build = Time.now
        @dlg.add_log('Построение модели в SketchUp')
        schedule(0.05)
      end

      def schedule(delay)
        @tick = UI.start_timer(delay, false) { guarded { build_tick } }
      end

      def build_tick
        return unless @active
        return fail!('Активная модель была изменена во время импорта') unless Sketchup.active_model.guid == @guid

        budget = Time.now + 0.15
        while @idx < @insts.size
          i = @insts[@idx]
          d = @defs[i['def']]
          needs_build = d['count'] > 1 ? !@comps.key?(i['def']) : true

          # Тяжёлая деталь: сначала показываем сообщение, даём окну перерисоваться, потом строим.
          if needs_build && d['tris_est'] > HEAVY_TRIS && !@announced[@idx]
            @announced[@idx] = true
            secs = [(d['tris_est'] / TRIS_PER_SEC.to_f).round, 1].max
            @dlg.update(build_pct, "Построение: #{i['name']}",
                        "≈#{d['tris_est']} треугольников, около #{secs} с (окно на это время может не обновляться)")
            @dlg.add_log("#{i['name']} (~#{secs} с)")
            return schedule(0.15)
          end

          place_instance(i, d)
          @idx += 1
          @dlg.update(build_pct, 'Построение модели', "#{@idx} из #{@insts.size}: #{i['name']}")
          break if Time.now > budget
        end

        @idx >= @insts.size ? finish_build : schedule(0.01)
      end

      def build_pct
        BUILD_FROM + (BUILD_TO - BUILD_FROM) * (@idx.to_f / @insts.size)
      end

      def place_instance(i, d)
        parent = StepImport.ensure_path(@root, @cache, i['path'])
        t = StepImport.to_transformation(i['matrix'])

        if d['count'] > 1
          cd = (@comps[i['def']] ||= StepImport.make_definition(@tmp, d))
          return unless cd
          obj = parent.entities.add_instance(cd, t)
        else
          obj = parent.entities.add_group
          unless StepImport.fill_entities(obj.entities, @tmp, d)
            obj.erase!
            return
          end
          obj.transformation = t
        end
        obj.name = i['name']
      end

      def finish_build
        @model.commit_operation
        @op_open = false
        StepImport.log format('Построение модели: %.1f c', Time.now - @t_build)
        Sketchup.status_text = "STEP: вхождений #{@insts.size}, уникальных форм #{@defs.size}"

        skp = nil
        if SAVE_SKP
          @dlg.update(BUILD_TO, 'Сохранение .skp', "#{@name}.skp")
          skp = StepImport.save_skp(@step)
        end

        total = Time.now - @t0
        StepImport.log format('Готово, всего %.1f c', total)
        @dlg.add_log(format('Готово за %.0f с', total))
        @dlg.finish('Импорт завершён',
                    skp ? "Сохранено: #{skp}" : "Вхождений: #{@insts.size}, уникальных форм: #{@defs.size}")
        @active = false
        cleanup_tmp
        UI.start_timer(2.5, false) { @dlg.close }
      end

      # ----- Завершение -----

      def abort_op
        return unless @op_open
        @model.abort_operation
        @op_open = false
      rescue StandardError
        nil
      end

      def stop_timers
        UI.stop_timer(@timer) if @timer
        UI.stop_timer(@tick) if @tick
        @timer = @tick = nil
      end

      def cleanup_tmp
        FileUtils.remove_entry(@tmp) if @tmp && !@keep_tmp && File.exist?(@tmp)
      rescue StandardError
        nil
      end

      def fail!(msg, err = nil)
        return unless @active
        @active = false
        stop_timers
        kill_freecad
        abort_op
        StepImport.log "ОШИБКА: #{msg}"
        StepImport.log err.backtrace.first(8).join("\n") if err
        StepImport.log "Папка сохранена для разбора: #{@tmp}"
        @keep_tmp = true
        @dlg.close if @dlg
        UI.messagebox("#{msg}\n\nЖурнал: #{LOG_FILE}")
      end
    end

    # ---------- Запуск ----------

    def self.run
      if @job && @job.active?
        return UI.messagebox('Импорт STEP уже выполняется')
      end

      exe = freecad_exe
      return UI.messagebox('FreeCADCmd.exe не найден') unless exe
      return UI.messagebox("Не найден #{SCRIPT}") unless File.exist?(SCRIPT)

      step = UI.openpanel('Выберите STEP', '', 'STEP|*.step;*.stp||')
      return unless step

      @job = Job.new(exe, step)
      @job.start
    end

    # ---------- Построение геометрии ----------

    # Читает STL и строит грани в entities (передавать ПУСТУЮ коллекцию). Возвращает false, если мешей нет.
    # fill_from_mesh на порядки быстрее add_faces_from_mesh на больших мешах
    # (замер на плате: 35 тыс. треугольников - 0.27 c против 29 c).
    def self.fill_entities(entities, dir, d)
      t0 = Time.now
      t_fill = 0.0
      total = 0
      each_stl_mesh(File.join(dir, d['file'])) do |mesh, tris|
        t = Time.now
        entities.fill_from_mesh(mesh, true, 0)
        t_fill += Time.now - t
        total += tris
      end
      return false if total.zero?

      log format('  %s: %d треугольников, чтение %.1f c, грани %.1f c',
                 d['file'], total, (Time.now - t0) - t_fill, t_fill)

      if total <= SOFTEN_MAX
        soften(entities)
      else
        log "  сглаживание пропущено (треугольников больше #{SOFTEN_MAX})"
      end
      true
    end

    # Цепочка вложенных групп по пути контейнеров (все с единичной матрицей).
    # Матрицы деталей глобальные, поэтому контейнеры трансформаций не несут.
    def self.ensure_path(root, cache, path)
      parent = root
      key = []
      path.each do |label|
        key += [label]
        cache[key] ||= begin
          g = parent.entities.add_group
          g.name = label
          g
        end
        parent = cache[key]
      end
      parent
    end

    def self.make_definition(dir, d)
      cd = Sketchup.active_model.definitions.add(d['name'])
      unless fill_entities(cd.entities, dir, d)
        Sketchup.active_model.definitions.remove(cd)
        return nil
      end
      cd
    end

    # FreeCAD: 16 чисел построчно, перенос в r[3], r[7], r[11] (мм)
    # SketchUp: 16 чисел по столбцам, перенос в дюймах
    def self.to_transformation(r)
      Geom::Transformation.new([
        r[0], r[4], r[8],  r[12],
        r[1], r[5], r[9],  r[13],
        r[2], r[6], r[10], r[14],
        r[3].mm, r[7].mm, r[11].mm, r[15]
      ])
    end

    # ---------- Сохранение .skp ----------

    def self.save_skp(step_path)
      skp = File.join(File.dirname(step_path), "#{File.basename(step_path, '.*')}.skp")
      if File.exist?(skp)
        answer = UI.messagebox("Файл #{File.basename(skp)} уже существует. Перезаписать?", MB_YESNO)
        return unless answer == IDYES
      end
      model = Sketchup.active_model
      if model.path.to_s.empty?
        # Новая (ещё не сохранённая) модель: save_copy для неё недоступен,
        # поэтому сохраняем саму модель под этим именем.
        model.save(skp)
      else
        # Модель уже открыта из файла: пишем копию, текущий документ не трогаем.
        model.save_copy(skp)
      end
      Sketchup.status_text = "Сохранено: #{skp}"
      log "Сохранено: #{skp}"
      skp
    rescue => e
      UI.messagebox("Не удалось сохранить .skp: #{e.message}")
      nil
    end

    # ---------- STL ----------

    # Отдаёт блоку [PolygonMesh, число_треугольников]. Весь STL идёт ОДНИМ мешем:
    # fill_from_mesh работает только с пустой коллекцией, повторные вызовы в ту же
    # группу ничего не добавляют (проверено на плате: из 6 порций построилась только первая).
    def self.each_stl_mesh(path)
      size = File.size(path)

      File.open(path, 'rb') do |f|
        count = f.read(84)[80, 4].unpack1('V')

        if size == 84 + 50 * count    # бинарный STL
          fmt_full = 'x12e9x2' * CHUNK
          limit = count        # ВАЖНО: один STL = один PolygonMesh (см. комментарий выше)
          left = count
          while left > 0
            n    = left < limit ? left : limit
            mesh = Geom::PolygonMesh.new
            pts  = {}                 # (x, y, z) STL -> индекс точки в mesh
            tris = 0
            todo = n
            while todo > 0
              m   = todo < CHUNK ? todo : CHUNK
              buf = f.read(50 * m)
              v   = buf.unpack(m == CHUNK ? fmt_full : 'x12e9x2' * m)
              m.times { |k| tris += 1 if add_tri(mesh, pts, v, k * 9) }
              todo -= m
            end
            left -= n
            yield mesh, tris if tris > 0
          end
        else                          # ASCII STL, одним мешем
          f.rewind
          mesh = Geom::PolygonMesh.new
          pts  = {}
          tris = 0
          buf  = []
          f.each_line do |line|
            next unless line =~ /^\s*vertex\s+(\S+)\s+(\S+)\s+(\S+)/
            buf << $1.to_f << $2.to_f << $3.to_f
            if buf.size == 9
              tris += 1 if add_tri(mesh, pts, buf, 0)
              buf = []
            end
          end
          yield mesh, tris if tris > 0
        end
      end
    end

    def self.add_tri(mesh, pts, v, o)
      ids = [0, 3, 6].map do |d|
        x = v[o + d]; y = v[o + d + 1]; z = v[o + d + 2]
        pts[[x, y, z]] ||= mesh.add_point(Geom::Point3d.new(x.mm, y.mm, z.mm))
      end
      return false if ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2]
      mesh.add_polygon(ids)
      true
    end

    def self.soften(entities)
      entities.grep(Sketchup::Edge).each do |e|
        next unless e.faces.size == 2
        if e.faces[0].normal.angle_between(e.faces[1].normal) < SOFTEN_ANGLE.degrees
          e.soft = true
          e.smooth = true
        end
      end
    end

    unless file_loaded?(__FILE__)
      UI.menu('Plugins').add_item('Import STEP assembly (FreeCAD)') { run }
      UI.menu('Plugins').add_item('Указать путь к FreeCADCmd…') { choose_freecad }
      file_loaded(__FILE__)
    end
  end
end
