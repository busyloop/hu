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

module Hu
  class Cli < Optix::Cli
    class Deploy < Optix::Cli
      @@shutting_down = false

      text "Interactive deployment."
      desc "Interactive deployment"
      if Hu::API_TOKEN.nil?
        text ""
        text "\e[1mWARNING: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
      end
      filter do
        if Hu::API_TOKEN.nil?
          STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
          exit 1
        end
      end

      def deploy(cmd, opts, argv)
        trap('INT') { shutdown; safe_abort }
        at_exit {
          if 130 == $!.status
            shutdown
            puts
            safe_abort
          end
        }
        push_url = get_heroku_git_remote

        wc_update = Thread.new { update_working_copy }

        app = heroku_app_by_git(push_url)

        if app.nil?
          puts
          puts "FATAL: Found no heroku app for git remote #{push_url}".color(:red)
          puts "       Are you logged into the right heroku account?".color(:red)
          puts
          puts "       Please run 'git remote rm heroku'. Then run 'hu deploy' again to select a new remote."
          puts
          exit 1
        end

        pipeline_name, stag_app_id, prod_app_id = heroku_pipeline_details(app)

        if app['id'] != stag_app_id
          puts
          puts "FATAL: The git remote 'heroku' points to app '#{app['name']}'".color(:red)
          puts "       which is not in stage 'staging'".color(:red)+
               " of pipeline '#{pipeline_name}'.".color(:red)
          puts
          puts "       The referenced app MUST be the staging member of the pipeline."

          puts "       Please run 'git remote rm heroku'. Then run 'hu deploy' again to select a new remote."
          puts
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
        likely_next_version = Versionomy.parse(highest_version).bump(:tiny).to_s
        release_tag, branch_already_exists = prompt_for_release_tag(likely_next_version, likely_next_version, true)

        prompt = TTY::Prompt.new

        clearscreen = true
        loop do
          git_revisions = show_pipeline_status(pipeline_name, stag_app_name, prod_app_name, release_tag, clearscreen)
          clearscreen = true

          changelog='Initial revision'
          release_branch_exists = branch_exists?("release/#{release_tag}")

          if release_branch_exists
            puts "\nThis release will be "+release_tag.color(:red).bright
            unless highest_version == 'v0.0.0'
              changelog=`git log --pretty=format:" - %s" #{highest_version}..HEAD` unless highest_version == 'v0.0.0'
              puts "\nChanges since "+highest_version.bright+":"
              puts changelog
            end
            puts
          else
            puts "\nThis is release "+release_tag.color(:green).bright
            puts
          end

          choice = prompt.select("Choose your destiny") do |menu|
            menu.enum '.'
            menu.choice "Refresh", :refresh
            menu.choice "Quit", :abort_ask
            unless git_revisions[:release] == git_revisions[stag_app_name] or !release_branch_exists
              menu.choice "Push   release/#{release_tag} to #{stag_app_name}", :push_to_staging
            end
            if release_branch_exists
              menu.choice "Delete release/#{release_tag} and start new release from develop", :retag
              menu.choice "Finish release (merge, tag and final stage)", :finish_release
            elsif git_revisions[prod_app_name] != git_revisions[stag_app_name]
              menu.choice "DEPLOY (promote #{stag_app_name} to #{prod_app_name})", :DEPLOY
            end
          end

          puts

          case choice
            when :DEPLOY
              promote_to_production
              anykey
            when :finish_release
              old_editor = ENV['EDITOR']
              tf = Tempfile.new('hu-tag')
              tf.write "#{release_tag}\n#{changelog}"
              tf.close
              ENV['EDITOR'] = "cp #{tf.path}"
              unless 0 == finish_release(release_tag)
                abort_merge
                puts "*** ERROR!  Push did not complete. *** ".color(:red)
              end
              ENV['EDITOR'] = old_editor
              anykey
            when :push_to_staging
              push_command = "git push #{push_url} release/#{release_tag}:master -f"
              `#{push_command}`
              puts
              anykey
            when :abort_ask
              delete_branch("release/#{release_tag}")
              puts
              exit 0
            when :retag
              if delete_branch("release/#{release_tag}")
                release_tag, branch_already_exists = prompt_for_release_tag(likely_next_version)
              end
          end
        end
      end

      def show_pipeline_status(pipeline_name, stag_app_name, prod_app_name, release_tag, clear=true)
        table = TTY::Table.new header: %w{location commit tag app_last_modified app_last_modified_by dynos# state}
        busy '♪♫♬  elevator music ', :pulse
        ts = []
        tpl_row = ['?', '', '', '', '', '', '']
        revs = ThreadSafe::Hash.new

        [[0,stag_app_name],[1,prod_app_name]].each do |idx, app_name|
          ts << Thread.new do
            table_row = tpl_row.dup
            table_row[0] = app_name
            loop do
              dynos = h.dyno.list(app_name)
              break if dynos.nil?
              dp :dynos, dynos

              table_row[5] = dynos.length

              release_version = dynos.dig(0, 'release', 'version')
              break if release_version.nil?

              state = Set.new(dynos.collect{|d| d['state']}).sort.join(', ')
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
              table_row[2] = '' if $? != 0

              # heroku uses wrong timezone offset in the slug api... /facepalm
              #table_row[3] = ChronicDuration.output(Time.now.utc - Time.parse(slug_info['updated_at']), :units => 1)

              table_row[3] = ChronicDuration.output(Time.now.utc - Time.parse(release_info['updated_at']), :units => 1)
              table_row[3] += " ago"
              #table_row[3] += "\n\e[30;1m" + slug_info['updated_at']

              table_row[4] = release_info['user']['email']
              table_row[5] = dynos.length
              break
            end
            [idx, table_row]
          end
        end

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

        rows.each do |row|
          table << row
        end

        puts "\e[H\e[2J" if clear
        puts " PIPELINE #{pipeline_name} ".inverse
        puts

        puts table.render(:unicode, padding: [0,1,0,1], multiline: true)
        revs
      end

      def heroku_app_by_git(git_url)
        busy('fetching heroku apps', :dots)
        r = h.app.list.select{ |e| e['git_url'] == git_url }
        unbusy
        raise "FATAL: Found multiple heroku apps with git_url=#{git_url}" if r.length > 1
        r[0]
      end

      def heroku_pipeline_details(app)
        busy('fetching heroku pipelines', :dots)
        couplings = h.pipeline_coupling.list
        unbusy
        r = couplings.select{ |e| e['app']['id'] == app['id'] }
        raise "FATAL: Found multiple heroku pipelines with app.id=#{r['id']}" if r.length > 1
        raise "FATAL: Found no heroku pipeline for app.id=#{r['id']}" if r.length != 1
        r = r[0]
        pipeline_name = r['pipeline']['name']

        r = couplings.select{ |e| e['pipeline']['id'] == r['pipeline']['id'] and e['stage'] == 'staging' }[0]
        staging_app_id = r['app']['id']

        r = couplings.select{ |e| e['pipeline']['id'] == r['pipeline']['id'] and e['stage'] == 'production' }[0]
        raise "FATAL: No production app in pipeline #{pipeline_name}" if r.nil?
        prod_app_id = r['app']['id']
        [pipeline_name, staging_app_id, prod_app_id]
      end

      def h
        @h ||= PlatformAPI.connect_oauth(Hu::API_TOKEN)
      end

      def run_each(script)
        quiet = false
        failfast = true
        spinner = true
        script.lines.each_with_index do |line, i|
          line.chomp!
          case line[0]
            when '#'
              puts "\n" + line.bright unless quiet
            when ':'
              quiet = true     if line == ':quiet'
              failfast = false if line == ':return'
              spinner  = false if line == ':nospinner'
          end
          next if line.empty? or ['#', ':'].include? line[0]
          busy line if spinner
          output, status = Open3.capture2e(line)
          unbusy if spinner
          color = (status.exitstatus == 0) ? :green : :red
          if status.exitstatus != 0 or !quiet
            puts "\n> ".color(color) + line.color(:black).bright
            puts output
          end
          if status.exitstatus != 0
            shutdown if failfast
            puts "Error on line #{i}: #{line}"
            puts "Exit code: #{status.exitstatus}"
            exit status.exitstatus if failfast
            return status.exitstatus
          end
        end
        0
      end

      def find_highest_version_tag
        output, status = Open3.capture2e('git tag')
        if status.exitstatus != 0
          puts "Error fetching git tags."
          exit status.exitstatus
        end

        versions = VersionSorter.sort(output.lines.map(&:chomp))
        latest = versions[-1] || 'v0.0.0'
        latest = "v#{latest}" unless latest[0] == "v"
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
          git co develop
          git branch -D #{branch_name}
        EOS
        puts "Branch #{branch_name} deleted.".color(:red)
        true
      end

      def checkout_branch(branch_name)
        run_each <<-EOS.strip_heredoc
          :quiet
          # Checkout branch #{branch_name}
          git co #{branch_name}
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

      def get_heroku_git_remote
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
        puts "We will set one up now. Please select the pipeline that you"
        puts "wish to deploy to, and we will set the 'heroku' remote"
        puts "to the staging application in that pipeline."
        puts

        busy
        heroku_apps=JSON.parse(`heroku pipelines:list --json`)
        unbusy

        prompt = TTY::Prompt.new
        pipeline_name = prompt.select("Select pipeline:") do |menu|
          menu.enum '.'
          heroku_apps.each do |app|
            menu.choice app['name']
          end
        end
        staging_app=JSON.parse(`heroku pipelines:info #{pipeline_name} --json`)['apps'].select{|e| e['coupling']['stage'] == 'staging'}[0]
        if staging_app.nil?
          puts "Error: Pipeline #{pipeline_name} has no staging app.".color(:red)
          exit 1
        end

        run_each <<-EOS.strip_heredoc
        # Add git remote
        git remote add heroku #{staging_app['git_url']}
        EOS
      end

      def prompt_for_release_tag(propose_version='v0.0.1', try_version=nil, keep_existing=false)
        prompt = TTY::Prompt.new
        loop do
          if try_version
            release_tag = try_version
            try_version = nil
          else
            show_existing_git_tags
            #puts
            release_tag = prompt.ask("Please enter a tag for this release", default: propose_version)
            begin
              unless release_tag[0] == 'v'
                raise ArgumentError, "Version string must start with the letter v"
              end
              if release_tag.length < 5
                raise ArgumentError, "too short"
              end
              Versionomy.parse(release_tag)
            rescue => e
              puts "Error: Tag does not look like a semantic version (#{e})".color(:red)
              next
            end
          end

          branches = `git for-each-ref refs/heads/ --format='%(refname:short)'`.lines.map(&:chomp)
          existing_branch = branches.find {|e| e.start_with? 'release/'}
          branch_already_exists = !existing_branch.nil?
          release_tag = existing_branch[8..-1] if keep_existing && branch_already_exists
          if branch_already_exists && !keep_existing
            choice = prompt.expand("The branch '"+"release/#{release_tag}".color(:red)+"' already exists. What shall we do?",
                                                          {default: 0}) do |q|
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
            develop_tag=`git tag --points-at develop 2>/dev/null`.lines.find { |e| e[0] == 'v' }&.chomp
            if develop_tag
              release_tag = develop_tag
            else
              start_release(release_tag)
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
        :return

        # Promote staging to production
        heroku pipelines:promote -r heroku
        EOS
      end

      def finish_release(release_tag)
        run_each <<-EOS.strip_heredoc
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
        git merge master

        # Push develop to origin
        git push origin develop
        EOS
      end

      def abort_merge
        run_each <<-EOS.strip_heredoc
        # Abort failed merge
        git merge --abort
        EOS
      end

      def shutdown
        @@shutting_down = true
        unbusy
      end

      def busy(msg='', format=:classic)
        return if @@shutting_down
        format ||= TTY::Formats::FORMATS.keys.sample
        options = {format: format, hide_cursor: true, error_mark: "\e[31;1m✖\e[0m", success_mark: "\e[32;1m✔\e[0m", clear: true}
        @@spinner = TTY::Spinner.new("\e[0;1m#{msg}#{msg.empty? ? '' : ' '}\e[0m\e[32;1m:spinner\e[0m", options)
        @@spinner.start
      end

      def unbusy
        @@spinner.stop
        printf "\e[?25h"
      end

      def with_spinner(msg='', format=:classic, &block)
        busy(msg, format)
        block.call
        unbusy
      end

      def anykey
        puts TTY::Cursor.hide
        print "--- Press any key to continue ---".color(:cyan).inverse
        STDIN.getch
        print TTY::Cursor.clear_line + TTY::Cursor.show
      end

      def dp(label, *args)
        return unless ENV['DEBUG']
        puts "---  DEBUG #{label}  ---"
        ap *args
        puts "--- ^#{label}^ ---"
      end

      def safe_abort
        @@spinner.stop
        printf "\e[0m\e[?25l"
        printf '(ヘ･_･)ヘ┳━┳'
        sleep 0.5
        printf "\e[12D(ヘ･_･)-┳━┳"
        sleep 0.1
        printf "\e[12D\e[31;1m(╯°□°）╯  ┻━┻"
        sleep 0.1
        printf "\e[1;31m\e[14D(╯°□°）╯    ┻━┻"
        sleep 0.05
        printf "\e[0;31m\e[15D(╯°□°）╯     ┻━┻"
        sleep 0.05
        printf "\e[30;1m\e[16D(╯°□°）╯      ┻━┻"
        sleep 0.05
        printf "\e[17D                 "
        printf "\e[?25h"
        puts
        exit 1
      end
    end
  end
end
