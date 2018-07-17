# frozen_string_literal: true
require 'tty-spinner'

module Hu
  class Cli < Optix::Cli
    class Deploy < Optix::Cli
      ::TTY::Formats::FORMATS[:hu] = { frames: '🌑🌒🌓🌔🌕🌖🌗🌘'.chars, interval: 10 }
      ::TTY::Formats::FORMATS[:huroku] = { frames: '⣷⣯⣟⡿⢿⣻⣽⣾'.chars, interval: 10 }

      class SigQuit < StandardError; end

      RELEASE_TYPE_HINT = {
        'patch' => 'only bugfixes',
        'minor' => 'fully backwards compatible',
        'major' => 'not backwards compatible'
      }

      NUMBERS = {
        0 => 'Zero',
        1 => 'One',
        2 => 'Two',
        3 => 'Three',
        4 => 'Four',
        5 => 'Five',
        6 => 'Six',
        7 => 'Seven',
        8 => 'Eight',
        9 => 'Nine'
      }

      $stdout.sync
      @@shutting_down = false
      @@spinner = nil
      @@home_branch = nil

      # MINIMUM_GIT_VERSION = Versionomy.parse('2.9.0')

      text 'Interactive deployment.'
      desc 'Interactive deployment'
      if Hu::API_TOKEN.nil?
        text ''
        text "\e[1mWARNING: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
      end
      filter do
        begin
          if Hu::API_TOKEN.nil?
            STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
            exit 1
          end
          require 'tty-cursor'
          print TTY::Cursor.hide + "\e[30;1ms"
          require 'rainbow'
          print 'y'
          require 'rainbow/ext/string'
          print 'n'
          require 'platform-api'
          print 'c'
          require 'version_sorter'
          print 'h'
          require 'versionomy'
          print 'r'
          require 'tty-prompt'
          print 'o'
          require 'tty-table'
          require 'octokit'
          print 'n'
          require 'open3'
          require 'fidget'
          print 'i'
          require 'json'
          require 'awesome_print'
          print 'z'
          require 'chronic_duration'
          require 'tempfile'
          print 'i'
          require 'thread_safe'
          require 'io/console'
          print 'n'
          require 'rugged'
          require 'pty'
          print 'g'
          require 'thread'
          require 'paint'
          require 'lolcat/lol'
          require 'io/console'
        rescue Interrupt
          puts "\e[0m*** Abort (SIGINT)"
          puts TTY::Cursor.show
          exit 1
        end
      end

      def deploy(_cmd, _opts, _argv)
        trap('INT') { shutdown; puts "\e[0m\e[35;1m^C\e[0m"; exit 1 }

        at_exit do
          if $!.class == SystemExit && 130 == $!.status
            puts "\n\n"
          end
          shutdown
          return_to_home_branch
          print "\e[0m\e[?25h"
        end

        begin
          @git = Rugged::Repository.discover('.')
        rescue Rugged::RepositoryError => e
          print TTY::Cursor.clear_line + TTY::Cursor.show
          puts
          puts "Git error: #{e}".color(:red)
          puts 'You need to be inside the working copy of the app that you wish to deploy.'.color(:red)
          puts
          exit 1
        end

        Dir.chdir(@git.workdir)

        if @git.config['branch.master.remote'] != 'origin'
          print TTY::Cursor.clear_line + TTY::Cursor.show
          puts
          puts "ERROR: Remote of branch 'master' does not point to 'origin'.".color(:red)
          puts
          puts "       Please run 'git config branch.master.remote origin'"
          puts
          exit 1
        end

        if @git.config['gitflow.branch.master'].nil?
          print TTY::Cursor.clear_line + TTY::Cursor.show
          puts
          puts "ERROR: This repository doesn't seem to be git-flow enabled.".color(:red)
          puts
          puts "       Please run 'git flow init -d'"
          puts
          exit 1
        end

        unless @git.config['gitflow.prefix.versiontag'].nil? ||
               @git.config['gitflow.prefix.versiontag'].empty?
          print TTY::Cursor.clear_line + TTY::Cursor.show
          puts
          puts 'ERROR: git-flow version prefix configured.'.color(:red)
          puts
          puts '       Please use this command to remove the prefix:'
          puts
          puts "       git config --add gitflow.prefix.versiontag ''".bright
          puts
          exit 1
        end

        push_url = heroku_git_remote
        @@home_branch = current_branch_name

        wc_update = Thread.new { update_working_copy }

        app = heroku_app_by_git(push_url)

        if app.nil?
          print TTY::Cursor.clear_line + TTY::Cursor.show
          puts
          puts "ERROR: Found no heroku app for git remote #{push_url}".color(:red)
          puts '       Are you logged into the right heroku account?'.color(:red)
          puts
          puts "       Please run 'git remote rm heroku'. Then run 'hu deploy' again to select a new remote."
          puts
          exit 1
        end

        pipeline_name, stag_app_id, prod_app_id = heroku_pipeline_details(app)

        if app['id'] != stag_app_id
          print TTY::Cursor.clear_line + TTY::Cursor.show
          puts
          puts "ERROR: The git remote 'heroku' points to app '#{app['name']}'".color(:red)
          puts "       which is not in stage 'staging'".color(:red) +
               " of pipeline '#{pipeline_name}'.".color(:red)
          puts
          puts '       The referenced app MUST be the staging member of the pipeline.'

          puts "       Please run 'git remote rm heroku'. Then run 'hu deploy' again to select a new remote."
          puts
          sleep 2
          exit 1
        end

        stag_app_name = app['name']
        busy 'synchronizing', :dots
        prod_app_name = h.app.info(prod_app_id)['name']

        wc_update.join

        unless develop_can_be_merged_into_master?
          unbusy
          puts
          puts "ERROR: It looks like a merge of 'develop' into 'master' would fail.".color(:red)
          puts '       Aborting early to prevent a merge conflict.'.color(:red)
          puts
          exit 1
        end

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

        unbusy

        release_tag, branch_already_exists = prompt_for_release_tag(likely_next_version, likely_next_version, true)

        prompt = TTY::Prompt.new

        clearscreen = true
        loop do
          git_revisions = show_pipeline_status(pipeline_name, stag_app_name, prod_app_name, release_tag, clearscreen)

          if git_revisions[:develop] == `git rev-parse master`[0..5] && git_revisions[:develop] == git_revisions[prod_app_name] &&
             git_revisions[prod_app_name] != git_revisions[stag_app_name]
             puts
             busy 'green green red green is not a legal state', :toggle
             sleep 1
             unbusy
             puts <<-EOM
\e[41;33;1m AMBIGUOUS STATE - CAN NOT DETERMINE PHASE OF OPERATION - YOUR REALITY IS INVALID \e[0;33m

EOM
sleep 1
puts <<-EOM
 _____________
( Woah, dude! )
 -------------
        \\   ^__^
         \\  (oo)\\_______
            (__)\\       )\\/\\
                ||----w |
                ||     ||
\e[0m
You have created a situation that hu can't understand.
This is most likely due to a \e[1mheroku rollback\e[0m or \e[1mmanipulation of git history\e[0m.

But don't be afraid!  Recovery is (usually) easy:
\e[32;1m>>> \e[0m 'git commit' a new revision to your local \e[1mdevelop\e[0m branch.

When hu sees that your develop branch is different from everything else
then it can (usually) recover from there.
\e[0m
EOM
            printf "\e[13A\e[32C\033]1337;RequestAttention=fireworks\a"
            printf TTY::Cursor.hide
            sleep 2
            puts "\e[12B"
            printf TTY::Cursor.show
            exit 6
          end

          clearscreen = true

          changelog = 'Initial revision'
          release_branch_exists = branch_exists?("release/#{release_tag}")

          case release_tag
            when minor_bump
              release_type = 'minor'
            when major_bump
              release_type = 'major'
            else
              release_type = 'patch'
          end

          if release_branch_exists
            puts "\nThis will be "+"#{release_type} release ".bright+release_tag.color(:green).bright
            unless highest_version == 'v0.0.0'
              env = {
                'PREVIOUS_TAG' => highest_version,
                'RELEASE_TAG'  => release_tag
              }
              changelog = create_changelog(env) unless highest_version == 'v0.0.0'
              unless changelog.empty?
                puts "\nChanges since " + highest_version.bright + " (#{RELEASE_TYPE_HINT[release_type]})".color(:black).bright
                puts changelog.color(:green)
              end
            end
          else
            puts "\nThis is release " + release_tag.color(:green).bright
          end
          puts

          unless git_revisions[:release] == git_revisions[stag_app_name] || !release_branch_exists
            puts ' Phase 1/2 '.inverse + ' The local release branch ' + "release/#{release_tag}".bright + ' was created.'
            puts '            Nothing else has happened so far. Push this branch to'
            puts '            ' + stag_app_name.to_s.bright + ' to begin the deploy procedure.'
            puts
          end

          if release_branch_exists && git_revisions[:release] == git_revisions[stag_app_name]
            hyperlink = "\e]8;;#{app['web_url']}\007#{app['web_url']}\e]8;;\007"

            puts ' Phase 2/2 '.inverse + ' Your local ' + "release/#{release_tag}".bright + ' (formerly ' + 'develop'.bright + ') is live on ' + stag_app_name.to_s.bright + '.'
            puts
            puts '            Please test here: ' + hyperlink.bright
            puts
            puts '            If everything looks good you may proceed and deploy to production.'
            puts '            If there are problems: Quit, delete the release branch and start fixing.'
            puts
          elsif git_revisions[prod_app_name] != git_revisions[stag_app_name] && !release_branch_exists && git_revisions[:release] != git_revisions[stag_app_name]
            hyperlink = "\e]8;;#{app['web_url']}\007#{app['web_url']}\e]8;;\007"

            puts ' DEPLOY '.inverse + '  HEADS UP! This is the last chance to detect problems.'.bright
            puts '          The final version of ' + "release/#{release_tag}".bright + ' is staged.'
            puts
            puts '          Test here: ' + hyperlink.bright
            sleep 0.1
            puts
            puts '          This is the exact version that will be promoted to production.'
            type "          From here you are on your own. Good luck #{`whoami`.chomp}!"
            puts
            puts
          end

          begin
            choice = prompt.select('>') do |menu|
              menu.enum '.'
              menu.choice 'Refresh', :refresh
              menu.choice 'Quit', :abort_ask
              unless git_revisions[:release] == git_revisions[stag_app_name] || !release_branch_exists
                menu.choice "Push develop to origin/develop and release/#{release_tag} to #{stag_app_name}", :push_to_staging
              end
              if release_branch_exists
                unless release_tag == tiny_bump
                  menu.choice "Change to PATCH release (bugfix only)       #{highest_version} -> #{tiny_bump}", :bump_tiny
                end

                unless release_tag == minor_bump
                  menu.choice "Change to MINOR release (new features)      #{highest_version} -> #{minor_bump}", :bump_minor
                end

                unless release_tag == major_bump
                  menu.choice "Change to MAJOR release (breaking changes)  #{highest_version} -> #{major_bump}", :bump_major
                end

                if git_revisions[:release] == git_revisions[stag_app_name]
                  menu.choice "DEPLOY to #{prod_app_name}", :finish_release
                end
              elsif git_revisions[prod_app_name] != git_revisions[stag_app_name]
                menu.choice "DEPLOY (promote #{stag_app_name} to #{prod_app_name})", :DEPLOY
              end
            end
          rescue TTY::Reader::InputInterrupt
            choice = :abort
            puts "\n\n"
          end

          case choice
          when :DEPLOY
            Fidget.prevent_sleep(:display, :sleep, :user) do
              promote_to_production
            end
            anykey
          when :finish_release
            Fidget.prevent_sleep(:display, :sleep, :user) do
              if ci_clear?
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
                unless 0 == finish_release(release_tag, env, tf.path)
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
                  exit 1
                end
                ENV['EDITOR'] = old_editor
                ENV['GIT_EDITOR'] = old_git_editor

                promote_to_production
                promoted_at = Time.now.to_i

                formation = h.formation.info(prod_app_name, 'web')
                dyno_count = formation['quantity']

                phase = :init
                want = dyno_count
                have = 0
                release_rev = `git rev-parse develop`[0..7]
                parser = Proc.new do |line, pid|
                  begin
                    source, line = line.chomp.split(' ', 2)[1].split(' ', 2)
                    source = /\[(.*)\]:/.match(source)[1]
                    prefix = "\e[0m"
                    case phase
                    when :init
                      if line =~ /Deploy #{release_rev}/
                        phase = :observe
                      end
                    when :observe
                      if line =~ /State changed from starting to crashed/
                        prefix = "\e[31;1m"
                      elsif line =~ /State changed from starting to up/
                        prefix = "\e[32;1m"
                        have += 1
                      end

                      t = Time.now.to_i - promoted_at
                      ts = sprintf("%02d:%02d", t / 60, t % 60)
                      print "\e[30;1m[\e[0;33mT+#{ts} #{prefix}#{have}\e[0m/#{prefix}#{want}\e[30;1m] \e[0m"
                      print "#{source}: " unless source == 'api'
                      print prefix + line
                      puts

                      if have >= want
                        Process.kill("TERM", pid)
                      end
                    end
                  rescue
                  end
                end

                puts
                puts "\e[0;1m# Observe startup\e[0m"
                if h.app_feature.info(prod_app_name, 'preboot').dig('enabled')
                  puts <<EOF
#
# \e[0m\e]8;;https://devcenter.heroku.com/articles/preboot\007Preboot\e]8;;\007 is \e[32;1menabled\e[0m for \e[1m#{prod_app_name}\e[0m.
#
# #{NUMBERS[formation['quantity']] || formation['quantity']} new dyno#{formation['quantity'] == 1 ? '' : 's'} (\e[1m#{formation['size']}\e[0m) #{formation['quantity'] == 1 ? 'is' : 'are'} starting up.
# The old dynos will shut down within 3 minutes.
EOF
                end

                script = <<-EOS.strip_heredoc
                :stream
                :quiet
                :failquiet
                :nospinner
                :return
                heroku logs --tail -a #{prod_app_name} | grep -E "heroku\\[|app\\[api\\]"
                EOS

                sigint_handler = Proc.new do
                  puts
                  print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show

                  puts
                  puts "\e[43m  \e[0m \e[0;32mRelease \e[1m#{release_tag}\e[0;32m is being launched on \e[1m#{prod_app_name}\e[0;32m\e[0m \e[43m  \e[0m"
                  puts

                  shutdown

                  exit 0
                end

                run_each(script, parser: parser, sigint_handler: sigint_handler)

                puts
                print"\a"; sleep 0.4
                puts "\e[42m  \e[0m \e[0;32mRelease \e[1m#{release_tag}\e[0;32m has been deployed to \e[1m#{prod_app_name}\e[0;32m\e[0m \e[42m  \e[0m"
                print"\a"; sleep 0.4
                puts
                print"\a"; sleep 0.4

                exit 0
              end
            end
          when :push_to_staging
            Fidget.prevent_sleep(:display, :sleep, :user) do
              run_each <<-EOS.strip_heredoc
                :stream
                git push origin develop
                git push #{push_url} release/#{release_tag}:master -f
                EOS
            end
            anykey
          when :abort_ask
            puts if delete_branch("release/#{release_tag}")
            exit 0
          when :bump_tiny
            if delete_branch("release/#{release_tag}")
              release_tag, branch_already_exists = prompt_for_release_tag(tiny_bump, tiny_bump)
            end
          when :bump_minor
            if delete_branch("release/#{release_tag}")
              release_tag, branch_already_exists = prompt_for_release_tag(minor_bump, minor_bump)
            end
          when :bump_major
            if delete_branch("release/#{release_tag}")
              release_tag, branch_already_exists = prompt_for_release_tag(major_bump, major_bump)
            end
          when :refresh
            puts
          when :abort
            exit 0
          end
        end
      end

      def type(text, delay=0.01)
        text.chars.each do |c|
          print c
          sleep rand * delay unless c == ' '
        end
      end

      def ci_info
        puts
        if ENV['HU_GITHUB_ACCESS_TOKEN'].nil?
          msg = "ERROR: Environment variable 'HU_GITHUB_ACCESS_TOKEN' must be set."
        else
          msg = 'ERROR: Github access token is invalid or has insufficient permissions'
        end
        puts msg.color(:red)
        puts <<EOF

       1. Go to \e]8;;https://github.com/settings/tokens\007https://github.com/settings/tokens\e]8;;\007

       2. Click on [Generate new token]

       3. Create a token with (only) the following permissions:

          - repo:status
          - repo_deployment
          - public_repo
          - read:user

       4. Add the following line to your shell environment (e.g. ~/.bash_profile):

          \e[1mexport HU_GITHUB_ACCESS_TOKEN=<your_token>\e[0m

EOF
      end

      def ci_status(release_branch_exists=true)
        okit = Octokit::Client.new(access_token: ENV['HU_GITHUB_ACCESS_TOKEN'])

        repo_name = @git.remotes['origin'].url.split(':')[1].gsub('.git', '')

        begin
          raw_status_develop = status_develop = okit.status(repo_name, @git.branches["origin/develop"].target_id)
          status_develop = status_develop[:statuses].empty? ? ' ' : status_develop[:state]
          status_develop = ' ' if @git.branches["origin/develop"].target_id != @git.branches["develop"].target_id
          status_develop = ' ' unless release_branch_exists
        rescue Octokit::NotFound, Octokit::Unauthorized
          return :error
        end

        begin
          # status_master = okit.status(repo_name, @git.branches["origin/master"].target_id)
          # p status_master
          # status_master = status_master[:statuses].empty? ? 'n/a' : status_master[:state]
          # status_master = ' ' if @git.branches["origin/master"].target_id != @git.branches["master"].target_id
          status_master = ' '
        rescue Octokit::NotFound
          status_master = 'unknown'
        end

        {
          master: status_master,
          develop: status_develop,
          raw_develop: raw_status_develop
        }
      end

      def ci_symbol(value)
        case value
        when ' '
          ''
        when 'pending'
          ' 🐌'
        when 'success'
          ' ✅'
        else
          ' ❌'
        end
      end

      def ci_clear?
        return true if ENV['HU_GITHUB_ACCESS_TOKEN'].nil?
        msg = ''
        prefix = "CI: "
        ci_develop = ''
        begin_wait_at = Time.now - 1
        i = 0
        puts
        Signal.trap('QUIT') { raise SigQuit }
        Signal.trap('INT') { raise Interrupt }
        while ci_develop != 'success' do
          puts
          print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.hide
          print prefix
          print ('-' * (ci_develop.length + 2)) unless i == 0
          print msg unless i == 0
          ci_develop = ci_status(true)[:develop] if i % 10 == 0
          # ci_develop = 'failed'

          puts
          print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show

          print TTY::Cursor.hide + "\n" + TTY::Cursor.up
          msg = " - press ^\\ to override, ^C to abort (#{ChronicDuration.output((Time.now - begin_wait_at).to_i, format: :short)}) "

          status = ci_develop.upcase
          case status
          when 'PENDING'
            status = "\e[44;33;1m PENDING \e[0m"
          when 'SUCCESS'
            status = "\e[42;30;1m CLEAR \e[0m"
          when ' '
            status = "\e[40;30;1m UNCONFIGURED \e[0m"
          else
            status = "\e[41;33;1m #{status} \e[0m"
          end
          print prefix + status
          print msg unless ci_develop == 'success' || ci_develop == ' '

          # key = nil

          sleep 1

          break if ci_develop == ' '
          # catch :sigint do
          #   begin
          #     Timeout::timeout(1) do
          #       Signal.trap('INT') { throw :sigint }
          #       key = STDIN.getch
          #     end
          #   rescue Timeout::Error
          #     key = :timeout
          #   ensure
          #     Signal.trap('INT', 'DEFAULT')
          #   end
          # end
          # if key == "\u0003"
          #   puts
          #   print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show
          #   return false
          # end

          i += 1
        end
        puts
        print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show
        print TTY::Cursor.up
        return true
        rescue Interrupt
          puts
          print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show
          return false
        rescue SigQuit
          puts
          print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show
          puts "CI: \e[41;33;1m OVERRIDE \e[0m"
          return true
        ensure
          Signal.trap('QUIT', 'DEFAULT')
          Signal.trap('INT', 'DEFAULT')
          puts
          print TTY::Cursor.up + TTY::Cursor.clear_line + TTY::Cursor.show
      end

      def show_pipeline_status(pipeline_name, stag_app_name, prod_app_name, release_tag, clear = true)
        table = TTY::Table.new header: ['', 'commit', 'tag', 'last_modified', 'last_modified_by', 'dynos', '']
        busy 'synchronizing', :dots
        ts = []
        workers = []
        tpl_row = ['?', '', '', '', '', '', '']
        revs = ThreadSafe::Hash.new
        app_config = ThreadSafe::Hash.new

        revs[:develop] = `git rev-parse develop`[0..5]

        [[0, stag_app_name], [1, prod_app_name]].each do |idx, app_name|
          workers << Thread.new do
            # config vars
            app_config[app_name] = h.config_var.info_for_app(app_name)
          end

          ts << Thread.new do
            # dyno settings
            table_row = tpl_row.dup
            table_row[0] = app_name
            loop do
              dynos = h.dyno.list(app_name)
              table_row[6] = "\e[31;1moffline\e[0m"
              break if dynos.nil?
              dp :dynos, dynos

              formation = h.formation.list(app_name)

              formation_stats = {}
              formation.each do |o|
                formation_stats[o['size']] ||= 0
                formation_stats[o['size']] += o['quantity']
              end
              table_row[5] = formation_stats.map{|k,v|
                                  next if 0 == v; "\e[1m#{v}×#{dt = Hu::Cli::Scale::DYNO_TYPES.find { |e| e[:id] == k.downcase }
                                  suffix = ""
                                  suffix = "\e[30;1m free" if dt[:id] == 'free'
                                  "\e[0m" + (dt[:ram]/1024.0).to_s}G"+suffix
                             }.compact.join(', ')

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

              table_row[1] = table_row[1].color(table_row[1] == revs[:develop] ? :green : :red)

              table_row[2] = `git tag --points-at #{slug_info['commit']} 2>/dev/null`
              table_row[2] = '' unless $?.success?

              # heroku uses wrong timezone offset in the slug api... /facepalm
              # table_row[3] = ChronicDuration.output(Time.now.utc - Time.parse(slug_info['updated_at']), :units => 1)

              if release_info['updated_at'].nil?
                table_row[3] += 'unknown'
              else
                delta = Time.now.utc - Time.parse(release_info['updated_at'])
                table_row[3] = delta < 60 ? 'less than a minute' : ChronicDuration.output(delta, units: 1)
                table_row[3] += ' ago'
              end
              # table_row[3] += "\n\e[30;1m" + slug_info['updated_at']

              table_row[4] = release_info['user']['email']
              break
            end
            [idx, table_row]
          end
        end

        ci = Thread.new do
          ci_status(branch_exists?("release/#{release_tag}"))
        end

        ci = ci.value
        if ci == :error
          unbusy
          ci_info
          exit 1
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
        row[1] = row[1].color(row[1] == revs[:develop] ? :green : :red)
        # row[3] = color_ci(ci[:master])
        rows.unshift row

        if branch_exists? "release/#{release_tag}"
          row = tpl_row.dup
          row[0] = "release/#{release_tag}"
          revs["release/#{release_tag}"] = revs[:release] = row[1] = `git rev-parse release/#{release_tag}`[0..5]
          row[1] = row[1].color(row[1] == revs[:release] ? :green : :red)
          row[2] = `git tag --points-at release/#{release_tag} 2>/dev/null`
          rows.unshift row
        end

        row = tpl_row.dup
        row[0] = 'origin/develop'
        row[1] = `git rev-parse origin/develop`[0..5]
        row[1] = row[1].color(row[1] == revs[:develop] ? :green : :red) + ci_symbol(ci[:develop])
        row[2] = `git tag --points-at origin/develop`
        # row[3] = color_ci(ci[:develop])
        rows.unshift row

        row = tpl_row.dup
        row[0] = 'develop'
        row[1] = revs[:develop].color(:green)
        row[2] = `git tag --points-at develop`
        # row[3] = color_ci(ci[:develop]) if
        rows.unshift row

        unbusy

        rows.each do |r|
          table << r
        end

        git_version_warning = ''
        # if current_git_version < MINIMUM_GIT_VERSION
        #  git_version_warning = " (your git is outdated. please upgrade to v#{MINIMUM_GIT_VERSION}!)".color(:black).bright
        # end

        puts "\e[H\e[2J" if clear
        puts " #{pipeline_name} ".bright.inverse + git_version_warning
        # puts " #{pipeline_name} ".bright.inverse + ' '.color(:cyan).inverse + ' '.color(:blue).inverse + ' '.color(:black).bright.inverse + git_version_warning

        puts

        puts table.render(:unicode, padding: [0, 1, 0, 1], multiline: true)

        missing_env = app_config[stag_app_name].keys - app_config[prod_app_name].keys
        env_ignore = begin
                       File.read(File.join('.hu', 'env_ignore'))&.lines.map(&:chomp)
                     rescue
                       nil
                     end
        missing_env -= env_ignore if missing_env && env_ignore
        unless missing_env.empty?
          puts
          missing_env.each do |var|
            puts ' WARNING '.background(:red).color(:yellow).bright + ' Missing config in ' + prod_app_name.bright + ": #{var}"
            sleep 0.42
          end
        end

        # p ci
        if ci[:develop] != ' '
          ci[:raw_develop][:statuses].each do |status|
            if ['failure', 'error'].include? status[:state]
              puts
              print " CI #{status[:state].upcase} ".background(:red).color(:yellow).bright
              print " \033]1337;RequestAttention=fireworks\a"
              sleep 1
              puts "#{status[:description]}".bright
              puts "      " + (" " * status[:state].length) + status[:target_url]
            end
          end
        end

        revs
      rescue Interrupt
        puts "*** Abort"
        exit 1
      end

      def heroku_app_by_git(git_url)
        busy('synchronizing', :dots)
        r = h.app.list.select { |e| e['git_url'] == git_url }
        unbusy
        raise "FATAL: Found multiple heroku apps with git_url=#{git_url}" if r.length > 1
        r[0]
      rescue Excon::Error::Unauthorized
        unbusy
        puts "ERROR: Heroku Access Denied".color(:red)
        puts
        puts "       Most likely your local credentials have expired."
        puts "       Please run 'heroku login'."
        puts
        exit 1
      end

      def heroku_pipeline_details(app)
        busy('synchronizing', :dots)
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
          failquiet: false,
          spinner: true,
          stream: false,
          parser: nil
        }.merge(opts)

        parser = opts[:parser]

        @spinlock ||= Mutex.new # :P
        script.lines.each_with_index do |line, i|
          line.chomp!
          case line[0]
          when '#'
            puts "\n" + line.bright unless opts[:quiet]
          when ':'
            opts[:quiet] = true if line == ':quiet'
            opts[:failfast] = false if line == ':return'
            opts[:failquiet] = true if line == ':failquiet'
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
                break if @minispin_last_char_at == :end || @shutdown
                begin
                  if 0.23 > Time.now - @minispin_last_char_at || @minispin_disable
                    sleep 0.1
                    next
                  end
                rescue
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
                l = ''
                until r.eof?
                  c = r.getc
                  @spinlock.synchronize do
                    print c unless opts[:quiet]
                    if c == "\n" && parser
                      parser.call(l, pid)
                      l = ''
                    else
                      l += c
                    end
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
              rescue Interrupt
                if opts[:sigint_handler]
                  opts[:sigint_handler].call
                else
                  puts
                  puts "*** Abort (SIGINT)"
                  exit 1
                end
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
              print TTY::Cursor.clear_line + TTY::Cursor.show
              puts "\n> ".color(color) + line.color(:black).bright
              puts output
            end
          end
          next unless status.exitstatus != 0
          shutdown if opts[:failfast]
          puts "Error, exit #{status.exitstatus}: #{line} (L#{i})".color(:red).bright unless opts[:failquiet]

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
                                                 # yes, this is really how rubocop
                                                 # wants to format this... *shrug*
                                                 next true if e.length < 4
                                                 Versionomy.parse(e)
                                                 false
                                               rescue
                                                 true
                                               end
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
        begin
          return false if TTY::Prompt.new.no?("Delete branch #{branch_name}?")
        rescue TTY::Reader::InputInterrupt
          return false
        end
        run_each <<-EOS.strip_heredoc
          :quiet
          # Delete branch #{branch_name}
          git checkout develop
          git branch -D #{branch_name}
        EOS
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
      end

      def update_working_copy
        run_each <<-EOS.strip_heredoc
        :quiet
        :nospinner
        # Ensure local repository is up to date
        git checkout develop && git pull
        git checkout master && git pull --rebase origin master
        EOS
      end

      def heroku_git_remote
        ensure_repo_has_heroku_remote
        `git remote show -n heroku | grep Push`.chomp.split(':', 2)[1][1..-1]
      end

      def ensure_repo_has_heroku_remote
        exit_code = run_each <<-EOS.strip_heredoc
        :nospinner
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

      def prompt_for_release_tag(_propose_version = 'v0.0.1', try_version = nil, keep_existing = false)
        prompt = TTY::Prompt.new
        loop do
          if try_version
            release_tag = try_version
            # try_version = nil
          end
          # else
          #  show_existing_git_tags
          #  release_tag = prompt.ask('Please enter a tag for this release', default: propose_version)
          #  begin
          #    unless release_tag[0] == 'v'
          #      raise ArgumentError, 'Version string must start with the letter v'
          #    end
          #    raise ArgumentError, 'too short' if release_tag.length < 5
          #    Versionomy.parse(release_tag)
          #  rescue => e
          #    puts "Error: Tag does not look like a semantic version (#{e})".color(:red)
          #    next
          #  end
          # end

          branches = `git for-each-ref refs/heads/ --format='%(refname:short)'`.lines.map(&:chomp)
          existing_branch = branches.find { |b| b.start_with? 'release/' }
          branch_already_exists = !existing_branch.nil?
          release_tag = existing_branch[8..-1] if keep_existing && branch_already_exists

          revs = {}
          revs[:develop] = `git rev-parse develop`[0..5]
          revs[:release] = `git rev-parse release/#{release_tag}`[0..5] if branch_already_exists

          if branch_already_exists && revs[:develop] != revs[:release]
            puts

            puts 'Oops!'.bright
            puts
            puts 'Your release-branch ' + "release/#{release_tag}".bright + ' is out of sync with ' + 'develop'.bright + '.'
            puts
            puts 'develop is at ' + revs[:develop].bright + ", release/#{release_tag} is at " + revs[:release].bright + '.'
            puts
            puts 'This usually means the release branch is old and does'
            puts 'not reflect what you actually want to deploy right now.'
            puts
            choice = prompt.select('What shall we do?') do |menu|
              menu.enum '.'
              menu.choice "Delete branch 'release/#{release_tag}' and create new release branch from 'develop'", :delete
              menu.choice 'Quit - do nothing, let me inspect the situation', :quit
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

      def finish_release(release_tag, env, changelog_path)
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

        # Adjust merge message
        git checkout master
        git commit --amend -F #{changelog_path}
        git tag -f #{release_tag}

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
      end

      def return_to_home_branch
        return if @@home_branch.nil? || @@home_branch == current_branch_name
        run_each <<-EOS.strip_heredoc
        :quiet
        :nospinner
        :return
        # Return to home branch
        git checkout #{@@home_branch}
        EOS
      end

      def develop_can_be_merged_into_master?
        status = run_each <<-EOS.strip_heredoc
        :quiet
        :nospinner
        :return
        git checkout master && git merge --no-commit --no-ff develop || { git merge --abort; false ;}
        git merge --abort || true
        EOS
        status == 0
      end

      def current_branch_name
        @git.head.name.sub(%r{^refs\/heads\/}, '')
      end

      # def current_git_version
      #  Versionomy.parse(`git --version`.chomp.split(' ')[-1])
      # end

      def create_changelog(env)
        if File.executable? '.hu/hooks/changelog'
          env.each { |k, v| ENV[k] = v }
          `.hu/hooks/changelog`
        else
          `git log --pretty=format:" - %h %s (%an)" #{env['PREVIOUS_TAG']}..HEAD 2>/dev/null`
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

      def anykey(force=false)
        unless ENV['HU_ANYKEY'] || force
          puts
          return
        end
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
