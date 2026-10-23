# encoding: UTF-8
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
# STEP assembly import for SketchUp via FreeCAD (Windows).
# STEP -> (FreeCADCmd + step2stl_fc.py) -> def_XXXX.stl + manifest.json -> groups/components -> .skp
#
# step2stl_fc.py must sit next to this file.
# User-facing text lives in locales/<code>.json (see i18n.rb); the language and the
# FreeCADCmd path are chosen in Extensions -> STEP Import (FreeCAD) -> Settings.
# The work log is always written in English to %TEMP%\step_import.log (and to the Ruby Console).

require 'sketchup.rb'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'cgi'
require_relative 'i18n'
require_relative 'settings'

module EugenyH
  module StepImport
    SCRIPT = File.join(__dir__, 'step2stl_fc.py')

    # Legacy registry location of the FreeCADCmd path (read once to migrate to settings.json)
    LEGACY_PREF = 'EugenyH_StepImport'

    # Conversion parameters (mm)
    TOL        = '0.1'   # tessellation tolerance for regular parts
    TOL_MERGED = '0.5'   # tolerance for merged containers (e.g. a PCB)
    MERGE_MIN  = '50'    # a container with this many parts or more is merged into one STL

    SAVE_SKP   = true    # save the resulting model as .skp next to the source STEP

    BIG_TRIS   = 300_000 # warn when a single STL has more triangles than this
    SOFTEN_MAX = 20_000  # soften edges only for meshes up to this size
    SOFTEN_ANGLE = 10    # edges between faces closer than this angle (degrees) are hidden and smoothed
    CHUNK      = 20_000  # triangles per read of a binary STL

    FREECAD_TIMEOUT = 900  # seconds; FreeCAD is killed after this
    HIDE_FREECAD    = true # hide the FreeCADCmd console window (falls back to a normal launch without wscript)

    HEAVY_TRIS     = 40_000 # bigger meshes are announced in the dialog before building
    TRIS_PER_SEC   = 5_000  # rough STL build speed, used only for the time hint
    FC_SHARE       = 0.80   # share of the total progress bar given to FreeCAD
    BUILD_FROM     = 80.0   # percent of the total bar: model building
    BUILD_TO       = 97.0
    LOG_FILE   = File.join(Dir.tmpdir, 'step_import.log')  # can be opened while the import runs

    # Shared look of the HtmlDialogs (light/dark)
    BASE_CSS = <<~'CSS'
      :root{--bg:#f3f3f3;--fg:#202020;--muted:#6b6b6b;--track:#d9d9d9;--accent:#1a73e8;--ok:#1e9e55;--card:#fff;--border:#d0d0d0}
      @media (prefers-color-scheme: dark){:root{--bg:#2b2b2b;--fg:#ececec;--muted:#a8a8a8;--track:#454545;--card:#333;--border:#555;--accent:#5b9dff}}
      html,body{height:100%}
      body{margin:0;background:var(--bg);color:var(--fg);font:13px 'Segoe UI',Arial,sans-serif;user-select:none;cursor:default}
      button{font:13px 'Segoe UI',Arial,sans-serif;padding:5px 22px;border:1px solid var(--border);border-radius:4px;background:var(--card);color:var(--fg);cursor:pointer}
      button:hover{border-color:var(--accent)}
    CSS

    # Translation shortcut: StepImport.t(key, name: value) fills %{name} placeholders
    def self.t(key, vars = nil)
      Lang.t(key, vars)
    end

    module Translate
      private

      def t(key, vars = nil)
        StepImport.t(key, vars)
      end
    end

    # Replaces %%KEY%% placeholders in an HTML template (values must already be escaped).
    def self.fill_template(tpl, map)
      tpl.gsub(/%%(\w+)%%/) { map.fetch(Regexp.last_match(1), '').to_s }
    end

    def self.esc(text)
      CGI.escapeHTML(text.to_s)
    end

    # Writes to the file (opened and closed each time) and to the Ruby Console.
    # The console does not repaint while the main thread is busy; the file can be read from outside.
    def self.log(msg)
      line = "[STEP #{Time.now.strftime('%H:%M:%S')}] #{msg}"
      File.open(LOG_FILE, 'a:UTF-8') { |f| f.puts(line) }
      puts line
    rescue
      nil
    end

    # ---------- FreeCAD ----------

    # Path saved in settings (migrates the old registry value on first use)
    def self.saved_freecad
      path = Settings.get('freecadcmd')
      return path if path

      legacy = Sketchup.read_default(LEGACY_PREF, 'freecadcmd').to_s
      return nil if legacy.empty?
      Settings.update('freecadcmd' => legacy)
      legacy
    end

    # Looks for FreeCADCmd.exe in the usual install locations (Program Files on any drive, per-user installs)
    def self.detect_freecad
      roots = [ENV['ProgramFiles'], ENV['ProgramW6432']]
      roots << File.join(ENV['LOCALAPPDATA'], 'Programs') if ENV['LOCALAPPDATA']
      ('C'..'Z').each { |d| roots << "#{d}:/Program Files" }
      roots = roots.compact.map { |r| r.tr('\\', '/') }.uniq
      roots.flat_map { |r| Dir.glob(File.join(r, 'FreeCAD*', 'bin', 'FreeCADCmd.exe')) }.max
    end

    # File dialog for FreeCADCmd.exe; returns the path or nil
    def self.pick_freecad(current = nil)
      dir = current.to_s.empty? ? nil : File.dirname(current.to_s)
      dir = 'C:/Program Files' unless dir && File.directory?(dir)
      UI.openpanel(t('freecad.locate_title'), dir, 'FreeCADCmd.exe|FreeCADCmd.exe||')
    end

    # Saved path if it still exists, otherwise auto-detection, otherwise ask the user
    def self.freecad_exe
      saved = saved_freecad
      return saved if saved && File.exist?(saved)

      log "Saved FreeCADCmd path is missing: #{saved}" if saved
      found = detect_freecad || pick_freecad
      Settings.update('freecadcmd' => found) if found
      found
    end

    # ---------- Progress window ----------

    class ProgressDialog
      include Translate

      HTML = <<~'HTML'
        <!DOCTYPE html>
        <html lang="%%LANG%%"><head><meta charset="utf-8">
        <style>
          %%CSS%%
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
        </style></head>
        <body><div class="wrap">
          <div class="file" id="file"></div>
          <div class="stage" id="stage">%%PREPARING%%</div>
          <div class="bar ind" id="bar"><div class="fill" id="fill"></div></div>
          <div class="row"><span id="pct"></span><span id="elapsed">0:00</span></div>
          <div class="detail" id="detail"></div>
          <ul class="log" id="log"></ul>
          <div class="buttons"><button id="cancel" onclick="sketchup.cancel()">%%CANCEL%%</button></div>
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

      def initialize(file, &on_cancel)
        @on_cancel = on_cancel
        @ready   = false
        @closing = false
        @state = { 'pct' => -1, 'stage' => t('stage.preparing'), 'detail' => '',
                   'file' => file, 'logs' => [], 'mode' => 'run' }
        html = StepImport.fill_template(HTML,
                                        'CSS'       => BASE_CSS,
                                        'LANG'      => StepImport.esc(Lang.current),
                                        'CANCEL'    => StepImport.esc(t('dlg.cancel')),
                                        'PREPARING' => StepImport.esc(t('stage.preparing')))
        @dlg = UI::HtmlDialog.new(dialog_title: t('dlg.title'), scrollable: false, resizable: false,
                                  width: 480, height: 400, style: UI::HtmlDialog::STYLE_DIALOG)
        @dlg.set_html(html)
        @dlg.add_action_callback('ready')  { |_c| @ready = true; push }
        @dlg.add_action_callback('cancel') { |_c| @on_cancel.call }
        @dlg.set_on_closed { @on_cancel.call unless @closing }
        @dlg.show
        @dlg.center if @dlg.respond_to?(:center)
      end

      # pct < 0 - indeterminate progress (running bar)
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

    # ---------- Settings window ----------

    class SettingsDialog
      include Translate

      HTML = <<~'HTML'
        <!DOCTYPE html>
        <html lang="%%LANG%%"><head><meta charset="utf-8">
        <style>
          %%CSS%%
          .wrap{padding:6px 20px 16px;display:flex;flex-direction:column;height:100%;box-sizing:border-box}
          label{display:block;font-weight:600;margin:16px 0 6px}
          select,input[type=text]{font:13px 'Segoe UI',Arial,sans-serif;padding:5px 7px;border:1px solid var(--border);border-radius:4px;background:var(--card);color:var(--fg);box-sizing:border-box;user-select:text}
          select{min-width:200px}
          .path{display:flex;gap:6px}
          .path input{flex:1;min-width:0}
          .path button{padding:5px 12px;white-space:nowrap}
          .hint{color:var(--muted);font-size:12px;margin-top:6px;word-break:break-all}
          .buttons{margin-top:auto;text-align:right}
          .buttons button{margin-left:6px}
          button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
        </style></head>
        <body><div class="wrap">
          <label for="lang">%%LANGUAGE%%</label>
          <select id="lang"></select>

          <label for="path">%%FREECAD%%</label>
          <div class="path">
            <input type="text" id="path" placeholder="%%PLACEHOLDER%%" spellcheck="false">
            <button id="browse">%%BROWSE%%</button>
            <button id="detect">%%DETECT%%</button>
          </div>
          <div class="hint">%%HINT%%</div>
          <div class="hint">%%CONFIG%%</div>

          <div class="buttons">
            <button class="primary" id="save">%%SAVE%%</button><button id="cancel">%%CANCEL%%</button>
          </div>
        </div>
        <script>
          function $(id){ return document.getElementById(id); }
          function init(s){
            var sel = $('lang'); sel.innerHTML = '';
            s.languages.forEach(function(l){
              var o = document.createElement('option');
              o.value = l[0]; o.textContent = l[1];
              if (l[0] === s.lang) o.selected = true;
              sel.appendChild(o);
            });
            $('path').value = s.path || '';
          }
          function setPath(p){ $('path').value = p; }
          $('browse').onclick = function(){ sketchup.browse($('path').value); };
          $('detect').onclick = function(){ sketchup.detect(); };
          $('save').onclick   = function(){ sketchup.save(JSON.stringify({lang: $('lang').value, path: $('path').value})); };
          $('cancel').onclick = function(){ sketchup.cancel(); };
          window.onload = function(){ sketchup.ready(); };
        </script></body></html>
      HTML

      # Opens the dialog, or brings the already open one to the front
      def self.show_or_focus
        if @instance && @instance.alive?
          @instance.focus
        else
          @instance = new
        end
      end

      def initialize
        @closed = false
        html = StepImport.fill_template(HTML,
                                        'CSS'         => BASE_CSS,
                                        'LANG'        => StepImport.esc(Lang.current),
                                        'LANGUAGE'    => StepImport.esc(t('settings.language')),
                                        'FREECAD'     => StepImport.esc(t('settings.freecad')),
                                        'PLACEHOLDER' => StepImport.esc(t('settings.placeholder')),
                                        'HINT'        => StepImport.esc(t('settings.hint_path')),
                                        'CONFIG'      => StepImport.esc(t('settings.config_file', path: Settings.path)),
                                        'BROWSE'      => StepImport.esc(t('settings.browse')),
                                        'DETECT'      => StepImport.esc(t('settings.detect')),
                                        'SAVE'        => StepImport.esc(t('settings.save')),
                                        'CANCEL'      => StepImport.esc(t('dlg.cancel')))
        @dlg = UI::HtmlDialog.new(dialog_title: t('settings.title'), scrollable: false, resizable: false,
                                  width: 540, height: 330, style: UI::HtmlDialog::STYLE_DIALOG)
        @dlg.set_html(html)
        @dlg.add_action_callback('ready')  { |_c| guarded { push_state } }
        @dlg.add_action_callback('browse') { |_c, current| guarded { browse(current) } }
        @dlg.add_action_callback('detect') { |_c| guarded { detect } }
        @dlg.add_action_callback('save')   { |_c, json| guarded { save(json) } }
        @dlg.add_action_callback('cancel') { |_c| @dlg.close }
        @dlg.set_on_closed { @closed = true }
        @dlg.show
        @dlg.center if @dlg.respond_to?(:center)
      end

      def alive?
        !@closed
      end

      def focus
        @dlg.bring_to_front
      end

      private

      def guarded
        yield
      rescue StandardError => e
        StepImport.log "Settings dialog error: #{e.class}: #{e.message}"
      end

      def push_state
        state = { 'languages' => Lang.available.to_a,
                  'lang'      => Lang.current,
                  'path'      => StepImport.saved_freecad.to_s }
        @dlg.execute_script("init(#{JSON.generate(state)})")
      end

      def set_path(path)
        @dlg.execute_script("setPath(#{path.to_s.to_json})")
      end

      def browse(current)
        path = StepImport.pick_freecad(current)
        set_path(path) if path
      end

      def detect
        found = StepImport.detect_freecad
        if found
          set_path(found)
        else
          UI.messagebox(t('settings.detect_failed'))
        end
      end

      def save(json)
        data = JSON.parse(json)
        path = data['path'].to_s.strip.delete('"').tr('\\', '/')
        lang = data['lang'].to_s
        lang = Lang.current unless Lang.available.key?(lang)

        unless path.empty?
          return UI.messagebox(t('settings.path_missing', path: path)) unless File.file?(path)
          unless File.basename(path).downcase.start_with?('freecadcmd')
            return unless UI.messagebox(t('settings.path_name_warn'), MB_YESNO) == IDYES
          end
        end

        changed = lang != Lang.current
        ok = Settings.update('language' => lang, 'freecadcmd' => (path.empty? ? nil : path))
        return UI.messagebox(t('settings.save_failed', path: Settings.path)) unless ok

        # An emptied field means "auto-detect": also clear the legacy registry value so it is not migrated back
        Sketchup.write_default(LEGACY_PREF, 'freecadcmd', '') if path.empty?
        Lang.current = lang
        StepImport.log "Settings saved: language=#{lang}, freecadcmd=#{path.empty? ? '(auto)' : path}"
        @dlg.close
        UI.messagebox(t('settings.lang_changed')) if changed
      end
    end

    # ---------- Import job ----------

    class Job
      include Translate

      def initialize(exe, step)
        @exe      = exe
        @step     = step
        @name     = File.basename(step, '.*')
        @t0       = Time.now
        @active   = true
        @op_open  = false
        @keep_tmp = false
        @fc_pid   = nil
        @mode     = nil      # :hidden (via wscript) or :direct
        @timer    = nil
        @tick     = nil
      end

      def active?
        @active
      end

      def start
        File.write(LOG_FILE, '')
        @tmp = Dir.mktmpdir('step2stl')               # ASCII-only path
        StepImport.log "Start: #{@step}"
        StepImport.log "FreeCADCmd: #{@exe}"
        StepImport.log "Temp folder: #{@tmp}"

        @dlg = ProgressDialog.new(@name) { cancel }
        @dlg.update(-1, t('stage.preparing'), t('detail.copying'))
        FileUtils.cp(@step, File.join(@tmp, 'in.step'))
        FileUtils.cp(SCRIPT, File.join(@tmp, 'conv.py'))

        launch_freecad
        @t_fc = Time.now
        @dlg.add_log(t('log.fc_started'))
        @dlg.update(-1, t('stage.reading_step'), t('detail.reading_step'))
        @timer = UI.start_timer(0.3, true) { guarded { poll_freecad } }
      rescue => e
        fail!(t('err.start', msg: e.message), e)
      end

      # Cancel (button or closing the window)
      def cancel
        return unless @active
        @active = false
        StepImport.log 'Cancelled by the user'
        stop_timers
        kill_freecad
        abort_op
        @dlg.close if @dlg
        cleanup_tmp
        Sketchup.status_text = t('status.cancelled')
      end

      private

      def guarded
        yield
      rescue => e
        fail!(t('err.generic', cls: e.class, msg: e.message), e)
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
          # The FreeCADCmd console is created hidden: WScript.Shell.Run with window style 0.
          cmd  = %("#{@exe.tr('/', '\\')}" "#{@py.tr('/', '\\')}")
          body = %(CreateObject("WScript.Shell").Run "#{cmd.gsub('"', '""')}", 0, False\r\n)
          vbs  = File.join(@tmp, 'run.vbs')
          File.binwrite(vbs, "\uFEFF".encode('UTF-16LE') + body.encode('UTF-16LE'))
          pid = Process.spawn(@env, wscript, '//B', '//Nologo', vbs.tr('/', '\\'))
          Process.detach(pid)
          @mode = :hidden
          StepImport.log 'FreeCAD started hidden (wscript)'
        else
          launch_direct
        end
      end

      def launch_direct
        @fc_pid = Process.spawn(@env, @exe, @py,
                                [:out, :err] => File.join(@tmp, 'freecad_console.log'),
                                :in => File::NULL)
        @mode = :direct
        StepImport.log "FreeCAD started normally, pid #{@fc_pid}"
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
        true                       # not sure - assume alive, the timeout will catch it
      end

      def kill_freecad
        pid = @fc_pid || read_pid
        return unless pid
        return unless fc_alive?
        Process.kill('KILL', pid)
        StepImport.log "FreeCAD process #{pid} killed"
      rescue StandardError => e
        StepImport.log "Could not kill FreeCAD #{pid}: #{e.class}"
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

      # step2stl_fc.py reports progress as translation keys (+ optional arguments)
      def fc_text(key, args = nil)
        return '' if key.to_s.empty?
        vars = nil
        vars = args.each_with_object({}) { |(k, v), h| h[k.to_sym] = v } if args.is_a?(Hash)
        t(key.to_s, vars)
      end

      def poll_freecad
        return unless @active
        elapsed = Time.now - @t_fc
        @fc_pid ||= read_pid

        if File.exist?(File.join(@tmp, 'error.txt'))
          txt = read_text('error.txt')
          return fail!(t('err.freecad_reported', text: txt[-900..] || txt))
        end

        if (prog = read_json('progress.json'))
          f = prog['fraction']
          pct = f.nil? ? -1 : (f.to_f * FC_SHARE * 100).round(1)
          stage = fc_text(prog['stage'])
          @dlg.update(pct, stage, fc_text(prog['detail'], prog['args']))
          if stage != @last_stage
            @last_stage = stage
            @dlg.add_log(stage)
          end
        end

        if File.exist?(File.join(@tmp, 'done.flag'))
          stop_timers
          StepImport.log format('FreeCAD finished in %.1f s', elapsed)
          kill_freecad                       # in case the process did not exit by itself
          return begin_build
        end

        if @mode == :hidden && @fc_pid.nil? && elapsed > 20
          StepImport.log 'Hidden launch did not work, starting FreeCAD normally'
          @dlg.add_log(t('log.fc_visible_fallback'))
          launch_direct
          @t_fc = Time.now
          return
        end

        if @fc_pid && !fc_alive?
          return if File.exist?(File.join(@tmp, 'done.flag'))   # finished just now - handled on the next tick
          return fail!(t('err.freecad_no_result', text: read_text('freecad.log')[-600..]))
        end

        if elapsed > FREECAD_TIMEOUT
          fail!(t('err.freecad_timeout', minutes: FREECAD_TIMEOUT / 60))
        else
          Sketchup.status_text = t('status.fc_working', sec: elapsed.to_i)
        end
      end

      # ----- Model building (in steps, driven by a timer) -----

      def begin_build
        data = JSON.parse(File.read(File.join(@tmp, 'manifest.json'), encoding: 'UTF-8'))
        @defs  = data['definitions']
        @insts = data['instances']
        StepImport.log "Manifest: #{@defs.size} definitions, #{@insts.size} instances"
        return fail!(t('err.no_parts')) if @insts.empty?

        big = []
        @defs.each do |d|
          size = File.size(File.join(@tmp, d['file']))
          d['tris_est'] = [(size - 84) / 50, 0].max
          StepImport.log format('%s  %s: %.1f MB, ~%d triangles', d['file'], d['name'], size / 1048576.0, d['tris_est'])
          big << d if d['tris_est'] > BIG_TRIS
        end
        unless big.empty?
          list = big.map { |d| t('big.item', name: d['name'], tris: d['tris_est']) }.join("\n")
          answer = UI.messagebox(t('big.prompt', list: list), MB_YESNO)
          return cancel unless answer == IDYES
        end

        @model = Sketchup.active_model
        @guid  = @model.guid
        @model.start_operation('Import STEP assembly', true)
        @op_open = true
        @root = @model.active_entities.add_group
        @root.name = @name
        @cache = {}          # container path -> group
        @comps = {}          # definition index -> ComponentDefinition
        @idx = 0
        @announced = {}
        @t_build = Time.now
        @dlg.add_log(t('log.building'))
        schedule(0.05)
      end

      def schedule(delay)
        @tick = UI.start_timer(delay, false) { guarded { build_tick } }
      end

      def build_tick
        return unless @active
        return fail!(t('err.model_changed')) unless Sketchup.active_model.guid == @guid

        budget = Time.now + 0.15
        while @idx < @insts.size
          i = @insts[@idx]
          d = @defs[i['def']]
          needs_build = d['count'] > 1 ? !@comps.key?(i['def']) : true

          # Heavy part: announce it first and let the window repaint, then build.
          if needs_build && d['tris_est'] > HEAVY_TRIS && !@announced[@idx]
            @announced[@idx] = true
            secs = [(d['tris_est'] / TRIS_PER_SEC.to_f).round, 1].max
            @dlg.update(build_pct, t('stage.building_part', name: i['name']),
                        t('detail.heavy', tris: d['tris_est'], secs: secs))
            @dlg.add_log(t('log.heavy', name: i['name'], secs: secs))
            return schedule(0.15)
          end

          place_instance(i, d)
          @idx += 1
          @dlg.update(build_pct, t('stage.building'),
                      t('detail.progress', done: @idx, total: @insts.size, name: i['name']))
          break if Time.now > budget
        end

        @idx >= @insts.size ? finish_build : schedule(0.01)
      end

      def build_pct
        BUILD_FROM + (BUILD_TO - BUILD_FROM) * (@idx.to_f / @insts.size)
      end

      def place_instance(i, d)
        parent = StepImport.ensure_path(@root, @cache, i['path'])
        tr = StepImport.to_transformation(i['matrix'])

        if d['count'] > 1
          cd = (@comps[i['def']] ||= StepImport.make_definition(@tmp, d))
          return unless cd
          obj = parent.entities.add_instance(cd, tr)
        else
          obj = parent.entities.add_group
          unless StepImport.fill_entities(obj.entities, @tmp, d)
            obj.erase!
            return
          end
          obj.transformation = tr
        end
        obj.name = i['name']
      end

      def finish_build
        @model.commit_operation
        @op_open = false
        StepImport.log format('Model built in %.1f s', Time.now - @t_build)
        Sketchup.status_text = t('status.summary', insts: @insts.size, defs: @defs.size)

        skp = nil
        if SAVE_SKP
          @dlg.update(BUILD_TO, t('stage.saving'), "#{@name}.skp")
          skp = StepImport.save_skp(@step)
        end

        total = Time.now - @t0
        StepImport.log format('Done, %.1f s in total', total)
        @dlg.add_log(t('log.done', sec: total.round))
        @dlg.finish(t('stage.finished'),
                    skp ? t('detail.saved', path: skp) : t('detail.counts', insts: @insts.size, defs: @defs.size))
        @active = false
        cleanup_tmp
        UI.start_timer(2.5, false) { @dlg.close }
      end

      # ----- Finishing -----

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
        StepImport.log "ERROR: #{msg}"
        StepImport.log err.backtrace.first(8).join("\n") if err
        StepImport.log "Temp folder kept for diagnosis: #{@tmp}"
        @keep_tmp = true
        @dlg.close if @dlg
        UI.messagebox(t('err.log_hint', msg: msg, log: LOG_FILE))
      end
    end

    # ---------- Entry points ----------

    def self.run
      if @job && @job.active?
        return UI.messagebox(t('run.already'))
      end

      exe = freecad_exe
      return UI.messagebox(t('freecad.not_found')) unless exe
      return UI.messagebox(t('run.script_missing', path: SCRIPT)) unless File.exist?(SCRIPT)

      step = UI.openpanel(t('run.open_title'), '', 'STEP|*.step;*.stp||')
      return unless step

      @job = Job.new(exe, step)
      @job.start
    end

    def self.open_settings
      SettingsDialog.show_or_focus
    end

    # ---------- Geometry building ----------

    # Reads an STL and builds faces in entities (pass an EMPTY collection). Returns false if there are no meshes.
    # fill_from_mesh is orders of magnitude faster than add_faces_from_mesh on big meshes
    # (measured on a PCB: 35k triangles - 0.27 s vs 29 s).
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

      log format('  %s: %d triangles, reading %.1f s, faces %.1f s',
                 d['file'], total, (Time.now - t0) - t_fill, t_fill)

      if total <= SOFTEN_MAX
        soften(entities)
      else
        log "  edge softening skipped (more than #{SOFTEN_MAX} triangles)"
      end
      true
    end

    # Chain of nested groups following the container path (all with identity transformations).
    # Part matrices are global, so containers carry no transformation.
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

    # FreeCAD: 16 numbers row by row, translation in r[3], r[7], r[11] (mm)
    # SketchUp: 16 numbers column by column, translation in inches
    def self.to_transformation(r)
      Geom::Transformation.new([
        r[0], r[4], r[8],  r[12],
        r[1], r[5], r[9],  r[13],
        r[2], r[6], r[10], r[14],
        r[3].mm, r[7].mm, r[11].mm, r[15]
      ])
    end

    # ---------- Saving .skp ----------

    def self.save_skp(step_path)
      skp = File.join(File.dirname(step_path), "#{File.basename(step_path, '.*')}.skp")
      if File.exist?(skp)
        answer = UI.messagebox(t('save.exists', name: File.basename(skp)), MB_YESNO)
        return unless answer == IDYES
      end
      model = Sketchup.active_model
      if model.path.to_s.empty?
        # New (unsaved) model: save_copy is not available for it,
        # so the model itself is saved under this name.
        model.save(skp)
      else
        # Model opened from a file: write a copy, leave the current document alone.
        model.save_copy(skp)
      end
      Sketchup.status_text = t('status.saved', path: skp)
      log "Saved: #{skp}"
      skp
    rescue => e
      UI.messagebox(t('err.save_failed', msg: e.message))
      nil
    end

    # ---------- STL ----------

    # Yields [PolygonMesh, triangle_count] to the block. The whole STL goes in ONE mesh:
    # fill_from_mesh only works on an empty collection; repeated calls into the same
    # group add nothing (verified on the PCB: of 6 chunks only the first was built).
    def self.each_stl_mesh(path)
      size = File.size(path)

      File.open(path, 'rb') do |f|
        count = f.read(84)[80, 4].unpack1('V')

        if size == 84 + 50 * count    # binary STL
          fmt_full = 'x12e9x2' * CHUNK
          limit = count        # IMPORTANT: one STL = one PolygonMesh (see the comment above)
          left = count
          while left > 0
            n    = left < limit ? left : limit
            mesh = Geom::PolygonMesh.new
            pts  = {}                 # (x, y, z) in STL -> point index in the mesh
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
        else                          # ASCII STL, single mesh
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

    # ---------- Menu ----------

    Lang.current = Settings.get('language', Lang::DEFAULT)

    unless file_loaded?(__FILE__)
      submenu = UI.menu('Plugins').add_submenu(t('menu.title'))
      submenu.add_item(t('menu.import')) { run }
      submenu.add_item(t('menu.settings')) { open_settings }
      file_loaded(__FILE__)
    end
  end
end
