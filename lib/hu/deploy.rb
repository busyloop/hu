# frozen_string_literal: true
require 'version_sorter'
require 'versionomy'
require 'tty-prompt'
require 'tty-spinner'
require 'tty-table'
require 'rainbow'
require 'rainbow/ext/string'
require 'open3'
require 'json'
require 'awesome_print'
require 'chronic_duration'
require 'tempfile'
require 'thread_safe'
require 'io/console'
require 'rugged'
require 'pty'
require 'thread'
require 'paint'
require 'lolcat/lol'
require 'io/console'

module Hu
  class Cli < Optix::Cli
    class Deploy < Optix::Cli
      ::TTY::Formats::FORMATS[:hu] = { frames: '🌑🌒🌓🌔🌕🌖🌗🌘'.chars, interval: 10 }
      ::TTY::Formats::FORMATS[:huroku] = { frames: '⣾⣽⣻⢿⡿⣟⣯⣷'.chars, interval: 10 }

      $stdout.sync
      @@shutting_down = false
      @@spinner = nil

      text 'Interactive deployment.'
      desc 'Interactive deployment'
      if Hu::API_TOKEN.nil?
        text ''
        text "\e[1mWARNING: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
      end
      filter do
        if Hu::API_TOKEN.nil?
          STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
          exit 1
        end
      end

      def deploy(_cmd, _opts, _argv)
        Hu::Tm.t(:invoke, cmd: 'deploy')
        trap('INT') { shutdown; puts "\e[0m\e[35;1m^C\e[0m"; exit 1 }
        at_exit do
          if $!.class == SystemExit && 130 == $!.status
            puts "\n\n"
          end
          Hu::Tm.flush!
          shutdown
          print "\e[0m\e[?25h"
        end

        begin
          @git = Rugged::Repository.discover('.')
        rescue Rugged::RepositoryError => e
          puts
          puts "Git error: #{e}".color(:red)
          puts 'You need to be inside the working copy of the app that you wish to deploy.'.color(:red)
          puts
          print TTY::Cursor.prev_line
          Hu::Tm.t(:error_not_in_working_copy, cmd: 'deploy')
          exit 1
        end

        Dir.chdir(@git.workdir)

        if @git.config['branch.master.remote'] != 'origin'
          puts
          puts "ERROR: Remote of branch 'master' does not point to 'origin'.".color(:red)
          puts
          puts '       Sorry, we need an origin here. We really do.'
          puts
          Hu::Tm.t(:error_no_git_origin, cmd: 'deploy')
          exit 1
        end

        if @git.config['gitflow.branch.master'].nil?
          puts
          puts "ERROR: This repository doesn't seem to be git-flow enabled.".color(:red)
          puts
          puts "       Please run 'git flow init -d'"
          puts
          Hu::Tm.t(:error_no_git_flow, cmd: 'deploy')
          exit 1
        end

        unless @git.config['gitflow.prefix.versiontag'].nil? ||
               @git.config['gitflow.prefix.versiontag'].empty?
          puts
          puts 'ERROR: git-flow version prefix configured.'.color(:red)
          puts
          puts '       Please use this command to remove the prefix:'
          puts
          puts "       git config --add gitflow.prefix.versiontag ''".bright
          puts
          Hu::Tm.t(:error_git_flow_prefix_enabled, cmd: 'deploy')
          exit 1
        end

        push_url = heroku_git_remote

        wc_update = Thread.new { update_working_copy }

        app = heroku_app_by_git(push_url)

        if app.nil?
          puts
          puts "ERROR: Found no heroku app for git remote #{push_url}".color(:red)
          puts '       Are you logged into the right heroku account?'.color(:red)
          puts
          puts "       Please run 'git remote rm heroku'. Then run 'hu deploy' again to select a new remote."
          puts
          Hu::Tm.t(:error_no_heroku_app_for_remote, cmd: 'deploy')
          exit 1
        end

        pipeline_name, stag_app_id, prod_app_id = heroku_pipeline_details(app)

        if app['id'] != stag_app_id
          puts
          puts "ERROR: The git remote 'heroku' points to app '#{app['name']}'".color(:red)
          puts "       which is not in stage 'staging'".color(:red) +
               " of pipeline '#{pipeline_name}'.".color(:red)
          puts
          puts '       The referenced app MUST be the staging member of the pipeline.'

          puts "       Please run 'git remote rm heroku'. Then run 'hu deploy' again to select a new remote."
          puts
          Hu::Tm.t(:error_remote_not_staging, cmd: 'deploy')
          sleep 2
          exit 1
        end

        stag_app_name = app['name']
        busy "fetching heroku app #{prod_app_id}", :dots
        prod_app_name = h.app.info(prod_app_id)['name']
        unbusy

        busy 'update working copy', :dots
        wc_update.join
        unbusy

        highest_version = find_highest_version_tag
        begin
          highest_versionomy = Versionomy.parse(highest_version)
        rescue
          highest_versionomy = Versionomy.parse('v0.0.0')
        end

        all_tags = Set.new(@git.references.to_a('refs/tags/*').collect { |o| o.name[10..-1] })

        tiny_bump  = highest_versionomy.dup
        minor_bump = highest_versionomy.dup
        major_bump = highest_versionomy.dup

        loop do
          tiny_bump = tiny_bump.bump(:tiny)
          break unless all_tags.include? tiny_bump.to_s
        end
        loop do
          minor_bump = minor_bump.bump(:minor)
          break unless all_tags.include? minor_bump.to_s
        end
        loop do
          major_bump = major_bump.bump(:major)
          break unless all_tags.include? tiny_bump.to_s
        end
        tiny_bump  = tiny_bump.to_s
        minor_bump = minor_bump.to_s
        major_bump = major_bump.to_s

        likely_next_version = tiny_bump

        release_tag, branch_already_exists = prompt_for_release_tag(likely_next_version, likely_next_version, true)

        prompt = TTY::Prompt.new

        clearscreen = true
        loop do
          git_revisions = show_pipeline_status(pipeline_name, stag_app_name, prod_app_name, release_tag, clearscreen)
          clearscreen = true

          changelog = 'Initial revision'
          release_branch_exists = branch_exists?("release/#{release_tag}")

          if release_branch_exists
            puts "\nThis release will be " + release_tag.color(:red).bright
            unless highest_version == 'v0.0.0'
              env = {
                'PREVIOUS_TAG' => highest_version,
                'RELEASE_TAG'  => release_tag
              }
              changelog = create_changelog(env) unless highest_version == 'v0.0.0'
              unless changelog.empty?
                puts "\nChanges since " + highest_version.bright + ':'
                puts changelog
              end
            end
          else
            puts "\nThis is release " + release_tag.color(:green).bright
          end
          puts

          unless git_revisions[:release] == git_revisions[stag_app_name] || !release_branch_exists
            puts 'Phase 1/3: The local release branch ' + "release/#{release_tag}".bright + ' was created.'
            puts '           Nothing else has happened so far. Push this branch to'
            puts '           ' + stag_app_name.to_s.bright + ' to begin the deploy procedure.'
            puts
            Hu::Tm.t(:phase1, cmd: 'deploy')
          end

          if release_branch_exists && git_revisions[:release] == git_revisions[stag_app_name]
            puts 'Phase 2/3: Your local ' + "release/#{release_tag}".bright + ' (formerly ' + 'develop'.bright + ') is live at ' + stag_app_name.to_s.bright + '.'
            puts '           Please test here: ' + (app['web_url']).to_s.bright
            puts '           If everything looks good, you may proceed and finish the release.'
            puts '           If there are problems: Quit, delete the release branch and start fixing.'
            puts
            Hu::Tm.t(:phase2, cmd: 'deploy')
          elsif git_revisions[prod_app_name] != git_revisions[stag_app_name] && !release_branch_exists && git_revisions[:release] != git_revisions[stag_app_name]
            puts 'Phase 3/3: HEADS UP! This is the last chance to detect problems.'
            puts '           The final version of ' + "release/#{release_tag}".bright + ' is now staged.'
            puts
            puts '           Test here: ' + (app['web_url']).to_s.bright
            sleep 1
            puts
            puts '           This is the exact version that will be promoted to production.'
            puts "           From here you are on your own. Good luck #{`whoami`.chomp}!"
            puts
            Hu::Tm.t(:phase3, cmd: 'deploy')
          end

          choice = prompt.select('Choose your destiny') do |menu|
            menu.enum '.'
            menu.choice 'Refresh', :refresh
            menu.choice 'Quit', :abort_ask
            unless git_revisions[:release] == git_revisions[stag_app_name] || !release_branch_exists
              menu.choice "Push release/#{release_tag} to #{stag_app_name}", :push_to_staging
            end
            if release_branch_exists
              unless release_tag == tiny_bump
                menu.choice "Change to PATCH release (bugfix only)     : #{highest_version} -> #{tiny_bump}", :bump_tiny
              end

              unless release_tag == minor_bump
                menu.choice "Change to MINOR release (new features)    : #{highest_version} -> #{minor_bump}", :bump_minor
              end

              unless release_tag == major_bump
                menu.choice "Change to MAJOR release (breaking changes): #{highest_version} -> #{major_bump}", :bump_major
              end

              if git_revisions[:release] == git_revisions[stag_app_name]
                menu.choice 'Finish release (merge, tag and final stage)', :finish_release
              end
            elsif git_revisions[prod_app_name] != git_revisions[stag_app_name]
              menu.choice "DEPLOY (promote #{stag_app_name} to #{prod_app_name})", :DEPLOY
            end
          end

          puts

          case choice
          when :DEPLOY
            Hu::Tm.t(:promote_begin, cmd: 'deploy')
            promote_to_production
            Hu::Tm.t(:promote_end, cmd: 'deploy')
            anykey
          when :finish_release
            Hu::Tm.t(:finish_begin, cmd: 'deploy')
            old_editor = ENV['EDITOR']
            old_git_editor = ENV['GIT_EDITOR']
            tf = Tempfile.new('hu-tag')
            tf.write "#{release_tag}\n#{changelog}"
            tf.close
            ENV['EDITOR'] = ENV['GIT_EDITOR'] = "cp #{tf.path}"
            env = {
              'PREVIOUS_TAG' => highest_version,
              'RELEASE_TAG'  => release_tag,
              'GIT_MERGE_AUTOEDIT' => 'no'
            }
            unless 0 == finish_release(release_tag, env)
              abort_merge
              puts '*** ERROR! Could not finish release *** '.color(:red)
              puts
              puts 'This usually means a merge conflict or'
              puts 'something equally annoying has occured.'
              puts
              puts 'Please bring the universe into a state'
              puts 'where the above sequence of commands can'
              puts 'succeed. Then try again.'
              puts
              Hu::Tm.t(:finish_fail, cmd: 'deploy')
              exit 1
            end
            ENV['EDITOR'] = old_editor
            ENV['GIT_EDITOR'] = old_git_editor
            Hu::Tm.t(:finish_end, cmd: 'deploy')
            anykey
          when :push_to_staging
            Hu::Tm.t(:stage_begin, cmd: 'deploy')
            run_each <<-EOS.strip_heredoc
              :stream
              git push #{push_url} release/#{release_tag}:master -f
              EOS
            Hu::Tm.t(:stage_end, cmd: 'deploy')
            anykey
          when :abort_ask
            Hu::Tm.t(:user_quit, cmd: 'deploy')
            puts if delete_branch("release/#{release_tag}")
            exit 0
          when :bump_tiny
            if delete_branch("release/#{release_tag}")
              release_tag, branch_already_exists = prompt_for_release_tag(tiny_bump, tiny_bump)
              Hu::Tm.t(:switch_release_type, bump: 'patch', cmd: 'deploy')
            end
          when :bump_minor
            if delete_branch("release/#{release_tag}")
              release_tag, branch_already_exists = prompt_for_release_tag(minor_bump, minor_bump)
              Hu::Tm.t(:switch_release_type, bump: 'minor', cmd: 'deploy')
            end
          when :bump_major
            if delete_branch("release/#{release_tag}")
              release_tag, branch_already_exists = prompt_for_release_tag(major_bump, major_bump)
              Hu::Tm.t(:switch_release_type, bump: 'major', cmd: 'deploy')
            end
          end
        end
      end

      def show_pipeline_status(pipeline_name, stag_app_name, prod_app_name, release_tag, clear = true)
        table = TTY::Table.new header: %w(location commit tag app_last_modified app_last_modified_by dynos# state)
        busy 'loading', :huroku
        ts = []
        workers = []
        tpl_row = ['?', '', '', '', '', '', '']
        revs = ThreadSafe::Hash.new
        app_config = ThreadSafe::Hash.new

        [[0, stag_app_name], [1, prod_app_name]].each do |idx, app_name|
          workers << Thread.new do
            # config vars
            app_config[app_name] = h.config_var.info(app_name)
          end

          ts << Thread.new do
            # dyno settings
            table_row = tpl_row.dup
            table_row[0] = app_name
            loop do
              dynos = h.dyno.list(app_name)
              break if dynos.nil?
              dp :dynos, dynos

              table_row[5] = dynos.length

              release_version = dynos.dig(0, 'release', 'version')
              break if release_version.nil?

              state = Set.new(dynos.collect { |d| d['state'] }).sort.join(', ')
              state_color = (state == 'up') ? 32 : 31
              table_row[6] = "\e[#{state_color};1m#{state}"

              release_info = h.release.info(app_name, release_version)
              dp :release_info, release_info
              break if release_info.nil?

              slug_info = h.slug.info(app_name, release_info['slug']['id'])
              dp :slug_info, slug_info
              break if slug_info.nil?

              revs[app_name] = table_row[1] = slug_info['commit'][0..5]

              table_row[2] = `git tag --points-at #{slug_info['commit']} 2>/dev/null`
              table_row[2] = '' unless $?.success?

              # heroku uses wrong timezone offset in the slug api... /facepalm
              # table_row[3] = ChronicDuration.output(Time.now.utc - Time.parse(slug_info['updated_at']), :units => 1)

              delta = Time.now.utc - Time.parse(release_info['updated_at'])
              table_row[3] = delta < 60 ? 'less than a minute' : ChronicDuration.output(delta, units: 1)
              table_row[3] += ' ago'
              # table_row[3] += "\n\e[30;1m" + slug_info['updated_at']

              table_row[4] = release_info['user']['email']
              table_row[5] = dynos.length
              break
            end
            [idx, table_row]
          end
        end

        workers.each(&:join)

        rows = []
        ts.each do |t|
          idx, table_row = t.value
          rows[idx] = table_row
        end

        row = tpl_row.dup
        row[0] = 'master'
        revs[:master] = row[1] = `git rev-parse master`[0..5]
        row[2] = `git tag --points-at master`
        rows.unshift row

        if branch_exists? "release/#{release_tag}"
          row = tpl_row.dup
          row[0] = "release/#{release_tag}"
          revs["release/#{release_tag}"] = revs[:release] = row[1] = `git rev-parse release/#{release_tag}`[0..5]
          row[2] = `git tag --points-at release/#{release_tag} 2>/dev/null`
          rows.unshift row
        end

        row = tpl_row.dup
        row[0] = 'develop'
        revs[:develop] = row[1] = `git rev-parse develop`[0..5]
        row[2] = `git tag --points-at develop`
        rows.unshift row

        unbusy

        rows.each do |r|
          table << r
        end

        puts "\e[H\e[2J" if clear
        puts " PIPELINE #{pipeline_name} ".inverse
        puts

        puts table.render(:unicode, padding: [0, 1, 0, 1], multiline: true)

        missing_env = app_config[stag_app_name].keys - app_config[prod_app_name].keys
        unless missing_env.empty?
          puts
          missing_env.each do |var|
            puts ' WARNING '.color(:red).bright.inverse + ' Missing config in ' + prod_app_name.bright + ": #{var}"
            sleep 0.42
          end
        end

        Hu::Tm.t(:status_screen, cmd: 'deploy')
        revs
      end

      def heroku_app_by_git(git_url)
        busy('fetching heroku apps', :dots)
        r = h.app.list.select { |e| e['git_url'] == git_url }
        unbusy
        raise "FATAL: Found multiple heroku apps with git_url=#{git_url}" if r.length > 1
        r[0]
      end

      def heroku_pipeline_details(app)
        busy('fetching heroku pipelines', :dots)
        couplings = h.pipeline_coupling.list
        unbusy
        r = couplings.select { |e| e['app']['id'] == app['id'] }
        raise "FATAL: Found multiple heroku pipelines with app.id=#{r['id']}" if r.length > 1
        raise "FATAL: Found no heroku pipeline for app.id=#{r['id']}" if r.length != 1
        r = r[0]
        pipeline_name = r['pipeline']['name']

        r = couplings.select { |e| e['pipeline']['id'] == r['pipeline']['id'] && e['stage'] == 'staging' }[0]
        staging_app_id = r['app']['id']

        r = couplings.select { |e| e['pipeline']['id'] == r['pipeline']['id'] && e['stage'] == 'production' }[0]
        raise "FATAL: No production app in pipeline #{pipeline_name}" if r.nil?
        prod_app_id = r['app']['id']
        [pipeline_name, staging_app_id, prod_app_id]
      end

      def h
        @h ||= PlatformAPI.connect_oauth(Hu::API_TOKEN)
      end

      def run_each(script, opts = {})
        opts = {
          quiet: false,
          failfast: true,
          spinner: true,
          stream: false
        }.merge(opts)

        @spinlock ||= Mutex.new # :P
        script.lines.each_with_index do |line, i|
          line.chomp!
          case line[0]
          when '#'
            puts "\n" + line.bright unless opts[:quiet]
          when ':'
            opts[:quiet] = true if line == ':quiet'
            opts[:failfast] = false if line == ':return'
            opts[:spinner]  = false if line == ':nospinner'
            if line == ':stream'
              opts[:stream] = true
              opts[:quiet] = false
            end
          end
          next if line.empty? || ['#', ':'].include?(line[0])

          status = nil
          if opts[:stream]
            puts "\n> ".color(:green) + line.color(:black).bright
            rows, cols = STDIN.winsize
            @minispin_disable = false
            @minispin_last_char_at = Time.now
            @tspin ||= Thread.new do
              i = 0
              loop do
                break if @minispin_last_char_at == :end
                if 0.23 > Time.now - @minispin_last_char_at || @minispin_disable
                  sleep 0.1
                  next
                end
                @spinlock.synchronize do
                  next if @minispin_disable
                  print "\e[?25l"
                  print Paint[' ', '#000', Lol.rainbow(1, i / 3.0)]
                  sleep 0.12
                  print 8.chr
                  print ' '
                  print 8.chr
                  i += 1
                  print "\e[?25h"
                end
              end
            end

            PTY.spawn("stty rows #{rows} cols #{cols}; " + line) do |r, _w, pid|
              begin
                until r.eof?
                  c = r.getc
                  @spinlock.synchronize do
                    print c
                    @minispin_last_char_at = Time.now
                    c = c.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: "\e") # barf.
                    # hold on when we are (likely) inside an escape sequence
                    @minispin_disable = true  if c.ord == 27 || c.ord < 9
                    @minispin_disable = false if c =~ /[A-Za-z]/ || [13, 10].include?(c.ord)
                  end
                end
              rescue Errno::EIO
                # Linux raises EIO on EOF, cf.
                # https://github.com/ruby/ruby/blob/57fb2199059cb55b632d093c2e64c8a3c60acfbb/ext/pty/pty.c#L519
                nil
              end

              _pid, status = Process.wait2(pid)
              @minispin_last_char_at = :end
              @tspin.join
              @tspin = nil
              # status = PTY.check(pid)
            end
          else
            busy line if opts[:spinner]
            output, status = Open3.capture2e(line)
            unbusy if opts[:spinner]
            color = (status.exitstatus == 0) ? :green : :red
            if status.exitstatus != 0 || !opts[:quiet]
              puts "\n> ".color(color) + line.color(:black).bright
              puts output
            end
          end
          next unless status.exitstatus != 0
          shutdown if opts[:failfast]
          puts "Error, exit #{status.exitstatus}: #{line} (L#{i})".color(:red).bright

          Hu::Tm.t(:runeach_error, exitstatus: status.exitstatus, cmd: 'deploy')
          exit status.exitstatus if opts[:failfast]
          return status.exitstatus
        end
        0
      end

      def find_highest_version_tag
        output, status = Open3.capture2e('git tag')
        if status.exitstatus != 0
          puts 'Error fetching git tags.'
          exit status.exitstatus
        end

        versions = output.lines.map(&:chomp).reject do |e|
          begin
                                                 Versionomy.parse(e)
                                               rescue
                                                 true
                                               end; false
        end
        versions = versions.map { |e| e[0].casecmp('v').zero? ? e.downcase : "v#{e.downcase}" }
        versions = VersionSorter.sort(versions)
        latest = versions[-1] || 'v0.0.0'
        latest = "v#{latest}" unless latest[0] == 'v'
        latest
      end

      def branch_exists?(branch_name)
        branches = `git for-each-ref refs/heads/ --format='%(refname:short)'`.lines.map(&:chomp)
        branches.include? branch_name
      end

      def delete_branch(branch_name)
        return false unless branch_exists? branch_name
        return false if TTY::Prompt.new.no?("Delete branch #{branch_name}?")
        run_each <<-EOS.strip_heredoc
          :quiet
          # Delete branch #{branch_name}
          git checkout develop
          git branch -D #{branch_name}
        EOS
        Hu::Tm.t(:delete_release_branch, cmd: 'deploy')
        puts "Branch #{branch_name} deleted.".color(:red)
        true
      end

      def checkout_branch(branch_name)
        run_each <<-EOS.strip_heredoc
          :quiet
          # Checkout branch #{branch_name}
          git checkout #{branch_name}
        EOS
      end

      def start_release(release_tag)
        run_each <<-EOS.strip_heredoc
        # Starting release #{release_tag.color(:green)}
        git flow release start #{release_tag} >/dev/null
        EOS
        Hu::Tm.t(:start_release, cmd: 'deploy')
      end

      def update_working_copy
        run_each <<-EOS.strip_heredoc
        :quiet
        :nospinner
        # Ensure local repository is up to date
        git checkout develop && git pull
        git checkout master && git pull --rebase origin master
        EOS
        Hu::Tm.t(:update_working_copy, cmd: 'deploy')
      end

      def heroku_git_remote
        ensure_repo_has_heroku_remote
        `git remote show -n heroku | grep Push`.chomp.split(':', 2)[1][1..-1]
      end

      def ensure_repo_has_heroku_remote
        exit_code = run_each <<-EOS.strip_heredoc
        :quiet
        :return
        # Ensure we have a 'heroku' git remote
        git remote | grep -q "^heroku$"
        EOS
        return if exit_code == 0

        # Setup git remote
        puts
        puts "This repository has no 'heroku' remote.".color(:red)
        puts 'We will set one up now. Please select the pipeline that you'
        puts "wish to deploy to, and we will set the 'heroku' remote"
        puts 'to the staging application in that pipeline.'
        puts

        busy
        heroku_apps = JSON.parse(`heroku pipelines:list --json`)
        unbusy

        prompt = TTY::Prompt.new
        pipeline_name = prompt.select('Select pipeline:') do |menu|
          menu.enum '.'
          heroku_apps.each do |app|
            menu.choice app['name']
          end
        end
        staging_app = JSON.parse(`heroku pipelines:info #{pipeline_name} --json`)['apps'].select { |e| e['coupling']['stage'] == 'staging' }[0]
        if staging_app.nil?
          puts "Error: Pipeline #{pipeline_name} has no staging app.".color(:red)
          exit 1
        end

        run_each <<-EOS.strip_heredoc
        # Add git remote
        git remote add heroku #{staging_app['git_url']}
        EOS
      end

      def prompt_for_release_tag(propose_version = 'v0.0.1', try_version = nil, keep_existing = false)
        prompt = TTY::Prompt.new
        loop do
          if try_version
            release_tag = try_version
            try_version = nil
          else
            show_existing_git_tags
            release_tag = prompt.ask('Please enter a tag for this release', default: propose_version)
            begin
              unless release_tag[0] == 'v'
                raise ArgumentError, 'Version string must start with the letter v'
              end
              raise ArgumentError, 'too short' if release_tag.length < 5
              Versionomy.parse(release_tag)
            rescue => e
              puts "Error: Tag does not look like a semantic version (#{e})".color(:red)
              next
            end
          end

          branches = `git for-each-ref refs/heads/ --format='%(refname:short)'`.lines.map(&:chomp)
          existing_branch = branches.find { |b| b.start_with? 'release/' }
          branch_already_exists = !existing_branch.nil?
          release_tag = existing_branch[8..-1] if keep_existing && branch_already_exists

          if branch_already_exists && !keep_existing
            choice = prompt.expand("The branch '" + "release/#{release_tag}".color(:red) + "' already exists. What shall we do?",
                                   default: 0) do |q|
              q.choice key: 'k', name: 'Keep, continue with the existing branch', value: :keep
              q.choice key: 'D', name: "Delete branch release/#{release_tag} and retry", value: :delete
              q.choice key: 'q', name: 'Quit', value: :quit
            end

            case choice
            when :quit
              puts
              exit 0
            when :delete
              delete_branch("release/#{release_tag}")
              next
            end
          end

          if branch_already_exists
            checkout_branch("release/#{release_tag}")
          else
            develop_tag = `git tag --points-at develop 2>/dev/null`.lines.find { |tag| tag[0] == 'v' }&.chomp
            if develop_tag
              release_tag = develop_tag
            else
              start_release(release_tag)
              puts
            end
          end

          return release_tag, branch_already_exists
        end
      end

      def show_existing_git_tags
        run_each <<-EOS.strip_heredoc
        # Show existing git tags (previous releases)
        git tag
        EOS
      end

      def promote_to_production
        run_each <<-EOS.strip_heredoc
        :stream
        :return

        # Promote staging to production
        heroku pipelines:promote -r heroku

        # Push develop to origin
        git push origin develop
        EOS
      end

      def finish_release(release_tag, env)
        env.each { |k, v| ENV[k] = v }
        if File.executable? '.hu/hooks/pre_release'
          run_each <<-EOS.strip_heredoc
          # Run pre-release hook
          .hu/hooks/pre_release
          EOS
        end

        run_each <<-EOS.strip_heredoc
        :stream
        :return
        # Finish release
        git flow release finish #{release_tag}

        # Push final master (#{release_tag}) to origin
        git push origin master
        git push origin --tags

        # Push final master (#{release_tag}) to staging
        git push heroku master:master -f

        # Merge master back into develop
        git checkout develop
        git rebase master
        EOS
      end

      def abort_merge
        run_each <<-EOS.strip_heredoc
        :return
        # Abort failed merge (if any)
        git merge --abort
        EOS
        Hu::Tm.t(:abort_merge, cmd: 'deploy')
      end

      def create_changelog(env)
        if File.executable? '.hu/hooks/changelog'
          env.each { |k, v| ENV[k] = v }
          `.hu/hooks/changelog`
        else
          `git log --pretty=format:" - %s" #{env['PREVIOUS_TAG']}..HEAD 2>/dev/null`
        end
      end

      def shutdown
        @@shutting_down = true
        unbusy
      end

      def busy(msg = '', format = :classic, clear = true)
        return if @@shutting_down
        format ||= TTY::Formats::FORMATS.keys.sample
        options = { format: format, hide_cursor: true, error_mark: "\e[31;1m✖\e[0m", success_mark: "\e[32;1m✔\e[0m", clear: clear }
        @@spinner = TTY::Spinner.new("\e[0;1m#{msg}#{msg.empty? ? '' : ' '}\e[0m\e[32;1m:spinner\e[0m", options)
        @@spinner.start
      end

      def unbusy
        @@spinner&.stop
        printf "\e[?25h"
      end

      def with_spinner(msg = '', format = :classic)
        busy(msg, format)
        yield
        unbusy
      end

      def anykey
        puts TTY::Cursor.hide
        print '--- Press any key ---'.color(:cyan)
        STDIN.getch
        print TTY::Cursor.clear_line + TTY::Cursor.show
      end

      def dp(label, *args)
        return unless ENV['DEBUG']
        puts "---  DEBUG #{label}  ---"
        ap(*args)
        puts "--- ^#{label}^ ---"
      end

    end # /Class Deploy
  end # /Class Cli
end # /Module Hu
